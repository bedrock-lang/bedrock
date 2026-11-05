const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const Parser = @import("parser.zig").Parser;

const stmt_mod = @import("stmt.zig");
const type_defs_mod = @import("type_defs.zig");
const decls_mod = @import("decls.zig");
const types_mod = @import("types.zig");

pub fn parse_items(self: *Parser) anyerror!std.ArrayList(ast.Item) {
    var items: std.ArrayList(ast.Item) = .empty;
    while (!self.lexer.is_end()) {
        var tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.eof) break;

        var is_pub = false;
        var is_inline = false;

        if (tok.type == token.TokenType.kw_pub) {
            _ = try self.lexer.next();
            is_pub = true;
            tok = try self.lexer.peek_token();
        }
        if (tok.type == token.TokenType.kw_inline) {
            _ = try self.lexer.next();
            is_inline = true;
            tok = try self.lexer.peek_token();
        }

        switch (tok.type) {
            .kw_import => {
                const import_def = try parse_import_def(self);
                try items.append(self.allocator, ast.Item{ .import_def = import_def });
            },
            .kw_func => {
                const func_def = try parse_func_def(self, is_pub, is_inline);
                try items.append(self.allocator, ast.Item{ .function = func_def });
            },
            .kw_proc => {
                const proc_def = try parse_proc_def(self, is_pub, is_inline);
                try items.append(self.allocator, ast.Item{ .proc = proc_def });
            },
            .kw_type => {
                //todo: error if is_inline set (struct/enum defs take no "inline")
                var type_def = try type_defs_mod.parse_type_def(self);
                type_def.is_pub = is_pub;
                type_def.is_global = true;
                try items.append(self.allocator, ast.Item{ .type_def = type_def });
            },
            .kw_extern => {
                const extern_def = try parse_extern_def(self);
                try items.append(self.allocator, ast.Item{ .extern_def = extern_def });
            },
            .kw_var => while (true) {
                var var_def = try decls_mod.parse_var_def(self);
                var_def.is_pub = is_pub;
                var_def.is_global = true;
                try items.append(self.allocator, ast.Item{ .var_def = var_def });
                if ((try self.lexer.peek_token()).type != .comma) break;
            },
            .kw_const => while (true) {
                var const_def = try decls_mod.parse_const_def(self);
                const_def.is_pub = is_pub;
                const_def.is_global = true;
                try items.append(self.allocator, ast.Item{ .const_def = const_def });
                if ((try self.lexer.peek_token()).type != .comma) break;
            },
            else => {
                // TODO:: error handling
                _ = try self.lexer.next();
                break;
            },
        }
    }
    return items;
}

pub fn parse_func_def(self: *Parser, is_pub: bool, is_inline: bool) anyerror!ast.FunctionDef {
    const func_tok = try self.lexer.next();
    var func_def = ast.FunctionDef{
        .is_pub = is_pub,
        .is_inline = is_inline,
        .name = "",
        .type_params = .empty,
        .params = undefined,
        .result = undefined,
        .body = undefined,
        .token = func_tok,
    };

    // todo: parse_type_params for the .type_params

    // get the function name
    const name_tok = try self.expect(.ident, "expected function name") orelse token.Token{ .type = .ident, .val = "", .line = func_tok.line, .col = func_tok.col };
    func_def.name = name_tok.val;

    // extect '('
    _ = try self.expect(.l_paren, "expected '('");

    // TODO: type params
    func_def.params = try parse_params(self);

    // expect '->'
    _ = try self.expect(.arrow, "expected '->'");

    func_def.result = try types_mod.parse_result(self);

    // parse block statement
    func_def.body = try stmt_mod.parse_body(self);

    return func_def;
}

pub fn parse_proc_def(self: *Parser, is_pub: bool, is_inline: bool) anyerror!ast.ProcDef {
    const proc_tok = try self.lexer.next();
    var proc_def = ast.ProcDef{
        .is_pub = is_pub,
        .is_inline = is_inline,
        .name = "",
        .type_params = .empty,
        .params = .empty,
        .body = undefined,
        .token = proc_tok,
    };

    const tok = try self.expect_ident("expected proc name", proc_tok);
    proc_def.name = tok.val;

    //todo: parse_type_params

    if (try self.expect(.l_paren, "expected '('") == null) {
        try self.sync(&.{ .r_paren, .kw_end });
    } else {
        proc_def.params = try parse_params(self);
    }

    proc_def.body = try stmt_mod.parse_body(self);

    return proc_def;
}

