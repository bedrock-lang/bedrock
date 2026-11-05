const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const ops = @import("ops.zig");
const Parser = @import("parser.zig").Parser;

const expr_mod = @import("expr.zig");

pub fn parse_literal_pattern(self: *Parser, tok: token.Token) anyerror!ast.Pattern {
    _ = self;
    return switch (tok.type) {
        .integer => .{ .integer = tok.val },
        .char => .{ .ident = tok.val },
        .kw_false => .{ .boolean = false },
        .kw_true => .{ .boolean = true },
        else => unreachable,
    };
}

pub fn parse_variant_pattern(self: *Parser, tok: token.Token) anyerror!ast.Pattern {
    var pattern = ast.VariantPattern{
        .name = tok.val,
        .params = .empty,
        .token = tok,
    };

    const next = try self.lexer.peek_token();
    // for c type enums
    if (next.type == .dot) {
        _ = try self.lexer.next();
        const bp = ops.postfix_binding_power(.dot).?;
        const f = try expr_mod.parse_expression_bp(self, bp[1]);
        const target = try self.alloc_expr(.{ .ident = .{ .name = tok.val, .token = tok } });
        const field_variant = try self.alloc_expr(.{
            .field_access = .{ .target = target, .field = f, .token = tok },
        });

        return .{ .field_variant = field_variant };
    }

    if (next.type != .l_paren) {
        return .{ .variant = pattern };
    }

    // consume '('
    _ = try self.lexer.next();
    const first = try self.lexer.peek_token();
    if (first.type == .r_paren) {
        // consume ')'
        _ = try self.lexer.next();
        return .{ .variant = pattern };
    }

    while (true) {
        const param = try self.allocator.create(ast.Pattern);
        param.* = try parse_pattern(self);
        try pattern.params.append(self.allocator, param);

        const sep = try self.lexer.next();
        switch (sep.type) {
            .r_paren => break,
            .comma => {
                const nxt = try self.lexer.peek_token();
                if (nxt.type == .r_paren) {
                    _ = try self.lexer.next();
                    break;
                }
                continue;
            },
            else => {
                try self.compiler.addError("expected ',' or ')'", err.Severity.Error, sep);
                try self.sync(&.{ .comma, .r_paren, .kw_end, .kw_case, .kw_else });
                break;
            },
        }
    }

    return .{ .variant = pattern };
}

pub fn parse_pattern(self: *Parser) anyerror!ast.Pattern {
    const tok = try self.lexer.next();

    switch (tok.type) {
        .integer, .char, .kw_true, .kw_false => return try parse_literal_pattern(self, tok),
        .ident => return try parse_variant_pattern(self, tok),
        else => {
            try self.compiler.addError("expected pattern", err.Severity.Error, tok);
            try self.sync(&.{ .comma, .r_paren, .kw_end });
            return error.InvalidPattern;
        },
    }
}
