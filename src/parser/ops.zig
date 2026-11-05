const token = @import("../token.zig");
const ast = @import("../ast.zig");

pub fn infix_binding_power(op: token.TokenType) [2]usize {
    return switch (op) {
        .pipe_pipe => .{ 1, 2 },
        .amp_amp => .{ 3, 4 },
        .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => .{ 5, 6 },
        .pipe => .{ 7, 8 },
        .caret => .{ 9, 10 },
        .amp => .{ 11, 12 },
        .shl, .shr => .{ 13, 14 },
        .dot_dot, .dot_dot_eq => .{ 15, 16 },
        .plus, .minus => .{ 17, 18 },
        .star, .slash, .percent => .{ 19, 20 },
        else => .{ 0, 0 },
    };
}

pub fn prefix_binding_power(op: token.TokenType) [2]usize {
    return switch (op) {
        .minus, .bang, .tilde, .amp, .star, .kw_new => .{ 0, 21 },
        else => .{ 0, 0 },
    };
}

pub fn postfix_binding_power(op: token.TokenType) ?[2]usize {
    return switch (op) {
        .l_paren, .dot, .l_bracket, .kw_where => .{ 21, 22 },
        else => null,
    };
}

pub fn get_binary_op(op: token.TokenType) ast.BinaryOp {
    return switch (op) {
        .plus => ast.BinaryOp.add,
        .minus => ast.BinaryOp.sub,
        .star => ast.BinaryOp.mul,
        .slash => ast.BinaryOp.div,
        .percent => ast.BinaryOp.mod,
        .eq_eq => ast.BinaryOp.eq,
        .gt_eq => ast.BinaryOp.ge,
        .lt_eq => ast.BinaryOp.le,
        .bang_eq => ast.BinaryOp.ne,
        .gt => ast.BinaryOp.gt,
        .lt => ast.BinaryOp.lt,
        .pipe => ast.BinaryOp.bit_or,
        .caret => ast.BinaryOp.bit_xor,
        .amp => ast.BinaryOp.bit_and,
        .amp_amp => ast.BinaryOp.logical_and,
        .pipe_pipe => ast.BinaryOp.logical_or,
        .shl => ast.BinaryOp.shl,
        .shr => ast.BinaryOp.shr,
        .dot_dot => ast.BinaryOp.range,
        .dot_dot_eq => ast.BinaryOp.range_incl,
        else => unreachable,
    };
}

pub fn get_unary_op(op: token.TokenType) ast.UnaryOp {
    return switch (op) {
        .minus => ast.UnaryOp.neg,
        .bang => ast.UnaryOp.not,
        .tilde => ast.UnaryOp.bit_not,
        .amp => ast.UnaryOp.addr_of,
        .star => ast.UnaryOp.deref,
        .kw_new => ast.UnaryOp.new,
        else => unreachable,
    };
}

pub fn get_bool_type(op: token.TokenType) ast.LiteralKind {
    return switch (op) {
        .kw_true => ast.LiteralKind.bool_true,
        .kw_false => ast.LiteralKind.bool_false,
        else => unreachable,
    };
}

pub fn get_compound_op(ty: token.TokenType) ?ast.CompoundOp {
    return switch (ty) {
        .plus_eq => ast.CompoundOp.add,
        .minus_eq => ast.CompoundOp.sub,
        .star_eq => ast.CompoundOp.mul,
        .slash_eq => ast.CompoundOp.div,
        .percent_eq => ast.CompoundOp.mod,
        .amp_eq => ast.CompoundOp.bit_and,
        .pipe_eq => ast.CompoundOp.bit_or,
        .caret_eq => ast.CompoundOp.bit_xor,
        .shl_eq => ast.CompoundOp.shl,
        .shr_eq => ast.CompoundOp.shr,
        else => null,
    };
}
