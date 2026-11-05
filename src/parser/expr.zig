const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const ops = @import("ops.zig");
const Parser = @import("parser.zig").Parser;

const stmt_mod = @import("stmt.zig");

pub fn parse_expression(self: *Parser) anyerror!*ast.Expr {
    return try parse_expression_bp(self, 0);
}

pub fn parse_expression_bp(self: *Parser, min_bp: usize) !*ast.Expr {
    var lhs: *ast.Expr = undefined;
    var tok = try self.lexer.next();
    switch (tok.type) {
        .integer => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .literal = try parse_int_literal(self, tok) };
        },
        .float => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .literal = try parse_float_literal(self, tok) };
        },
        .ident => {
            lhs = try self.allocator.create(ast.Expr);
            // can be a call expression
            const peek_tok = try self.lexer.peek_token();
            if (peek_tok.type == token.TokenType.l_paren) {
                // TODO:
            }
            lhs.* = .{ .ident = .{
                .name = tok.val,
                .token = tok,
            } };
        },
        .kw_false, .kw_true => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .literal = .{
                .kind = ops.get_bool_type(tok.type),
                .raw = tok.val,
                .token = tok,
            } };
        },
        .kw_nil => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .nil = .{ .token = tok } };
        },
        .kw_undefined => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .undefined = .{ .token = tok } };
        },
        .l_paren => {
            lhs = try parse_expression_bp(self, 0);
            // expect ')'
            _ = try self.expect(.r_paren, "expected ')'");
        },
        .minus, .bang, .tilde, .amp, .star, .kw_new => {
            const p_bp = ops.prefix_binding_power(tok.type);
            const rhs = try parse_expression_bp(self, p_bp[1]);
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{
                .unary = .{
                    .op = ops.get_unary_op(tok.type),
                    .operand = rhs,
                    .token = tok,
                },
            };
        },
        .string => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .literal = .{
                .kind = ast.LiteralKind.string,
                .raw = tok.val,
                .token = tok,
            } };
        },
        .char => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .literal = .{
                .kind = ast.LiteralKind.char,
                .raw = tok.val,
                .token = tok,
            } };
        },
        .l_bracket => {
            var elems: std.ArrayList(*ast.Expr) = .empty;
            var nxt = try self.lexer.peek_token();
            if (nxt.type != .r_bracket) {
                while (true) {
                    try elems.append(self.allocator, try parse_expression_bp(self, 0));
                    const sep = try self.lexer.next();
                    switch (sep.type) {
                        .r_bracket => break,
                        .comma => {
                            nxt = try self.lexer.peek_token();
                            if (nxt.type == .r_bracket) {
                                _ = try self.lexer.next();
                                break;
                            }
                            continue;
                        },
                        else => {
                            try self.compiler.addError("expected ',' or ']'", err.Severity.Error, sep);
                            try self.sync(&.{ .r_bracket, .semicolon });
                            break;
                        },
                    }
                }
            } else {
                // empty '[]' literal
                _ = try self.lexer.next();
            }
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .array_literal = .{ .elements = elems, .token = tok } };
        },
        .kw_comptime => {
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{ .comptime_expr = .{ .body = try stmt_mod.parse_body(self), .token = tok } };
        },
        else => {
            try self.compiler.addError("expected an expression", err.Severity.Error, tok);
            lhs = try self.error_expr(tok);
        },
    }

    while (true) {
        tok = try self.lexer.peek_token();
        // expect a operator
        const op = switch (tok.type) {
            // zig fmt: off
                .plus, .minus, .star, .slash, .percent,
                .eq_eq, .gt_eq, .lt_eq, .bang_eq, .gt, .lt,
                .amp_amp, .pipe_pipe,
                .amp, .pipe, .caret,
                .shl, .shr, .dot, .dot_dot, .dot_dot_eq,
                .l_paren, .l_bracket,
                .kw_where => tok.type,

                // zig fmt: on
            else => break,
        };

        if (ops.postfix_binding_power(op)) |p_bp| {
            if (p_bp[0] < min_bp) break;
            if (tok.type == token.TokenType.l_paren) {
                const prev_lhs = lhs;
                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{ .call = try parse_call_expression(self, prev_lhs) };
            } else if (tok.type == .dot) {
                _ = try self.lexer.next();
                const bp = ops.postfix_binding_power(.dot).?;
                const f = try parse_expression_bp(self, bp[1]);
                const tmp = lhs;
                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{ .field_access = .{ .target = tmp, .field = f, .token = tok } };
            } else if (tok.type == .l_bracket) {
                _ = try self.lexer.next();
                var args: std.ArrayList(*ast.Expr) = .empty;
                while (true) {
                    try args.append(self.allocator, try parse_expression_bp(self, 0));
                    const sep = try self.lexer.next();
                    switch (sep.type) {
                        .r_bracket => break,
                        .comma => continue,
                        else => {
                            try self.compiler.addError("expected ',' or ']'", err.Severity.Error, sep);
                            try self.sync(&.{ .r_bracket, .semicolon });
                            break;
                        },
                    }
                }
                const tmp = lhs;
                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{ .index = .{ .target = tmp, .args = args, .token = tok } };
            } else if (tok.type == .kw_where) {
                const name = switch (lhs.*) {
                    .ident => |i| i.name,
                    else => blk: {
                        try self.compiler.addError("expected a type name or '_' before 'where'", err.Severity.Error, tok);
                        break :blk "<error>";
                    },
                };
                self.allocator.destroy(lhs);

                var st_lit = ast.StructLiteral{ .name = name, .field_inits = .empty, .token = tok };
                tok = try self.lexer.next();
                while (true) {
                    tok = try self.lexer.peek_token();
                    switch (tok.type) {
                        .ident => {
                            const f = try parse_struct_literal(self);
                            try st_lit.field_inits.append(self.allocator, f);

                            const nxt = try self.lexer.peek_token();
                            if (nxt.type == .comma) {
                                _ = try self.lexer.next();
                            } else if (nxt.type != .kw_end) {
                                try self.compiler.addError("expected ',' or 'end'", err.Severity.Error, nxt);
                                // try self.sync(&.{.{ .kw_end, .kw_const, .kw_var }});
                                break;
                            }
                        },
                        .kw_end => {
                            _ = try self.lexer.next();
                            break;
                        },
                        else => {
                            try self.compiler.addError("expected struct initializer fileds here", err.Severity.Error, tok);
                            try self.sync(&.{ .kw_end, .kw_const, .kw_var });
                            break;
                        },
                    }
                }

                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{ .struct_literal = st_lit };
            }
            continue;
        }

        const i_bp = ops.infix_binding_power(op);
        if (i_bp[0] < min_bp) break;

        tok = try self.lexer.next();
        const rhs = try parse_expression_bp(self, i_bp[1]);

        const prev_lhs = lhs;
        lhs = try self.allocator.create(ast.Expr);
        lhs.* = .{
            .binary = .{
                .lhs = prev_lhs,
                .op = ops.get_binary_op(op),
                .rhs = rhs,
                .token = tok,
            },
        };
    }

    return lhs;
}

