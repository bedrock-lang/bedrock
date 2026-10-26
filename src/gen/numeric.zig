const std = @import("std");
const llvm = @import("llvm");
const ast = @import("../ast.zig");
const types = @import("../sema/type_system.zig");
const Codegen = @import("codegen.zig").Codegen;

const Value = llvm.LLVMValueRef;

pub fn is_float(cg: *Codegen, ty: types.TypeId) bool {
    const ts = cg.ts();
    return ts.is_numeric(ty) and !ts.is_integer(ty);
}

pub fn is_signed(cg: *Codegen, ty: types.TypeId) bool {
    const ts = cg.ts();
    return ts.is_integer(ty) and !ts.is_unsigned(ty);
}

pub fn coerce(cg: *Codegen, val: Value, from: types.TypeId, to: types.TypeId) !Value {
    if (from == .invalid or to == .invalid or from == to) return val;
    const llvm_ty = try cg.get_llvm_type_of(to);
    if (llvm.LLVMTypeOf(val) == llvm_ty) return val; // for like isize and i64 or usize and u64

    const from_is_float = is_float(cg, from);
    const to_is_float = is_float(cg, to);

    if (from_is_float and to_is_float) return llvm.LLVMBuildFPExt(cg.builder, val, llvm_ty, "fpext");
    if (!from_is_float and to_is_float) {
        return if (is_signed(cg, from)) llvm.LLVMBuildSIToFP(cg.builder, val, llvm_ty, "sitofp") else llvm.LLVMBuildUIToFP(cg.builder, val, llvm_ty, "uitofp");
    }
    if (!from_is_float and !to_is_float) {
        return if (is_signed(cg, from)) llvm.LLVMBuildSExt(cg.builder, val, llvm_ty, "sext") else llvm.LLVMBuildZExt(cg.builder, val, llvm_ty, "zext");
    }
    return val;
}

pub const ArithOp = enum { add, sub, mul, div, mod, bit_or, bit_xor, bit_and, shl, shr };
pub const CmpOp = enum { eq, ne, lt, gt, le, ge };

pub fn arith_of(op: anytype) ?ArithOp {
    return std.meta.stringToEnum(ArithOp, @tagName(op));
}

pub fn cmp_of(op: anytype) ?CmpOp {
    return std.meta.stringToEnum(CmpOp, @tagName(op));
}

pub fn build_arith(cg: *Codegen, comptime suffix: []const u8, op: ArithOp, l: Value, r: Value, float: bool, signed: bool) Value {
    const b = cg.builder;
    return switch (op) {
        .add => if (float) llvm.LLVMBuildFAdd(b, l, r, "add_" ++ suffix) else llvm.LLVMBuildAdd(b, l, r, "add_" ++ suffix),
        .sub => if (float) llvm.LLVMBuildFSub(b, l, r, "sub_" ++ suffix) else llvm.LLVMBuildSub(b, l, r, "sub_" ++ suffix),
        .mul => if (float) llvm.LLVMBuildFMul(b, l, r, "mul_" ++ suffix) else llvm.LLVMBuildMul(b, l, r, "mul_" ++ suffix),
        .div => if (float) llvm.LLVMBuildFDiv(b, l, r, "div_" ++ suffix) else if (signed) llvm.LLVMBuildSDiv(b, l, r, "div_" ++ suffix) else llvm.LLVMBuildUDiv(b, l, r, "div_" ++ suffix),
        .mod => if (float) llvm.LLVMBuildFRem(b, l, r, "mod_" ++ suffix) else if (signed) llvm.LLVMBuildSRem(b, l, r, "mod_" ++ suffix) else llvm.LLVMBuildURem(b, l, r, "mod_" ++ suffix),
        .bit_or => llvm.LLVMBuildOr(b, l, r, "log_" ++ suffix),
        .bit_xor => llvm.LLVMBuildXor(b, l, r, "log_" ++ suffix),
        .bit_and => llvm.LLVMBuildAnd(b, l, r, "log_" ++ suffix),
        .shl => llvm.LLVMBuildShl(b, l, r, "shift_" ++ suffix),
        .shr => if (signed) llvm.LLVMBuildAShr(b, l, r, "shift_" ++ suffix) else llvm.LLVMBuildLShr(b, l, r, "shift_" ++ suffix),
    };
}

pub fn build_cmp(cg: *Codegen, op: CmpOp, l: Value, r: Value, float: bool, signed: bool, name: [*:0]const u8) Value {
    if (float) {
        const pred: llvm.LLVMRealPredicate = switch (op) {
            .eq => llvm.LLVMRealOEQ,
            .ne => llvm.LLVMRealONE,
            .lt => llvm.LLVMRealOLT,
            .gt => llvm.LLVMRealOGT,
            .le => llvm.LLVMRealOLE,
            .ge => llvm.LLVMRealOGE,
        };
        return llvm.LLVMBuildFCmp(cg.builder, pred, l, r, name);
    }
    const pred: llvm.LLVMIntPredicate = switch (op) {
        .eq => llvm.LLVMIntEQ,
        .ne => llvm.LLVMIntNE,
        .lt => if (signed) llvm.LLVMIntSLT else llvm.LLVMIntULT,
        .gt => if (signed) llvm.LLVMIntSGT else llvm.LLVMIntUGT,
        .le => if (signed) llvm.LLVMIntSLE else llvm.LLVMIntULE,
        .ge => if (signed) llvm.LLVMIntSGE else llvm.LLVMIntUGE,
    };
    return llvm.LLVMBuildICmp(cg.builder, pred, l, r, name);
}

pub fn compound_op(cg: *Codegen, op: ast.CompoundOp, l: Value, r: Value, signed: bool) Value {
    const kind = llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(l));
    const float = kind == llvm.LLVMFloatTypeKind or kind == llvm.LLVMDoubleTypeKind;
    const aop = arith_of(op).?;
    // note: has always been a logical shift, even on signed types
    return build_arith(cg, "compound", aop, l, r, float, signed and aop != .shr);
}
