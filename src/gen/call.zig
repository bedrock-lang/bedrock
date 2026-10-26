const std = @import("std");
const llvm = @import("llvm");
const ast = @import("../ast.zig");
const types = @import("../sema/type_system.zig");
const Codegen = @import("codegen.zig").Codegen;
const lower_types = @import("lower_types.zig");

const log = std.log.scoped(.codegen);
const Value = llvm.LLVMValueRef;

pub fn codegen_call(cg: *Codegen, c: *ast.CallExpr) anyerror!Value {
    // NOTE: assume callee is an ident (sema lowers method calls into one)
    const name = switch (c.callee.*) {
        .ident => |i| i.name,
        else => {
            // TODO:
            unreachable;
        },
    };

    const name_z = try cg.cstr(name);
    defer cg.allocator.free(name_z);
    const func_ref = llvm.LLVMGetNamedFunction(cg.mod, name_z.ptr) orelse {
        log.err("no function named {s}\n", .{name});
        return error.FunctionNotFound;
    };

    const param_types = switch (cg.ts().get(cg.expr_type(c.callee)).*) {
        .function => |f| f.params.items,
        .procedure => |p| p.params.items,
        else => unreachable,
    };

    const func_type = llvm.LLVMGlobalGetValueType(func_ref);
    const args = try codegen_args(cg, c.args, param_types);
    defer cg.allocator.free(args);

    return llvm.LLVMBuildCall2(cg.builder, func_type, func_ref, args.ptr, @intCast(c.args.items.len), "");
}

fn codegen_args(cg: *Codegen, args: std.ArrayList(ast.CallArg), param_types: []const types.TypeId) ![]Value {
    const out = try cg.allocator.alloc(Value, args.items.len);
    for (args.items, 0..) |arg, idx| {
        const arg_ty = cg.expr_type(arg.value);
        const param_ty: ?types.TypeId = if (idx < param_types.len) param_types[idx] else null;

        if (param_ty) |pty| {
            if (is_array_slice_conversion(cg, arg_ty, pty)) {
                out[idx] = try codegen_array_as_slice(cg, arg.value, arg_ty);
                continue;
            }
        }

        var v = try cg.codegen_expression(arg.value);
        // for passing array literal by value
        if (arg.value.* == .array_literal) {
            const llvm_type = try cg.get_llvm_type_of(arg_ty);
            v = llvm.LLVMBuildLoad2(cg.builder, llvm_type, v, "");
        }
        out[idx] = if (param_ty) |pty| try cg.coerce_numeric(v, arg_ty, pty) else v;
    }
    return out;
}

fn is_array_slice_conversion(cg: *Codegen, arg_ty: types.TypeId, param_ty: types.TypeId) bool {
    const ts = cg.ts();
    return ts.get(arg_ty).* == .array and ts.get(param_ty).* == .slice;
}

fn codegen_array_as_slice(cg: *Codegen, operand: *ast.Expr, array_ty: types.TypeId) !Value {
    const array_info = switch (cg.ts().get(array_ty).*) {
        .array => |a| a,
        else => unreachable,
    };

    const array_ptr = switch (operand.*) {
        .ident => |ident| cg.stack_map.get(ident.name).?,
        .array_literal => try cg.codegen_expression(operand),
        else => unreachable,
    };

    const llvm_array_ty = try cg.get_llvm_type_of(array_ty);
    var indices = [_]Value{
        llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0),
        llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0),
    };
    const elem_ptr = llvm.LLVMBuildGEP2(cg.builder, llvm_array_ty, array_ptr, &indices, indices.len, "slice_ptr");

    const elem_ty = try cg.get_llvm_type_of(array_info.child);
    var slice = llvm.LLVMGetUndef(lower_types.slice_type(cg, elem_ty));
    slice = llvm.LLVMBuildInsertValue(cg.builder, slice, elem_ptr, 0, "slice_ptr");
    slice = llvm.LLVMBuildInsertValue(
        cg.builder,
        slice,
        llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), array_info.len, 0),
        1,
        "slice_len",
    );
    return slice;
}
