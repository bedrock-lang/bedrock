// if / while / for / match.

const std = @import("std");
const llvm = @import("llvm");
const ast = @import("../ast.zig");
const types = @import("../sema/type_system.zig");
const Codegen = @import("codegen.zig").Codegen;
const numeric = @import("numeric.zig");

const Value = llvm.LLVMValueRef;
const Block = llvm.LLVMBasicBlockRef;

pub fn codegen_control_flow(cg: *Codegen, cf: *ast.ControlFlowStmt) anyerror!void {
    switch (cf.*) {
        .if_expr => |*i| try codegen_if(cg, i),
        .while_expr => |*w| try codegen_while(cg, w),
        .for_expr => |*f| try codegen_for(cg, f),
        .match_expr => |*m| try codegen_match(cg, m),
    }
}

// --- helpers --- //

fn parent_function(cg: *Codegen) llvm.LLVMValueRef {
    return llvm.LLVMGetBasicBlockParent(cg.entry);
}

fn new_block(cg: *Codegen, name: [*c]const u8) Block {
    return llvm.LLVMAppendBasicBlockInContext(cg.ctx, parent_function(cg), name);
}

// jump to `target`, unless the current block already ended (return / break / ...)
fn br_if_open(cg: *Codegen, target: Block) void {
    const cur = llvm.LLVMGetInsertBlock(cg.builder);
    if (llvm.LLVMGetBasicBlockTerminator(cur) == null) {
        _ = llvm.LLVMBuildBr(cg.builder, target);
    }
}

// conditions are allowed to be wider than i1, those compare `!= 0`
fn to_i1(cg: *Codegen, cond: Value) Value {
    const width = llvm.LLVMGetIntTypeWidth(llvm.LLVMTypeOf(cond));
    if (width == 1) return cond;
    const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), 0, 0);
    return llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntNE, cond, zero, "");
}

fn at(cg: *Codegen, block: Block) void {
    llvm.LLVMPositionBuilderAtEnd(cg.builder, block);
}

// a loop body: `break` goes to `break_bb`, `continue` to `continue_bb`
fn loop_body(cg: *Codegen, body: std.ArrayList(ast.Stmt), break_bb: Block, continue_bb: Block) !void {
    try cg.break_targets.append(cg.allocator, break_bb);
    try cg.continue_targets.append(cg.allocator, continue_bb);
    defer {
        _ = cg.break_targets.pop();
        _ = cg.continue_targets.pop();
    }
    try cg.codegen_statements(body);
}

// --- if --- //

fn codegen_if(cg: *Codegen, i: *ast.IfExpr) !void {
    const then_bb = new_block(cg, "");

    const elif_bbs = try cg.allocator.alloc(Block, i.elifs.items.len);
    defer cg.allocator.free(elif_bbs);
    const elif_then_bbs = try cg.allocator.alloc(Block, i.elifs.items.len);
    defer cg.allocator.free(elif_then_bbs);
    for (elif_bbs, elif_then_bbs) |*cond_bb, *body_bb| {
        cond_bb.* = new_block(cg, "");
        body_bb.* = new_block(cg, "");
    }

    const else_bb = new_block(cg, "");
    const merge_bb = new_block(cg, "");

    const first_false_bb = if (elif_bbs.len > 0) elif_bbs[0] else else_bb;
    const cond = to_i1(cg, try cg.codegen_expression(i.cond));
    _ = llvm.LLVMBuildCondBr(cg.builder, cond, then_bb, first_false_bb);

    at(cg, then_bb);
    try cg.codegen_statements(i.then_body);
    br_if_open(cg, merge_bb);

    for (i.elifs.items, 0..) |*elif, idx| {
        at(cg, elif_bbs[idx]);
        const elif_cond = to_i1(cg, try cg.codegen_expression(elif.cond));
        const next = if (idx + 1 < elif_bbs.len) elif_bbs[idx + 1] else else_bb;
        _ = llvm.LLVMBuildCondBr(cg.builder, elif_cond, elif_then_bbs[idx], next);

        at(cg, elif_then_bbs[idx]);
        try cg.codegen_statements(elif.body);
        br_if_open(cg, merge_bb);
    }

    at(cg, else_bb);
    if (i.else_body) |body| try cg.codegen_statements(body);
    br_if_open(cg, merge_bb);

    at(cg, merge_bb);
}

// --- while --- //

fn codegen_while(cg: *Codegen, w: *ast.WhileExpr) !void {
    const cond_bb = new_block(cg, "");
    const while_bb = new_block(cg, "");
    const merge_bb = new_block(cg, "");

    // jmp to while condition block
    _ = llvm.LLVMBuildBr(cg.builder, cond_bb);
    at(cg, cond_bb);
    const cond = to_i1(cg, try cg.codegen_expression(w.cond));
    _ = llvm.LLVMBuildCondBr(cg.builder, cond, while_bb, merge_bb);

    at(cg, while_bb);
    try loop_body(cg, w.body, merge_bb, cond_bb);
    br_if_open(cg, cond_bb);

    at(cg, merge_bb);
}

