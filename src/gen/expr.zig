// Expressions.

const std = @import("std");
const llvm = @import("llvm");
const ast = @import("../ast.zig");
const types = @import("../sema/type_system.zig");
const Codegen = @import("codegen.zig").Codegen;
const numeric = @import("numeric.zig");
const call_mod = @import("call.zig");

const Value = llvm.LLVMValueRef;

pub fn codegen_expression(cg: *Codegen, e: *ast.Expr) anyerror!Value {
    return codegen_expression_with_type(cg, e, null);
}

pub fn codegen_expression_with_type(cg: *Codegen, e: *ast.Expr, expected_ty: ?llvm.LLVMTypeRef) anyerror!Value {
    return switch (e.*) {
        .literal => |*l| try codegen_literal(cg, l, e),
        .binary => |*b| try codegen_binary(cg, b),
        .unary => |*u| try codegen_unary(cg, u),
        .call => |*c| try call_mod.codegen_call(cg, c),
        .ident => |*i| try codegen_ident(cg, i),
        .array_literal => |*a| try codegen_array(cg, a, e),
        .index => |*i| try codegen_index(cg, i, false),
        .struct_literal => |*s| try codegen_struct_literal(cg, s, expected_ty),
        .field_access => |*f| try codegen_field_access(cg, f, false),
        else => unreachable,
    };
}

// --- leaves --- //

fn codegen_literal(cg: *Codegen, l: *ast.LiteralExpr, e: *ast.Expr) !Value {
    const ty = cg.expr_type(e);

    switch (l.kind) {
        .integer => {
            if (numeric.is_float(cg, ty)) {
                const f = try std.fmt.parseFloat(f64, l.raw);
                return llvm.LLVMConstReal(try cg.get_llvm_type_of(ty), f);
            }
            return llvm.LLVMConstInt(try cg.get_llvm_type_of(ty), l.ivalue, 1);
        },
        .float => return llvm.LLVMConstReal(try cg.get_llvm_type_of(ty), l.fvalue),
        .bool_true => return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 1, 0),
        .bool_false => return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 0, 0),
        .char => return llvm.LLVMConstInt(llvm.LLVMInt8TypeInContext(cg.ctx), l.raw[1], 0),
        .string => {
            const name = try cg.cstr(l.raw);
            defer cg.allocator.free(name);
            return llvm.LLVMBuildGlobalString(cg.builder, name.ptr, "");
        },
    }
}

fn codegen_ident(cg: *Codegen, i: *ast.IdentExpr) !Value {
    // load var from stack
    if (cg.stack_map.get(i.name)) |v| {
        return llvm.LLVMBuildLoad2(cg.builder, llvm.LLVMGetAllocatedType(v), v, "");
    }

    if (cg.global_map.get(i.name)) |g| {
        return llvm.LLVMBuildLoad2(cg.builder, llvm.LLVMGlobalGetValueType(g), g, "");
    }
    return error.VariableNotFound;
}

// --- operators --- //

fn codegen_binary(cg: *Codegen, b: *ast.BinaryExpr) anyerror!Value {
    var l = try codegen_expression(cg, b.lhs);
    var r = try codegen_expression(cg, b.rhs);
    const lty = cg.expr_type(b.lhs);
    const rty = cg.expr_type(b.rhs);
    const opty = cg.ts().unify(lty, rty) orelse lty;
    l = try cg.coerce_numeric(l, lty, opty);
    r = try cg.coerce_numeric(r, rty, opty);
    const float = numeric.is_float(cg, opty);
    const signed = numeric.is_signed(cg, opty);

    // TODO: handle overflow and underflow
    if (numeric.arith_of(b.op)) |op| return numeric.build_arith(cg, "bin", op, l, r, float, signed);
    if (numeric.cmp_of(b.op)) |op| return numeric.build_cmp(cg, op, l, r, float, signed, "cmp_bin");
    return switch (b.op) {
        .logical_or => llvm.LLVMBuildOr(cg.builder, l, r, "or_bin"),
        .logical_and => llvm.LLVMBuildAnd(cg.builder, l, r, "and_bin"),
        else => {
            // TODO:
            unreachable;
        },
    };
}

