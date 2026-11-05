const std = @import("std");
const token = @import("../token.zig");
const lexer = @import("../lexer.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const compiler = @import("../compiler.zig");

const items_mod = @import("items.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer.Lexer,
    source: []const u8,
    compiler: *compiler.Compiler,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, c: *compiler.Compiler) Parser {
        return Parser{
            .allocator = allocator,
            .lexer = lexer.Lexer.init(source, allocator),
            .source = source,
            .compiler = c,
        };
    }

    pub fn parse(self: *Parser) !ast.AST {
        var ast_res = ast.AST.init();
        ast_res.program = try self.parse_program();
        return ast_res;
    }

    pub fn parse_program(self: *Parser) !ast.Program {
        var program = ast.Program{ .items = undefined };
        program.items = try items_mod.parse_items(self);
        return program;
    }

    pub fn expect(self: *Parser, ty: token.TokenType, msg: []const u8) !?token.Token {
        const tok = try self.lexer.peek_token();
        if (tok.type != ty) {
            try self.compiler.addError(msg, err.Severity.Error, tok);
            return null;
        }
        return try self.lexer.next();
    }

    pub fn expect_ident(self: *Parser, msg: []const u8, at: token.Token) !token.Token {
        return try self.expect(.ident, msg) orelse token.Token{
            .type = .ident,
            .val = "<error>",
            .line = at.line,
            .col = at.col,
        };
    }

    // when error occurs and when a production can't sensibly continue
    // (e.g. -> missing in a func type) then call this to reach a good
    // point where u can continue parsing.
    pub fn sync(self: *Parser, stop_set: []const token.TokenType) !void {
        var depth: usize = 0;
        while (true) {
            const t = try self.lexer.peek_token();
            if (t.type == .eof) return;
            if (depth == 0) {
                for (stop_set) |s| {
                    if (t.type == s) return; // not consume it, as code after this needs this token
                }
            }
            _ = try self.lexer.next();
            switch (t.type) {
                .l_paren, .l_bracket => depth += 1,
                .r_paren, .r_bracket => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            }
        }
    }

    pub fn expect_decl_end(self: *Parser) !void {
        const nxt = try self.lexer.peek_token();
        if (nxt.type == .comma) return;
        if (nxt.type == .semicolon) {
            _ = try self.lexer.next();
            return;
        }
        try self.compiler.addError("expected ',' or ';'", err.Severity.Error, nxt);
        try self.sync(&.{
            .semicolon, .kw_end,    .kw_elif,   .kw_else,  .kw_case,     .kw_var,    .kw_const,  .kw_static,
            .kw_defer,  .kw_unsafe, .kw_return, .kw_break, .kw_continue, .kw_if,     .kw_match,  .kw_while,
            .kw_for,    .kw_import, .kw_func,   .kw_proc,  .kw_type,     .kw_extern, .kw_inline, .kw_pub,
        });
        if ((try self.lexer.peek_token()).type == .semicolon) _ = try self.lexer.next();
    }

    /// Parses `item { "," item } [","] ")"` where the opening '(' has already
    /// been consumed. Used for params, call args and type lists.
    pub fn parse_list_until_rparen(
        self: *Parser,
        comptime T: type,
        comptime parse_item: fn (*Parser) anyerror!T,
    ) anyerror!std.ArrayList(T) {
        var list: std.ArrayList(T) = .empty;

        if ((try self.lexer.peek_token()).type == .r_paren) {
            _ = try self.lexer.next();
            return list;
        }

        while (true) {
            try list.append(self.allocator, try parse_item(self));
            const tok = try self.lexer.next();
            switch (tok.type) {
                .r_paren => break,
                .comma => {
                    if ((try self.lexer.peek_token()).type == .r_paren) {
                        _ = try self.lexer.next();
                        break;
                    }
                },
                else => {
                    try self.compiler.addError("expected ',' or ')'", err.Severity.Error, tok);
                    try self.sync(&.{ .comma, .r_paren });
                    switch ((try self.lexer.peek_token()).type) {
                        .comma => _ = try self.lexer.next(),
                        .r_paren => {
                            _ = try self.lexer.next();
                            break;
                        },
                        else => break,
                    }
                },
            }
        }
        return list;
    }

    pub fn error_type(self: *Parser, tok: token.Token) !*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{
            .is_optional = false,
            .is_error_union = false,
            .base = .{ .named = .{ .name = "<error>", .args = &[_]*ast.Type{}, .token = tok } },
            .token = tok,
        };
        return ty;
    }

    pub fn alloc_expr(self: *Parser, e: ast.Expr) !*ast.Expr {
        const p = try self.allocator.create(ast.Expr);
        p.* = e;
        return p;
    }

    pub fn error_expr(self: *Parser, tok: token.Token) !*ast.Expr {
        return self.alloc_expr(.{ .ident = .{ .name = "<error>", .token = tok } });
    }
};