// --- for --- //

fn codegen_for(cg: *Codegen, f: *ast.ForExpr) !void {
    // todo: slices based iterations
    const iter_ty = cg.expr_type(f.iterable);
    switch (cg.ts().get(iter_ty).*) {
        .range => |r| try codegen_for_range(cg, f, r.elem),
        .array => |a| try codegen_array_iter(cg, f, a.child, a.len),
        else => unreachable, // sema sambhal lega
    }
}

// allocates the optional `index` binding of `for (i, x) ...`
fn enumerate_setup(cg: *Codegen, f: *ast.ForExpr) !?Value {
    const ib = f.index_binding orelse return null;
    const start_ty = try cg.get_llvm_type_of(cg.expr_type(f.index_start.?));
    const start_val = try cg.codegen_expression(f.index_start.?);
    const alloca = llvm.LLVMBuildAlloca(cg.builder, start_ty, "");
    _ = llvm.LLVMBuildStore(cg.builder, start_val, alloca);
    try cg.stack_map.put(ib, alloca);
    return alloca;
}

fn enumerate_increment(cg: *Codegen, enum_alloca: ?Value) void {
    const alloca = enum_alloca orelse return;
    const ty = llvm.LLVMGetAllocatedType(alloca);
    const cur = llvm.LLVMBuildLoad2(cg.builder, ty, alloca, "");
    const next = llvm.LLVMBuildAdd(cg.builder, cur, llvm.LLVMConstInt(ty, 1, 0), "enum_inc");
    _ = llvm.LLVMBuildStore(cg.builder, next, alloca);
}

fn codegen_array_iter(cg: *Codegen, f: *ast.ForExpr, ty: types.TypeId, len: u64) !void {
    const llvm_ty = try cg.get_llvm_type_of(ty);
    const array_ptr = switch (f.iterable.*) {
        .ident => |ident| cg.stack_map.get(ident.name) orelse return error.UnknownVariable,
        else => return error.UnsupportedArrayTarget,
    };
    const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
    const l = llvm.LLVMConstInt(i64_ty, len, 0);

    const cond_bb = new_block(cg, "for_cond");
    const body_bb = new_block(cg, "for_body");
    const merge_bb = new_block(cg, "for_merge");
    const inc_bb = new_block(cg, "inc_bb");

    // index variable.
    const index_alloca = llvm.LLVMBuildAlloca(cg.builder, i64_ty, "for_index");
    _ = llvm.LLVMBuildStore(cg.builder, llvm.LLVMConstInt(i64_ty, 0, 0), index_alloca);

    const name = try cg.cstr(f.binding);
    defer cg.allocator.free(name);
    const i_alloca = llvm.LLVMBuildAlloca(cg.builder, llvm_ty, name.ptr);
    const e_alloca = try enumerate_setup(cg, f);
    try cg.stack_map.put(f.binding, i_alloca);

    _ = llvm.LLVMBuildBr(cg.builder, cond_bb);

    at(cg, cond_bb);
    const index = llvm.LLVMBuildLoad2(cg.builder, i64_ty, index_alloca, "index");
    const cond = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntULT, index, l, "for_cmp");
    _ = llvm.LLVMBuildCondBr(cg.builder, cond, body_bb, merge_bb);

    at(cg, body_bb);
    var indices = [2]Value{ llvm.LLVMConstInt(i64_ty, 0, 0), index };
    const gep = llvm.LLVMBuildGEPWithNoWrapFlags(cg.builder, llvm.LLVMArrayType2(llvm_ty, len), array_ptr, &indices, 2, "", 0);
    const ele = llvm.LLVMBuildLoad2(cg.builder, llvm_ty, gep, "ele");
    _ = llvm.LLVMBuildStore(cg.builder, ele, i_alloca);

    try loop_body(cg, f.body, merge_bb, inc_bb);
    br_if_open(cg, inc_bb);

    // i = i + 1
    at(cg, inc_bb);
    const curr = llvm.LLVMBuildLoad2(cg.builder, i64_ty, index_alloca, "index");
    const next = llvm.LLVMBuildAdd(cg.builder, curr, llvm.LLVMConstInt(i64_ty, 1, 0), "for_inc");
    _ = llvm.LLVMBuildStore(cg.builder, next, index_alloca);
    enumerate_increment(cg, e_alloca);
    _ = llvm.LLVMBuildBr(cg.builder, cond_bb);

    at(cg, merge_bb);
}

