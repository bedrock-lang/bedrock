const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const Parser = @import("parser.zig").Parser;

const expr_mod = @import("expr.zig");

pub fn parse_type(self: *Parser) anyerror!*ast.Type {
    const start_tok = try self.lexer.peek_token();

    var is_optional = false;
    if (start_tok.type == token.TokenType.optional) {
        _ = try self.lexer.next();
        is_optional = true;
    }

    const base = try parse_base_type(self);

    var is_error_union = false;
    const is_it_bang = try self.lexer.peek_token();
    if (is_it_bang.type == token.TokenType.bang) {
        _ = try self.lexer.next();
        is_error_union = true;
    }

    const ty = try self.allocator.create(ast.Type);
    ty.* = .{
        .is_optional = is_optional,
        .is_error_union = is_error_union,
        .base = base,
        .token = start_tok,
    };
    return ty;
}

pub fn parse_result(self: *Parser) anyerror!*ast.Type {
    return parse_type(self);
}

/// `type { "," type } [","] ")"` — the '(' is already consumed.
pub fn parse_type_list(self: *Parser) anyerror!std.ArrayList(*ast.Type) {
    return self.parse_list_until_rparen(*ast.Type, parse_type);
}

fn parse_base_type(self: *Parser) anyerror!ast.BaseType {
    const tok = try self.lexer.next();

    switch (tok.type) {
        .star => {
            const pointee = try parse_type(self);
            return ast.BaseType{ .pointer = pointee };
        },
        .l_bracket => {
            const nxt = try self.lexer.peek_token();
            if (nxt.type == .r_bracket) {
                return try parse_slice_type(self, tok);
            }
            return try parse_array_type(self, tok);
        },
        .kw_func => return try parse_func_type(self, tok),
        .kw_proc => return try parse_proc_type(self, tok),
        .ident, .kw_ptr, .kw_type => {
            if (std.meta.stringToEnum(ast.PrimitiveType, tok.val)) |prim| {
                return ast.BaseType{ .primitive = prim };
            }
            return try parse_named_type(self, tok);
        },
        else => {
            try self.compiler.addError("expected a type", err.Severity.Error, tok);
            return ast.BaseType{ .named = .{ .name = tok.val, .args = &[_]*ast.Type{}, .token = tok } };
        },
    }
}

fn parse_slice_type(self: *Parser, tok: token.Token) anyerror!ast.BaseType {
    _ = try self.lexer.next();
    const elem = try parse_type(self);
    return ast.BaseType{ .slice = .{ .elem = elem, .token = tok } };
}

fn parse_array_type(self: *Parser, tok: token.Token) anyerror!ast.BaseType {
    const size_tok = try self.lexer.peek_token();
    var size: ast.ArraySize = .inferred;

    if (size_tok.type == token.TokenType.ident and std.mem.eql(u8, size_tok.val, "_")) {
        _ = try self.lexer.next();
    } else {
        const e = try expr_mod.parse_expression(self);
        if (e.* == .literal and e.literal.kind == .integer) {
            const raw = e.literal.raw;
            e.deinit(self.allocator);
            size = .{ .fixed = raw };
        } else {
            size = .{ .expr = e };
        }
    }

    if (try self.expect(.r_bracket, "expected ']'") == null) {
        try self.sync(&.{ .comma, .r_paren });
        return ast.BaseType{ .array = .{ .size = size, .elem = try self.error_type(tok), .token = tok } };
    }

    const elem = try parse_type(self);

    return ast.BaseType{ .array = ast.ArrayType{ .size = size, .elem = elem, .token = tok } };
}

fn parse_func_type(self: *Parser, tok: token.Token) anyerror!ast.BaseType {
    _ = try self.expect(.l_paren, "expected '('");

    const params = try parse_type_list(self);

    if (try self.expect(.arrow, "expected '->'") == null) {
        try self.sync(&.{ .r_paren, .comma });
        return ast.BaseType{ .func = .{ .params = params, .result = try self.error_type(tok), .token = tok } };
    }
    const result = try parse_type(self);

    return ast.BaseType{ .func = ast.FuncType{ .params = params, .result = result, .token = tok } };
}

fn parse_proc_type(self: *Parser, tok: token.Token) anyerror!ast.BaseType {
    if (try self.expect(.l_paren, "expected '('") == null) {
        try self.sync(&.{ .r_paren, .comma });
        return ast.BaseType{ .proc = ast.ProcType{ .params = .empty, .token = tok } };
    }
    const params = try parse_type_list(self);
    return ast.BaseType{ .proc = ast.ProcType{ .params = params, .token = tok } };
}

fn parse_named_type(self: *Parser, tok: token.Token) anyerror!ast.BaseType {
    var args: std.ArrayList(*ast.Type) = .empty;

    var nxt = try self.lexer.peek_token();
    if (nxt.type != token.TokenType.l_bracket) {
        return ast.BaseType{ .named = .{ .name = tok.val, .args = &[_]*ast.Type{}, .token = tok } };
    }
    _ = try self.lexer.next();

    while (true) {
        try args.append(self.allocator, try parse_type(self));

        const sep = try self.lexer.peek_token();
        if (sep.type == token.TokenType.r_bracket) {
            _ = try self.lexer.next();
            break;
        }

        if (try self.expect(.comma, "expected ',' or ']'") == null) {
            const peek_tok = try self.lexer.peek_token();
            if (peek_tok.type == .comma) {
                _ = try self.lexer.next();
                continue;
            } else if (peek_tok.type == .r_bracket) {
                _ = try self.lexer.next();
                break;
            } else {
                break;
            }
        }

        nxt = try self.lexer.peek_token();
        if (nxt.type == token.TokenType.r_bracket) {
            _ = try self.lexer.next();
            break;
        }
    }
    return ast.BaseType{ .named = .{ .name = tok.val, .args = try args.toOwnedSlice(self.allocator), .token = tok } };
}