pub fn parse_struct_literal(self: *Parser) anyerror!ast.FieldInit {
    const tok = try self.lexer.next();
    const name = tok.val;
    // expect '='
    _ = try self.expect(.eq, "expected '='");

    const e = try parse_expression(self);

    return .{ .name = name, .value = e, .token = tok };
}

pub fn parse_call_expression(self: *Parser, callee: *ast.Expr) anyerror!ast.CallExpr {
    // TODO: check if tok is ok to peek here
    const tok = try self.lexer.peek_token();
    var c_expr = ast.CallExpr{
        .callee = callee,
        .args = .empty,
        .token = tok,
    };

    // expect a '('
    _ = (try self.expect(.l_paren, "expected '('")).?;

    c_expr.args = try self.parse_list_until_rparen(ast.CallArg, parse_call_arg);
    return c_expr;
}

pub fn parse_call_arg(self: *Parser) anyerror!ast.CallArg {
    return .{ .value = try parse_expression(self) };
}

pub fn parse_literal(self: *Parser) anyerror!ast.LiteralExpr {
    const tok = try self.lexer.next();
    return try parse_int_literal(self, tok);
}

fn parse_int_literal(self: *Parser, tok: token.Token) anyerror!ast.LiteralExpr {
    const val = std.fmt.parseInt(u64, tok.val, 0) catch {
        try self.compiler.addError("invalid integer literal", err.Severity.Error, tok);
        return .{ .kind = .integer, .ivalue = 0, .raw = tok.val, .token = tok };
    };
    return .{ .kind = .integer, .ivalue = val, .raw = tok.val, .token = tok };
}

fn parse_float_literal(self: *Parser, tok: token.Token) anyerror!ast.LiteralExpr {
    const val = std.fmt.parseFloat(f64, tok.val) catch {
        try self.compiler.addError("invalid float literal", err.Severity.Error, tok);
        return .{ .kind = .float, .fvalue = 0.0, .raw = tok.val, .token = tok };
    };
    return .{ .kind = .float, .fvalue = val, .raw = tok.val, .token = tok };
}

pub fn parse_ident(self: *Parser) anyerror!ast.IdentExpr {
    const tok = try self.lexer.next();
    return .{ .name = tok.val, .token = tok };
}