fn codegen_for_range(cg: *Codegen, f: *ast.ForExpr, ty: types.TypeId) !void {
    const llvm_ty = try cg.get_llvm_type_of(ty);

    const b = &f.iterable.binary;
    var lo = try cg.codegen_expression(b.lhs);
    var hi = try cg.codegen_expression(b.rhs);
    lo = try cg.coerce_numeric(lo, cg.expr_type(b.lhs), ty);
    hi = try cg.coerce_numeric(hi, cg.expr_type(b.rhs), ty);

    const cond_bb = new_block(cg, "for_cond");
    const body_bb = new_block(cg, "for_body");
    const inc_bb = new_block(cg, "inc_bb");
    const merge_bb = new_block(cg, "for_merge");

    const name = try cg.cstr(f.binding);
    defer cg.allocator.free(name);
    const i_alloca = llvm.LLVMBuildAlloca(cg.builder, llvm_ty, name.ptr);
    const e_alloca = try enumerate_setup(cg, f);
    _ = llvm.LLVMBuildStore(cg.builder, lo, i_alloca);
    try cg.stack_map.put(f.binding, i_alloca);

    _ = llvm.LLVMBuildBr(cg.builder, cond_bb);
    at(cg, cond_bb);

    const float = numeric.is_float(cg, ty);
    const signed = numeric.is_signed(cg, ty);
    const i_val = llvm.LLVMBuildLoad2(cg.builder, llvm_ty, i_alloca, "");
    const is_inclusive = b.op == .range_incl; // the range is inclusize (..=)
    const cond = numeric.build_cmp(cg, if (is_inclusive) .le else .lt, i_val, hi, float, signed, "for_cmp");
    _ = llvm.LLVMBuildCondBr(cg.builder, cond, body_bb, merge_bb);

    at(cg, body_bb);
    try loop_body(cg, f.body, merge_bb, inc_bb);
    br_if_open(cg, inc_bb);

    // do the i = i + 1
    at(cg, inc_bb);
    const cur = llvm.LLVMBuildLoad2(cg.builder, llvm_ty, i_alloca, "");
    const one = if (float) llvm.LLVMConstReal(llvm_ty, 1.0) else llvm.LLVMConstInt(llvm_ty, 1, 0);
    const next = if (float) llvm.LLVMBuildFAdd(cg.builder, cur, one, "for_inc") else llvm.LLVMBuildAdd(cg.builder, cur, one, "for_inc");
    _ = llvm.LLVMBuildStore(cg.builder, next, i_alloca);
    enumerate_increment(cg, e_alloca);
    _ = llvm.LLVMBuildBr(cg.builder, cond_bb);

    at(cg, merge_bb);
}

// --- match --- //

fn codegen_match(cg: *Codegen, m: *ast.MatchExpr) !void {
    const sub = try cg.codegen_expression(m.subject);
    const sub_ty = llvm.LLVMTypeOf(sub);

    const default_bb = new_block(cg, "");
    const merge_bb = new_block(cg, "");

    const arm_bbs = try cg.allocator.alloc(Block, m.arms.items.len);
    defer cg.allocator.free(arm_bbs);

    const sw = llvm.LLVMBuildSwitch(cg.builder, sub, default_bb, @intCast(m.arms.items.len));
    for (m.arms.items, arm_bbs) |*arm, *arm_bb| {
        arm_bb.* = new_block(cg, "match_arm");
        const case_val = try codegen_match_pattern(cg, &arm.pattern, sub_ty);
        llvm.LLVMAddCase(sw, case_val, arm_bb.*);
    }

    for (m.arms.items, arm_bbs) |*arm, arm_bb| {
        at(cg, arm_bb);
        try cg.codegen_statements(arm.body);
        br_if_open(cg, merge_bb);
    }

    // else arm
    at(cg, default_bb);
    if (m.else_body) |body| try cg.codegen_statements(body);
    br_if_open(cg, merge_bb);

    at(cg, merge_bb);
}

fn codegen_match_pattern(cg: *Codegen, p: *ast.Pattern, subject_ty: llvm.LLVMTypeRef) !Value {
    switch (p.*) {
        .integer => |s| {
            const v = try std.fmt.parseInt(i64, s, 0);
            return llvm.LLVMConstInt(subject_ty, @bitCast(v), 1);
        },
        .boolean => |b| return llvm.LLVMConstInt(subject_ty, @intFromBool(b), 0),
        .field_variant => |e| {
            // NOTE: doing `codegen_expression` on `field_variant` is resulted into an error, see the previous commit for stack trace log
            const fa = switch (e.*) {
                .field_access => |*fa| fa,
                else => return error.UnsupportedPattern,
            };
            const enum_name = switch (fa.target.*) {
                .ident => |id| id.name,
                else => return error.UnsupportedPattern,
            };
            const variant_name = switch (fa.field.*) {
                .ident => |id| id.name,
                else => return error.UnsupportedPattern,
            };

            const enum_id = cg.ts().resolve(enum_name) orelse return error.UnknownEnum;
            const enum_info = switch (cg.ts().get(enum_id).*) {
                .enum_ty => |en| en,
                else => return error.UnknownEnum,
            };
            for (enum_info.variants.items, 0..) |ev, idx| {
                if (std.mem.eql(u8, ev.name, variant_name)) {
                    return llvm.LLVMConstInt(subject_ty, idx, 0);
                }
            }
            return error.UnknownEnumVariant;
        },
        else => return error.UnsupportedPattern,
    }
}
