const std = @import("std");
const llvm = @import("llvm");
const ast = @import("../ast.zig");
const Codegen = @import("codegen.zig").Codegen;
const numeric = @import("numeric.zig");
const expr_mod = @import("expr.zig");
const control_flow = @import("control_flow.zig");

const Value = llvm.LLVMValueRef;

pub fn codegen_statements(cg: *Codegen, stmts: std.ArrayList(ast.Stmt)) anyerror!void {
    for (stmts.items) |*stmt| {
        switch (stmt.*) {
            .return_stmt => |*r| try codegen_return(cg, r),
            .expr_stmt => |*e| try codegen_expression_statement(cg, e),
            .var_stmt => |*v| try codegen_local(cg, v.name, v.type_ann, v.value),
            .const_stmt => |*c| try codegen_local(cg, c.name, c.type_ann, c.value),
            .assign_stmt => |*a| try codegen_assign(cg, a),
            .control_flow_stmt => |*c| try control_flow.codegen_control_flow(cg, c),
            .break_stmt => _ = llvm.LLVMBuildBr(cg.builder, cg.break_targets.getLast()),
            .continue_stmt => _ = llvm.LLVMBuildBr(cg.builder, cg.continue_targets.getLast()),
            else => {
                // TODO:
                unreachable;
            },
        }
    }
}

fn codegen_return(cg: *Codegen, r: *ast.ReturnStmt) !void {
    if (r.value) |e| {
        const val = try cg.codegen_expression(e);
        _ = llvm.LLVMBuildRet(cg.builder, val);
        return;
    }
    _ = llvm.LLVMBuildRetVoid(cg.builder);
}

fn codegen_expression_statement(cg: *Codegen, e_stmt: *ast.ExprStmt) !void {
    const e = e_stmt.value orelse unreachable;
    _ = try cg.codegen_expression(e);
}

fn alloca_for(cg: *Codegen, name: []const u8, type_ann: ?*ast.Type, value: *ast.Expr) !Value {
    const t = if (type_ann) |ann| try cg.get_type(ann) else try cg.get_llvm_type_of(cg.expr_type(value));
    const n = try cg.cstr(name);
    defer cg.allocator.free(n);
    return llvm.LLVMBuildAlloca(cg.builder, t, n.ptr);
}

fn codegen_local(cg: *Codegen, name: []const u8, type_ann: ?*ast.Type, value: *ast.Expr) !void {
    switch (value.*) {
        .array_literal => {
            const arr = try cg.codegen_expression(value);
            try cg.stack_map.put(name, arr);
        },
        .struct_literal => {
            const alloca = try alloca_for(cg, name, type_ann, value);
            const expected_ty = if (type_ann) |ty| try cg.get_type(ty) else null;
            const s = try cg.codegen_expression_with_type(value, expected_ty);
            _ = llvm.LLVMBuildStore(cg.builder, s, alloca);
            try cg.stack_map.put(name, alloca);
        },
        else => {
            // tagged enum
            if (type_ann) |ann| {
                switch (ann.base) {
                    .named => |*n| if (cg.enum_types.get(n.name)) |enum_ty| {
                        return codegen_tagged_enum(cg, name, value, n.name, enum_ty);
                    },
                    else => {},
                }
            }

            const alloca = try alloca_for(cg, name, type_ann, value);
            if (value.* == .undefined) {
                try cg.stack_map.put(name, alloca);
                return;
            }
            var e = try cg.codegen_expression(value);
            if (type_ann) |ann| {
                if (ann.base == .primitive) {
                    const target_ty = try cg.ts().from_ast_primitive(ann.base.primitive);
                    e = try cg.coerce_numeric(e, cg.expr_type(value), target_ty);
                }
            }
            // store value on stack space
            _ = llvm.LLVMBuildStore(cg.builder, e, alloca);
            try cg.stack_map.put(name, alloca);
        },
    }
}