pub fn parse_import_def(self: *Parser) anyerror!ast.ImportDef {
    var tok = try self.lexer.next();
    var import_def = ast.ImportDef{ .path = .empty, .token = tok };
    while (true) {
        // expect an ident
        tok = try self.expect_ident("expected ident ", tok);
        try import_def.path.append(self.allocator, tok.val);

        // can be a '.'
        tok = try self.lexer.next();
        if (tok.type == token.TokenType.semicolon) break;
        if (tok.type != token.TokenType.dot) {
            try self.compiler.addError("expected . or ; ", err.Severity.Error, tok);
            try self.sync(&.{ .semicolon, .kw_import, .kw_func, .kw_const, .kw_var, .kw_type, .kw_extern, .kw_pub, .kw_proc });
            break;
        }
    }
    return import_def;
}

pub fn parse_extern_def(self: *Parser) anyerror!ast.ExternDef {
    var tok = try self.lexer.next();
    const ktok = try self.lexer.next(); // func or proc

    switch (ktok.type) {
        .kw_func => {
            tok = try self.expect_ident("expected function name", tok);
            _ = try self.expect(.l_paren, "expected '('");
            const parsed = try parse_extern_params(self);
            _ = try self.expect(.arrow, "expected '->'");
            const result = try types_mod.parse_type(self);
            _ = try self.expect(.semicolon, "expected ';'");

            return ast.ExternDef{
                .kind = .{
                    .func = .{
                        .name = tok.val,
                        .params = parsed.params,
                        .result = result,
                        .is_variadic = parsed.is_variadic, //todo: implement this '...'
                    },
                },
                .token = tok,
            };
        },
        .kw_proc => {
            tok = try self.expect_ident("expected proc name", tok);
            _ = try self.expect(.l_paren, "expected '('");
            const parsed = try parse_extern_params(self);
            _ = try self.expect(.semicolon, "expected ';'");

            return ast.ExternDef{
                .kind = .{
                    .proc = .{
                        .name = tok.val,
                        .params = parsed.params,
                        .is_variadic = parsed.is_variadic,
                    },
                },
                .token = tok,
            };
        },
        else => {
            try self.compiler.addError("expected func or proc", err.Severity.Error, tok);
            return ast.ExternDef{
                .kind = .{ .proc = .{ .name = "<error>", .params = .empty, .is_variadic = false } },
                .token = tok,
            };
        },
    }
}

pub fn parse_params(self: *Parser) anyerror!std.ArrayList(ast.Param) {
    return self.parse_list_until_rparen(ast.Param, parse_param);
}

// extern_params   = extern_param { "," extern_param } [ "," "..." ]
pub fn parse_extern_params(self: *Parser) anyerror!struct { params: std.ArrayList(ast.Param), is_variadic: bool } {
    var params: std.ArrayList(ast.Param) = .empty;
    var is_variadic = false;

    const first = try self.lexer.peek_token();
    if (first.type == token.TokenType.r_paren) {
        _ = try self.lexer.next();
        return .{ .params = params, .is_variadic = is_variadic };
    }

    if (first.type == token.TokenType.dot_dot_dot) {
        _ = try self.lexer.next();
        is_variadic = true;
        _ = try self.expect(.r_paren, "expected ')'");
        return .{ .params = params, .is_variadic = is_variadic };
    }

    while (true) {
        try params.append(self.allocator, try parse_param(self));
        const tok = try self.lexer.next();
        switch (tok.type) {
            .r_paren => break,
            .comma => {
                const nxt = try self.lexer.peek_token();
                if (nxt.type == token.TokenType.r_paren) {
                    _ = try self.lexer.next();
                    break;
                }
                if (nxt.type == token.TokenType.dot_dot_dot) {
                    _ = try self.lexer.next();
                    is_variadic = true;
                    _ = try self.expect(.r_paren, "expected ')'");
                    break;
                }
                continue;
            },
            else => {
                try self.compiler.addError("expected ',' or ')'", err.Severity.Error, tok);
                try self.sync(&.{ .comma, .r_paren });
                const peek_tok = try self.lexer.peek_token();
                if (peek_tok.type == .comma) {
                    _ = try self.lexer.next();
                    continue;
                } else if (peek_tok.type == .r_paren) {
                    _ = try self.lexer.next();
                    break;
                } else {
                    break;
                }
            },
        }
    }
    return .{ .params = params, .is_variadic = is_variadic };
}

pub fn parse_param(self: *Parser) anyerror!ast.Param {
    var tok = try self.lexer.peek_token();
    var param = ast.Param{
        .name = "",
        .is_const = false,
        .is_comptime = false,
        .type = undefined,
        .token = undefined,
    };

    // check for comptime
    if (tok.type == .kw_comptime) {
        param.is_comptime = true;
        _ = try self.lexer.next();
    }

    // name
    tok = try self.expect_ident("expected identifier", tok);
    param.name = tok.val;
    param.token = tok;

    // :
    _ = try self.expect(.colon, "expected ':'");

    // type
    if ((try self.lexer.peek_token()).type == .kw_const) {
        _ = try self.lexer.next();
        param.is_const = true;
    }

    param.type = try types_mod.parse_type(self);
    return param;
}
