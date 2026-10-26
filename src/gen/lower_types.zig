const std = @import("std");
const llvm = @import("llvm");
const ast = @import("../ast.zig");
const types = @import("../sema/type_system.zig");
const Codegen = @import("codegen.zig").Codegen;

const log = std.log.scoped(.codegen);

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