fn codegen_unary(cg: *Codegen, u: *ast.UnaryExpr) anyerror!Value {
    if (u.op == .new) return codegen_new(cg, u.operand);
    if (u.op == .addr_of) return codegen_addr_of(cg, u.operand);

    const e = try codegen_expression(cg, u.operand);
    const oty = cg.expr_type(u.operand);
    const float = numeric.is_float(cg, oty);

    return switch (u.op) {
        .neg => if (float) llvm.LLVMBuildFNeg(cg.builder, e, "neg_un") else llvm.LLVMBuildNeg(cg.builder, e, "neg_un"),
        .bit_not => llvm.LLVMBuildNot(cg.builder, e, "bit_not_un"),
        .not => llvm.LLVMBuildNot(cg.builder, e, "not_un"),
        .deref => blk: {
            const child = cg.ts().get(oty).pointer.child;
            break :blk llvm.LLVMBuildLoad2(cg.builder, try cg.get_llvm_type_of(child), e, "");
        },
        else => {
            // TODO:
            unreachable;
        },
    };
}

// pointer to the place `operand` names
fn codegen_addr_of(cg: *Codegen, operand: *ast.Expr) anyerror!Value {
    return switch (operand.*) {
        .ident => |*i| cg.stack_map.get(i.name) orelse cg.global_map.get(i.name) orelse return error.VariableNotFound,
        .field_access => |*f| try codegen_field_access(cg, f, true),
        .index => |*i| blk: {
            const tty = cg.expr_type(i.target);
            break :blk switch (cg.ts().get(tty).*) {
                .array => try codegen_array_index(cg, i, tty, true),
                .slice => try codegen_slice_index(cg, i, tty, true),
                else => return error.InvalidIndex,
            };
        },
        .unary => |*u| if (u.op == .deref) try codegen_expression(cg, u.operand) else return error.InvalidAddressOf,
        else => return error.InvalidAddressOf,
    };
}

fn codegen_new(cg: *Codegen, expr: *ast.Expr) !Value {
    const type_id = cg.expr_type(expr);
    const llvm_type = try cg.get_llvm_type_of(type_id);
    const size_val = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 8, 0);
    var args = [_]Value{size_val};

    // TODO: handle for wasm target
    const bok_alloc_fn = llvm.LLVMGetNamedFunction(cg.mod, "bok_alloc");
    const bok_alloc_type = llvm.LLVMGlobalGetValueType(bok_alloc_fn);
    const ptr = llvm.LLVMBuildCall2(cg.builder, bok_alloc_type, bok_alloc_fn, &args, args.len, "");

    switch (expr.*) {
        .struct_literal => |*s| {
            for (s.field_inits.items, 0..) |field_init, idx| {
                const name = try cg.cstr(field_init.name);
                defer cg.allocator.free(name);
                const field_ptr = llvm.LLVMBuildStructGEP2(cg.builder, llvm_type, ptr, @intCast(idx), name.ptr);
                const value = try codegen_expression(cg, field_init.value);
                _ = llvm.LLVMBuildStore(cg.builder, value, field_ptr);
            }
        },
        else => unreachable,
    }
    return ptr;
}

// --- aggregates --- //

fn codegen_array(cg: *Codegen, a: *ast.ArrayLiteralExpr, e: *ast.Expr) anyerror!Value {
    const array_ty = try cg.get_llvm_type_of(cg.expr_type(e));
    const arr = llvm.LLVMBuildAlloca(cg.builder, array_ty, "");
    var indices = [2]Value{
        llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0),
        llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0),
    };

    for (a.elements.items, 0..) |ele, idx| {
        indices[1] = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), idx, 0);
        const value = try codegen_expression(cg, ele);
        const gep = llvm.LLVMBuildGEPWithNoWrapFlags(cg.builder, array_ty, arr, &indices, 2, "", 0);
        _ = llvm.LLVMBuildStore(cg.builder, value, gep);
    }
    return arr;
}

