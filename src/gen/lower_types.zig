// Type lowering: AST / sema types -> LLVM types, plus struct and enum layouts.

const std = @import("std");
const llvm = @import("llvm");
const ast = @import("../ast.zig");
const types = @import("../sema/type_system.zig");
const Codegen = @import("codegen.zig").Codegen;

const log = std.log.scoped(.codegen);

// `p` is either an `ast.PrimitiveType` or a `types.Primitive`, both have same tag.
// so that we can just have one func for both!
pub fn primitive_type(cg: *Codegen, p: anytype) llvm.LLVMTypeRef {
    return switch (p) {
        .i8, .u8 => llvm.LLVMInt8TypeInContext(cg.ctx),
        .i16, .u16 => llvm.LLVMInt16TypeInContext(cg.ctx),
        .i32, .u32 => llvm.LLVMInt32TypeInContext(cg.ctx),
        .i64, .u64, .usize, .isize => llvm.LLVMInt64TypeInContext(cg.ctx),
        .f32 => llvm.LLVMFloatTypeInContext(cg.ctx),
        .f64 => llvm.LLVMDoubleTypeInContext(cg.ctx),
        .bool => llvm.LLVMInt1TypeInContext(cg.ctx),
        .char => llvm.LLVMInt8TypeInContext(cg.ctx),
        .str => llvm.LLVMPointerType(llvm.LLVMInt8TypeInContext(cg.ctx), 0),
        .ptr => llvm.LLVMPointerTypeInContext(cg.ctx, 0),
    };
}

// { ptr, len }
pub fn slice_type(cg: *Codegen, elem: llvm.LLVMTypeRef) llvm.LLVMTypeRef {
    var fields = [_]llvm.LLVMTypeRef{ llvm.LLVMPointerType(elem, 0), llvm.LLVMInt64TypeInContext(cg.ctx) };
    return llvm.LLVMStructTypeInContext(cg.ctx, &fields, fields.len, 0);
}

// type written in the source (annotations, params, fields)
pub fn get_type(cg: *Codegen, ret_type: *ast.Type) anyerror!llvm.LLVMTypeRef {
    // TODO: handle optionals and errors
    switch (ret_type.base) {
        .primitive => |p| return primitive_type(cg, p),
        .pointer => |p| return llvm.LLVMPointerType(try get_type(cg, p), 0),
        .array => |*a| {
            const ele_ty = try get_type(cg, a.elem);
            const sz = switch (a.size) {
                .fixed => |s| try std.fmt.parseInt(c_uint, s, 10),
                else => unreachable,
            };
            return llvm.LLVMArrayType2(ele_ty, sz);
        },
        .named => |*n| {
            if (std.mem.eql(u8, n.name, "ptr")) {
                return llvm.LLVMPointerTypeInContext(cg.ctx, 0);
            }
            if (cg.struct_types.get(n.name)) |st| return st;
            const resolved = cg.ts().resolve(n.name) orelse unreachable;
            return try llvm_type_of(cg, resolved);
        },
        .slice => |*s| return slice_type(cg, try get_type(cg, s.elem)),
        else => {
            // TODO:
            unreachable;
        },
    }
}

// type computed by sema (expression types)
pub fn llvm_type_of(cg: *Codegen, ty: types.TypeId) anyerror!llvm.LLVMTypeRef {
    // note: for temp if some types are not managed in sema for now
    if (ty == .invalid) return llvm.LLVMInt32TypeInContext(cg.ctx);

    switch (cg.ts().get(ty).*) {
        .primitive => |p| return primitive_type(cg, p),
        .pointer => |p| return llvm.LLVMPointerType(try llvm_type_of(cg, p.child), 0),
        .array => |a| {
            const ele_ty = try llvm_type_of(cg, a.child);
            const sz: c_uint = @intCast(a.len);
            return llvm.LLVMArrayType2(ele_ty, sz);
        },
        .struct_ty => |s| return cg.struct_types.get(s.name) orelse error.NoStructTypeAvailable,
        .slice => |s| return slice_type(cg, try llvm_type_of(cg, s.child)),
        .enum_ty => return llvm.LLVMInt32TypeInContext(cg.ctx),
        else => {
            //todo: other typse
            unreachable;
        },
    }
}

pub fn struct_def(cg: *Codegen, s_def: *ast.StructDef) !void {
    const fields = try cg.allocator.alloc(llvm.LLVMTypeRef, s_def.fields.items.len);
    defer cg.allocator.free(fields);
    for (s_def.fields.items, 0..) |f, idx| {
        fields[idx] = try get_type(cg, f.type);
    }

    const s_ty = llvm.LLVMStructTypeInContext(cg.ctx, fields.ptr, @intCast(fields.len), 0);
    try cg.struct_types.put(s_def.name, s_ty);

    // TODO: the named struct is created but never used (struct_types holds the literal type)
    const name = try cg.cstr(s_def.name);
    defer cg.allocator.free(name);
    _ = llvm.LLVMStructCreateNamed(cg.ctx, name.ptr);
}

pub fn enum_def(cg: *Codegen, e_def: *ast.EnumDef) !void {
    // get the largest enum variant to allocate enough space
    // TODO: multiple type variant
    var l_width: usize = 0;
    for (e_def.variants.items, 0..) |*ev, i| {
        if (ev.types.items.len == 0) continue;

        const v_elems = try cg.allocator.alloc(llvm.LLVMTypeRef, ev.types.items.len + 1);
        defer cg.allocator.free(v_elems);
        // tagged variant with i8
        v_elems[0] = llvm.LLVMInt8TypeInContext(cg.ctx);
        for (ev.types.items, 1..) |t, idx| {
            const ty = try get_type(cg, t);
            const tar_data = llvm.LLVMGetModuleDataLayout(cg.mod);
            const w_ty = llvm.LLVMABISizeOfType(tar_data, ty);
            if (w_ty > l_width) l_width = w_ty;
            v_elems[idx] = ty;
        }

        // allocate for variant types
        const name = try cg.allocator.dupe(u8, ev.name);
        const v_ty = llvm.LLVMStructTypeInContext(cg.ctx, v_elems.ptr, @intCast(ev.types.items.len + 1), 0);
        try cg.enum_types.put(name, v_ty);
        try cg.enum_tag.put(name, i);
    }

    // c type simple enum
    if (l_width == 0) return;

    // allocate a range of bytes(i8), with alignment and padding
    const name = try cg.allocator.dupe(u8, e_def.name);
    const arr_ty = llvm.LLVMArrayType(llvm.LLVMInt8TypeInContext(cg.ctx), @intCast(l_width));
    var elems: [2]llvm.LLVMTypeRef = .{ llvm.LLVMInt8TypeInContext(cg.ctx), arr_ty };
    const e_ty = llvm.LLVMStructTypeInContext(cg.ctx, @ptrCast(&elems), 2, 0);
    log.debug("enum type registered: {s}", .{name});
    try cg.enum_types.put(name, e_ty);
}