fn codegen_tagged_enum(cg: *Codegen, name: []const u8, value: *ast.Expr, enum_name: []const u8, enum_ty: llvm.LLVMTypeRef) !void {
    const call = switch (value.*) {
        .call => |*c| c,
        else => unreachable,
    };

    const enum_name_z = try cg.cstr(enum_name);
    defer cg.allocator.free(enum_name_z);
    const e_alloca = llvm.LLVMBuildAlloca(cg.builder, enum_ty, enum_name_z.ptr);
    // pointer to the first element of type i8 (the tag)
    const tag_ptr = llvm.LLVMBuildStructGEP2(cg.builder, enum_ty, e_alloca, 0, "");

    // TODO: fix this spliting workaround with normal target and field type
    const id = call.callee.*.ident.name;
    const active = if (std.mem.lastIndexOfScalar(u8, id, '.')) |dot| id[dot + 1 ..] else id;
    const var_ty = cg.enum_types.get(active) orelse return error.NoEnumVariant;
    const var_tag = cg.enum_tag.get(active) orelse return error.NoEnumVariant;

    // set the tag value
    const tag = llvm.LLVMConstInt(llvm.LLVMInt8TypeInContext(cg.ctx), @intCast(var_tag), 0);
    _ = llvm.LLVMBuildStore(cg.builder, tag, tag_ptr);

    const u_cast = llvm.LLVMBuildBitCast(cg.builder, e_alloca, llvm.LLVMPointerType(var_ty, 0), "");
    for (call.args.items) |*a| {
        const u_exp = try cg.codegen_expression(a.value);
        const u_ptr = llvm.LLVMBuildStructGEP2(cg.builder, var_ty, u_cast, 1, "");
        _ = llvm.LLVMBuildStore(cg.builder, u_exp, u_ptr);
        // so later code can find the variable
        try cg.stack_map.put(name, e_alloca);
    }
}

fn codegen_assign(cg: *Codegen, a: *ast.AssignStmt) !void {
    switch (a.target.*) {
        .ident => |*i| try assign_ident(cg, a, i.name),
        .index => |*i| try assign_index(cg, a, i),
        .field_access => |*f| {
            const rhs = try cg.codegen_expression_with_type(a.value, null);
            const ptr = try expr_mod.codegen_field_access(cg, f, true);
            try assign_through(cg, a, ptr, rhs);
        },
        else => {
            // TODO:
        },
    }
}

fn assign_ident(cg: *Codegen, a: *ast.AssignStmt, name: []const u8) !void {
    const ty = cg.expr_type(a.target);
    const llvm_ty = try cg.get_llvm_type_of(ty);
    const e = try cg.codegen_expression_with_type(a.value, llvm_ty);
    if (std.mem.eql(u8, name, "_")) return; // discarded

    // lookup for var on stack
    const ptr = cg.stack_map.get(name) orelse cg.global_map.get(name) orelse return error.VariableNotFound;

    // `a = <array>` (undefined array updation) rebinds the name to the new array
    if (a.op == null and cg.ts().get(ty).* == .array) {
        try cg.stack_map.put(name, e);
        return;
    }
    try assign_through(cg, a, ptr, e);
}

fn assign_index(cg: *Codegen, a: *ast.AssignStmt, i: *ast.IndexExpr) !void {
    const rhs = try cg.codegen_expression_with_type(a.value, null);
    const target_ty = cg.expr_type(i.target);
    const ptr = switch (cg.ts().get(target_ty).*) {
        .array => try expr_mod.codegen_array_element_ptr(cg, i),
        .slice => try expr_mod.codegen_slice_index(cg, i, target_ty, true),
        else => return error.InvalidIndex,
    };
    try assign_through(cg, a, ptr, rhs);
}

fn assign_through(cg: *Codegen, a: *ast.AssignStmt, ptr: Value, rhs: Value) !void {
    const ty = cg.expr_type(a.target);
    const e = try cg.coerce_numeric(rhs, cg.expr_type(a.value), ty);

    const op = a.op orelse {
        _ = llvm.LLVMBuildStore(cg.builder, e, ptr);
        return;
    };
    const old = llvm.LLVMBuildLoad2(cg.builder, try cg.get_llvm_type_of(ty), ptr, "");
    const result = numeric.compound_op(cg, op, old, e, numeric.is_signed(cg, ty));
    _ = llvm.LLVMBuildStore(cg.builder, result, ptr);
}