fn codegen_struct_literal(cg: *Codegen, s_lit: *ast.StructLiteral, expected_ty: ?llvm.LLVMTypeRef) anyerror!Value {
    const s_ty = if (s_lit.name.len != 0 and !std.mem.eql(u8, s_lit.name, "_"))
        cg.struct_types.get(s_lit.name) orelse return error.NoStructTypeAvailable
    else
        expected_ty orelse return error.NoStructTypeAvailable;

    var struct_value = llvm.LLVMGetUndef(s_ty);
    for (s_lit.field_inits.items, 0..) |*f, idx| {
        const value = try codegen_expression(cg, f.value);
        struct_value = llvm.LLVMBuildInsertValue(cg.builder, struct_value, value, @intCast(idx), "");
    }
    return struct_value;
}

// `assign`: return a pointer to the field instead of its value
pub fn codegen_field_access(cg: *Codegen, f_access: *ast.FieldAccessExpr, assign: bool) anyerror!Value {
    const target_ty = cg.expr_type(f_access.target);
    if (target_ty == .invalid) return error.InvalidType;

    //   Point   -> load Point from stack
    //   *Point  -> load pointer to Point from stack
    var struct_ty_id: types.TypeId = .invalid;
    var struct_ptr: Value = undefined;
    switch (cg.ts().get(target_ty).*) {
        .struct_ty => {
            struct_ty_id = target_ty;
            struct_ptr = try codegen_addr_of(cg, f_access.target);
        },
        .pointer => |p| {
            struct_ty_id = p.child;
            struct_ptr = try codegen_expression(cg, f_access.target);
        },
        .enum_ty => return codegen_enum_field(cg, f_access, target_ty, assign),
        else => return error.InvalidFieldAccess,
    }

    const struct_info = switch (cg.ts().get(struct_ty_id).*) {
        .struct_ty => |s| s,
        else => return error.InvalidFieldAccess,
    };
    const llvm_struct_ty = try cg.get_llvm_type_of(struct_ty_id);

    const field_name = switch (f_access.field.*) {
        .ident => |id| id.name,
        else => {
            std.debug.print("tagname is {s}\n", .{@tagName(f_access.field.*)});
            // TODO:
            unreachable;
        },
    };

    var field_index: usize = 0;
    var field_type: types.TypeId = .invalid;
    var found = false;
    for (struct_info.fields.items, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, field_name)) {
            field_index = i;
            field_type = field.ty;
            found = true;
            break;
        }
    }
    if (!found) return error.UnknownField;

    const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), 0, 0);
    const field_idx = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), field_index, 0);
    var indices = [_]Value{ zero, field_idx };
    const field_ptr = llvm.LLVMBuildGEP2(cg.builder, llvm_struct_ty, struct_ptr, &indices, indices.len, "");

    if (assign) return field_ptr;

    const llvm_field_ty = try cg.get_llvm_type_of(field_type);
    return llvm.LLVMBuildLoad2(cg.builder, llvm_field_ty, field_ptr, "");
}

// `Enum.Variant` (the tag value) or `value.Variant` (the payload of a tagged enum)
fn codegen_enum_field(cg: *Codegen, f: *ast.FieldAccessExpr, enum_ty: types.TypeId, assign: bool) anyerror!Value {
    const field_name = f.field.*.ident.name;

    if (cg.stack_map.get(f.target.ident.name)) |e_st| {
        const var_ty = cg.enum_types.get(field_name) orelse return error.UnknownEnumVariant;
        const payload_ptr = llvm.LLVMBuildStructGEP2(cg.builder, var_ty, e_st, 1, "");
        if (assign) return payload_ptr;
        const payload_ty = llvm.LLVMStructGetTypeAtIndex(var_ty, 1);
        return llvm.LLVMBuildLoad2(cg.builder, payload_ty, payload_ptr, "");
    }

    const enum_info = cg.ts().get(enum_ty).enum_ty;
    for (enum_info.variants.items, 0..) |ev, idx| {
        if (std.mem.eql(u8, ev.name, field_name)) {
            const llvm_ty = try cg.get_llvm_type_of(enum_ty);
            return llvm.LLVMConstInt(llvm_ty, idx, 0);
        }
    }
    return error.UnknownEnumVariant;
}

// --- indexing --- //

fn array_element_gep(cg: *Codegen, array_ty: llvm.LLVMTypeRef, arr: Value, index: Value) Value {
    var indices = [2]Value{
        llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0),
        index,
    };
    return llvm.LLVMBuildGEPWithNoWrapFlags(cg.builder, array_ty, arr, &indices, 2, "", 0);
}

// `ret_gep`: return the element pointer instead of the loaded element
pub fn codegen_slice_index(cg: *Codegen, i: *ast.IndexExpr, slice_ty: types.TypeId, ret_gep: bool) anyerror!Value {
    const slice_llvm_ty = try cg.get_llvm_type_of(slice_ty);
    const slice_ptr = switch (i.target.*) {
        .ident => |ident| cg.stack_map.get(ident.name) orelse return error.UnknownVariable,
        else => unreachable,
    };

    const slice = llvm.LLVMBuildLoad2(cg.builder, slice_llvm_ty, slice_ptr, "");
    const data_ptr = llvm.LLVMBuildExtractValue(cg.builder, slice, 0, "");

    // generate index.
    const index = try codegen_expression(cg, i.args.items[0]);
    const slice_info = switch (cg.ts().get(slice_ty).*) {
        .slice => |s| s,
        else => unreachable,
    };

    var indices = [1]Value{index};
    const elem_ty = try cg.get_llvm_type_of(slice_info.child);
    const element_ptr = llvm.LLVMBuildGEP2(cg.builder, elem_ty, data_ptr, &indices, 1, "");

    // for slice params assigning we need to store in gep ptr not the load inst
    if (ret_gep) return element_ptr;
    return llvm.LLVMBuildLoad2(cg.builder, elem_ty, element_ptr, "");
}

fn codegen_array_index(cg: *Codegen, i: *ast.IndexExpr, array_ty: types.TypeId, ret_gep: bool) anyerror!Value {
    const arr = switch (i.target.*) {
        .ident => |ident| cg.stack_map.get(ident.name) orelse cg.global_map.get(ident.name) orelse return error.UnknownVariable,
        else => try codegen_expression(cg, i.target),
    };
    const llvm_array_ty = try cg.get_llvm_type_of(array_ty);
    const index = try codegen_expression(cg, i.args.items[0]);
    const element_ptr = array_element_gep(cg, llvm_array_ty, arr, index);

    if (ret_gep) return element_ptr;

    const element_ty = llvm.LLVMGetElementType(llvm_array_ty);
    return llvm.LLVMBuildLoad2(cg.builder, element_ty, element_ptr, "");
}

fn codegen_index(cg: *Codegen, i: *ast.IndexExpr, ret_gep: bool) anyerror!Value {
    // todo: Currently only support one-dimensional arrays.
    if (i.args.items.len != 1) return error.InvalidIndex;

    const target_ty = cg.expr_type(i.target);
    return switch (cg.ts().get(target_ty).*) {
        .array => codegen_array_index(cg, i, target_ty, ret_gep),
        .slice => codegen_slice_index(cg, i, target_ty, ret_gep),
        else => error.InvalidIndex,
    };
}

// pointer to `array[index]` (for assignments)
pub fn codegen_array_element_ptr(cg: *Codegen, i: *ast.IndexExpr) !Value {
    if (i.args.items.len != 1) return error.InvalidArrayIndex;

    // for now, array target must be an identifier.
    const arr = switch (i.target.*) {
        .ident => |ident| cg.stack_map.get(ident.name) orelse cg.global_map.get(ident.name) orelse
            return error.UnknownVariable,
        else => return error.UnsupportedArrayTarget,
    };

    const target_ty = cg.expr_type(i.target);
    if (target_ty == .invalid) return error.InvalidType;

    const array_ty = try cg.get_llvm_type_of(target_ty);
    const index = try codegen_expression(cg, i.args.items[0]);
    return array_element_gep(cg, array_ty, arr, index);
}
