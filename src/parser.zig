const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const err = @import("error.zig");
const compiler = @import("compiler.zig");

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

    fn expect(self: *Parser, ty: token.TokenType, msg: []const u8) !?token.Token {
        const tok = try self.lexer.peek_token();
        if (tok.type != ty) {
            try self.compiler.addError(msg, err.Severity.Error, tok);
            return null;
        }
        return try self.lexer.next();
    }

    // when error occurs and when a production can't sensibly continue
    // (e.g. -> missing in a func type) then call this to reach a good
    // point where u can continue parsing.
    fn sync(self: *Parser, stop_set: []const token.TokenType) !void {
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

    // error type token
    fn error_type(self: *Parser, tok: token.Token) !*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{
            .is_optional = false,
            .is_error_union = false,
            .base = .{ .named = .{ .name = "<error>", .args = &[_]*ast.Type{}, .token = tok } },
            .token = tok,
        };
        return ty;
    }

    pub fn parse(self: *Parser) !ast.AST {
        var ast_res = ast.AST.init();
        ast_res.program = try self.parse_program();
        return ast_res;
    }

    pub fn parse_program(self: *Parser) !ast.Program {
        var program = ast.Program{ .items = undefined };
        program.items = try self.parse_items();
        return program;
    }

    pub fn parse_items(self: *Parser) !std.ArrayList(ast.Item) {
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
                    const import_def = try self.parse_import_def();
                    try items.append(self.allocator, ast.Item{ .import_def = import_def });
                },
                .kw_func => {
                    const func_def = try self.parse_func_def(is_pub, is_inline);
                    try items.append(self.allocator, ast.Item{ .function = func_def });
                },
                .kw_proc => {
                    const proc_def = try self.parse_proc_def(is_pub, is_inline);
                    try items.append(self.allocator, ast.Item{ .proc = proc_def });
                },
                .kw_type => {
                    //todo: error if is_inline set (struct/enum defs take no "inline")
                    var type_def = try self.parse_type_def();
                    type_def.is_pub = is_pub;
                    type_def.is_global = true;
                    try items.append(self.allocator, ast.Item{ .type_def = type_def });
                },
                .kw_extern => {
                    const extern_def = try self.parse_extern_def();
                    try items.append(self.allocator, ast.Item{ .extern_def = extern_def });
                },
                .kw_var => {
                    var var_def = try self.parse_var_def();
                    var_def.is_pub = is_pub;
                    var_def.is_global = true;
                    try items.append(self.allocator, ast.Item{ .var_def = var_def });
                },
                .kw_const => {
                    var const_def = try self.parse_const_def();
                    const_def.is_pub = is_pub;
                    const_def.is_global = true;
                    try items.append(self.allocator, ast.Item{ .const_def = const_def });
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

    pub fn parse_func_def(self: *Parser, is_pub: bool, is_inline: bool) !ast.FunctionDef {
        var tok = try self.lexer.next();
        var func_def = ast.FunctionDef{
            .is_pub = is_pub,
            .is_inline = is_inline,
            .name = "",
            .type_params = .empty,
            .params = undefined,
            .result = undefined,
            .body = undefined,
            .token = tok,
        };

        tok = try self.lexer.peek_token();
        if (tok.type == .l_bracket) {
            _ = try self.lexer.next();
            func_def.type_params = try self.parse_type_params();
        }

        // get the function name
        const name_tok = try self.expect(.ident, "expected function name") orelse token.Token{ .type = .ident, .val = "", .line = tok.line, .col = tok.col };
        func_def.name = name_tok.val;

        // extect '('
        _ = try self.expect(.l_paren, "expected '('");

        // TODO: type params
        // parse parameters
        func_def.params = try self.parse_params();

        // expect '->'
        _ = try self.expect(.arrow, "expected '->'");

        func_def.result = try self.parse_result();

        // parse block statement
        func_def.body = try self.parse_body();

        return func_def;
    }

    pub fn parse_proc_def(self: *Parser, is_pub: bool, is_inline: bool) !ast.ProcDef {
        var tok = try self.lexer.next();
        var proc_def = ast.ProcDef{
            .is_pub = is_pub,
            .is_inline = is_inline,
            .name = "",
            .type_params = .empty,
            .params = .empty,
            .body = undefined,
            .token = tok,
        };

        tok = try self.lexer.peek_token();
        if (tok.type == .l_bracket) {
            _ = try self.lexer.next();
            proc_def.type_params = try self.parse_type_params();
        }

        tok = try self.expect(.ident, "expected proc name") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        proc_def.name = tok.val;

        if (try self.expect(.l_paren, "expected '('") == null) {
            try self.sync(&.{ .r_paren, .kw_end });
        } else {
            proc_def.params = try self.parse_params();
        }

        proc_def.body = try self.parse_body();

        return proc_def;
    }

    pub fn parse_type_def(self: *Parser) !ast.TypeDef {
        var type_def = ast.TypeDef{
            .is_pub = false,
            .is_global = false,
            .variant = undefined,
        };
        // NOTE: no type params for now
        var tok = try self.lexer.next();
        // ident
        const name = try self.lexer.next();
        _ = try self.expect(.eq, "expected '='");

        tok = try self.lexer.next();
        switch (tok.type) {
            .kw_struct => {
                const s = try self.parse_struct(name.val);
                type_def.variant = .{ .struct_def = s };
            },
            .kw_enum => {
                // TODO:
            },
            else => {
                // error
            },
        }

        return type_def;
    }

    pub fn parse_struct(self: *Parser, name: []const u8) !ast.StructDef {
        var tok = try self.lexer.peek_token();
        var s = ast.StructDef{
            .is_pub = false,
            .name = name,
            .type_params = .empty,
            .fields = .empty,
            .methods = .empty,
            .token = tok,
        };

        try self.parse_struct_members(&s);

        tok = try self.lexer.peek_token();
        // expect end
        _ = try self.expect(.kw_end, "expected 'end'") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };

        return s;
    }

    pub fn parse_struct_members(self: *Parser, s: *ast.StructDef) !void {
        var tok = try self.lexer.peek_token();
        // parse struct fields
        while (true) {
            switch (tok.type) {
                .kw_end => break,
                .ident, .kw_pub => {
                    const f = try self.parse_struct_fields();
                    try s.fields.append(self.allocator, f);
                    const nxt = try self.lexer.peek_token();
                    if (nxt.type == .comma) {
                        _ = try self.lexer.next();
                    } else if (nxt.type != .kw_end) {
                        try self.compiler.addError("expected ',' or 'end'", err.Severity.Error, nxt);
                        // try self.sync(&.{.{ .kw_end, .kw_const, .kw_var }});
                        break;
                    }
                    tok = try self.lexer.peek_token();
                },
                else => {
                    try self.compiler.addError("expected struct fileds or struct member here ", err.Severity.Error, tok);
                    try self.sync(&.{ .kw_import, .kw_func, .kw_const, .kw_var, .kw_type, .kw_extern, .kw_pub, .kw_proc });
                    break;
                },
            }
        }
    }

    pub fn parse_struct_fields(self: *Parser) !ast.StructField {
        var sf = ast.StructField{
            .is_pub = false,
            .name = "",
            .type = undefined,
            .token = undefined,
        };

        // check for pub
        var tok = try self.lexer.peek_token();
        if (tok.type == .kw_pub) {
            sf.is_pub = true;
            _ = try self.lexer.next();
        }

        tok = try self.lexer.next();
        sf.name = tok.val;

        // expect ':'
        _ = try self.expect(.colon, "expected ':'") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };

        // parse type
        sf.type = try self.parse_type();

        tok = try self.lexer.peek_token();

        return sf;
    }

    pub fn parse_struct_literal(self: *Parser) anyerror!ast.FieldInit {
        const tok = try self.lexer.peek_token();
        _ = try self.lexer.next();
        const name = tok.val;
        // expect '='
        _ = try self.expect(.eq, "expected '='") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };

        const e = try self.parse_expression();

        return .{ .name = name, .value = e, .token = tok };
    }

    pub fn parse_extern_def(self: *Parser) !ast.ExternDef {
        var tok = try self.lexer.next();
        const ktok = try self.lexer.next(); // func or proc

        switch (ktok.type) {
            .kw_func => {
                tok = try self.expect(.ident, "expected function name") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
                _ = try self.expect(.l_paren, "expected '('");
                const parsed = try self.parse_extern_params();
                _ = try self.expect(.arrow, "expected '->'");
                const result = try self.parse_type();
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
                tok = try self.expect(.ident, "expected proc name") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
                _ = try self.expect(.l_paren, "expected '('");
                const parsed = try self.parse_extern_params();
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

    pub fn parse_params(self: *Parser) !std.ArrayList(ast.Param) {
        var params: std.ArrayList(ast.Param) = .empty;

        const first = try self.lexer.peek_token();
        if (first.type == token.TokenType.r_paren) {
            _ = try self.lexer.next();
            return params;
        }

        while (true) {
            try params.append(self.allocator, try self.parse_param());
            const tok = try self.lexer.next();
            switch (tok.type) {
                .r_paren => break,
                .comma => {
                    const nxt = try self.lexer.peek_token();
                    if (nxt.type == token.TokenType.r_paren) {
                        _ = try self.lexer.next();
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
                        // can't recover
                        break;
                    }
                    break;
                },
            }
        }

        return params;
    }

    // extern_params   = extern_param { "," extern_param } [ "," "..." ]
    pub fn parse_extern_params(self: *Parser) !struct { params: std.ArrayList(ast.Param), is_variadic: bool } {
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
            try params.append(self.allocator, try self.parse_param());
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

    pub fn parse_param(self: *Parser) !ast.Param {
        var tok = try self.lexer.peek_token();
        var param = ast.Param{
            .name = "",
            .is_const = false,
            .type = undefined,
            .token = undefined,
        };

        // name
        tok = try self.expect(.ident, "expected identifier") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        param.name = tok.val;
        param.token = tok;

        // :
        _ = try self.expect(.colon, "expected ':'");

        // type
        if ((try self.lexer.peek_token()).type == .kw_const) {
            _ = try self.lexer.next();
            param.is_const = true;
        }

        param.type = try self.parse_type();
        return param;
    }

    fn parse_type_params(self: *Parser) !std.ArrayList(ast.TypeParam) {
        var params: std.ArrayList(ast.TypeParam) = .empty;
        while (true) {
            const tok = try self.expect(.ident, "expected type param name") orelse token.Token{ .type = .ident, .val = "<error>", .line = 0, .col = 0 };
            try params.append(self.allocator, ast.TypeParam{ .name = tok.val, .token = tok });
            if ((try self.lexer.peek_token()).type == .r_bracket) {
                _ = try self.lexer.next();
                break;
            }
            // this is here to avoid going into infinite loop
            // when found '[' but no ']'. (it's not so good, as it gives wierd errors)
            if (try self.expect(.comma, "expected ','") == null) {
                try self.sync(&.{.r_bracket});
                _ = try self.lexer.next();
                break;
            }
        }
        return params;
    }

    pub fn parse_body(self: *Parser) !std.ArrayList(ast.Stmt) {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (true) {
            const tok = try self.lexer.peek_token();
            if (tok.type == .kw_end or tok.type == .kw_elif or tok.type == .kw_else or tok.type == .eof or tok.type == .kw_case) break;
            try stmts.append(self.allocator, try self.parse_statement());
        }
        if ((try self.lexer.peek_token()).type == .kw_end) {
            _ = try self.expect(.kw_end, "expected 'end'");
        }
        return stmts;
    }

    pub fn parse_statement(self: *Parser) !ast.Stmt {
        const tok = try self.lexer.peek_token();

        return switch (tok.type) {
            .kw_var => try self.parse_var_stmt(),
            .kw_const => try self.parse_const_stmt(),
            .kw_static => try self.parse_local_static_var_stmt(),
            .kw_defer => try self.parse_defer_stmt(),
            .kw_unsafe => try self.parse_unsafe_stmt(),
            .kw_return => try self.parse_return_stmt(),
            .kw_break => try self.parse_break(),
            .kw_continue => try self.parse_continue(),
            .kw_if, .kw_match, .kw_while, .kw_for => try self.parse_control_flow_stmt(),
            .ident => {
                // NOTE: temporary print stub
                if (std.mem.eql(u8, tok.val, "bokbok")) {
                    return try self.parse_print_stub();
                } else {
                    return try self.parse_expr_or_assign_stmt();
                }
            },
            else => try self.parse_expr_or_assign_stmt(),
        };
    }

    fn parse_var_stmt(self: *Parser) !ast.Stmt {
        var tok = try self.lexer.next();
        var var_stmt = ast.VarStmt{
            .name = "",
            .type_ann = null,
            .value = undefined,
            .token = tok,
        };

        // expect name ident
        tok = try self.expect(.ident, "expected name ident ") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        var_stmt.name = tok.val;

        // if ':' parse type
        tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.colon) {
            _ = try self.lexer.next();
            var_stmt.type_ann = try self.parse_type();
        }

        // expect '='
        _ = try self.expect(.eq, "expected '='");
        var_stmt.value = try self.parse_expression();

        switch (var_stmt.value.*) {
            .struct_literal => {},
            .unary => |*u| {
                switch (u.operand.*) {
                    .struct_literal => {},
                    else => _ = try self.expect(.semicolon, "expected ';'"),
                }
            },
            // extect ';'
            else => _ = try self.expect(.semicolon, "expected ';'"),
        }

        return ast.Stmt{ .var_stmt = var_stmt };
    }

    fn parse_const_stmt(self: *Parser) !ast.Stmt {
        var tok = try self.lexer.next();
        var const_stmt = ast.ConstStmt{
            .name = "",
            .type_ann = null,
            .value = undefined,
            .token = tok,
        };

        // expect name ident
        tok = try self.expect(.ident, "expected name ident ") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        const_stmt.name = tok.val;

        // if ':' parse type
        tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.colon) {
            _ = try self.lexer.next();
            const_stmt.type_ann = try self.parse_type();
        }

        // expect '='
        _ = try self.expect(.eq, "expected '='");
        const_stmt.value = try self.parse_expression();

        switch (const_stmt.value.*) {
            .struct_literal => {},
            // extect ';'
            else => _ = try self.expect(.semicolon, "expected ';'"),
        }

        return ast.Stmt{ .const_stmt = const_stmt };
    }

    fn parse_break(self: *Parser) !ast.Stmt {
        const tok = try self.lexer.peek_token();
        _ = try self.lexer.next();
        // extect ';'
        _ = try self.expect(.semicolon, "expected ';'");

        return ast.Stmt{ .break_stmt = .{ .token = tok } };
    }

    fn parse_continue(self: *Parser) !ast.Stmt {
        const tok = try self.lexer.peek_token();
        _ = try self.lexer.next();
        // extect ';'
        _ = try self.expect(.semicolon, "expected ';'");

        return ast.Stmt{ .continue_stmt = .{ .token = tok } };
    }

    fn parse_local_static_var_stmt(self: *Parser) !ast.Stmt {
        var tok = try self.lexer.next();
        var lsv_stmt = ast.LocalStaticVarStmt{
            .name = "",
            .type_ann = null,
            .value = undefined,
            .token = tok,
        };

        _ = try self.expect(.kw_var, "expected 'var'");

        tok = try self.expect(.ident, "expected name ident") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        lsv_stmt.name = tok.val;

        tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.colon) {
            _ = try self.lexer.next();
            lsv_stmt.type_ann = try self.parse_type();
        }

        _ = try self.expect(.eq, "expected '='");
        lsv_stmt.value = try self.parse_expression();

        _ = try self.expect(.semicolon, "expected ';'");

        return ast.Stmt{ .local_static_var_stmt = lsv_stmt };
    }

    fn parse_defer_stmt(self: *Parser) anyerror!ast.Stmt {
        const tok = try self.lexer.next();
        const statement_list = try self.parse_body();
        return ast.Stmt{ .defer_stmt = .{ .statement_list = statement_list, .token = tok } };
    }

    fn parse_unsafe_stmt(self: *Parser) anyerror!ast.Stmt {
        const tok = try self.lexer.next();
        const body = try self.parse_body();
        return ast.Stmt{ .unsafe_stmt = .{ .body = body, .token = tok } };
    }

    fn parse_return_stmt(self: *Parser) !ast.Stmt {
        const tok = try self.lexer.next();
        if ((try self.lexer.peek_token()).type == .semicolon) {
            _ = try self.lexer.next();
            return ast.Stmt{ .return_stmt = .{ .value = null, .token = tok } };
        }
        const value = try self.parse_expression();
        _ = try self.expect(.semicolon, "expected ';'");
        return ast.Stmt{ .return_stmt = .{ .value = value, .token = tok } };
    }

    fn parse_expr_or_assign_stmt(self: *Parser) !ast.Stmt {
        const tok = try self.lexer.peek_token();
        const expr = try self.parse_expression();
        const op = try self.lexer.peek_token();
        const coop = get_compund_op(op.type);
        if (op.type == .eq or coop != null) {
            _ = try self.lexer.next();
            const value = try self.parse_expression();
            _ = try self.expect(.semicolon, "expected ';'");
            return ast.Stmt{ .assign_stmt = .{ .target = expr, .op = coop, .value = value, .token = tok } };
        }
        _ = try self.expect(.semicolon, "expected ';'");
        return ast.Stmt{ .expr_stmt = .{ .value = expr } };
    }

    fn get_compund_op(ty: token.TokenType) ?ast.CompoundOp {
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

    fn parse_print_stub(self: *Parser) !ast.Stmt {
        var tok = try self.lexer.next();
        var stub = ast.PrintStub{ .value = undefined, .token = tok };
        // expect '('
        if (try self.expect(.l_paren, "expected '('") == null) {
            try self.sync(&.{.semicolon});
        }

        tok = try self.lexer.peek_token();
        switch (tok.type) {
            .integer => stub.value = .{ .stub_literal = try self.parse_literal() },
            .ident => stub.value = .{ .stub_ident = try self.parse_ident() },
            else => {
                try self.sync(&.{.semicolon});
            },
        }

        if (try self.expect(.r_paren, "expected ')'") == null) {
            try self.sync(&.{.semicolon});
        }

        // extect ';'
        _ = try self.expect(.semicolon, "expected ';'");

        return ast.Stmt{ .print_stub = stub };
    }

    fn parse_literal(self: *Parser) !ast.LiteralExpr {
        const tok = try self.lexer.next();
        return .{ .kind = .integer, .raw = tok.val, .token = tok };
    }

    fn parse_ident(self: *Parser) !ast.IdentExpr {
        const tok = try self.lexer.next();
        return .{ .name = tok.val, .token = tok };
    }

    fn parse_control_flow_stmt(self: *Parser) !ast.Stmt {
        const tok = try self.lexer.peek_token();

        const cf = switch (tok.type) {
            .kw_if => try self.parse_if_expr(),
            .kw_match => try self.parse_match_expr(),
            .kw_while => try self.parse_while_expr(),
            .kw_for => try self.parse_for_expr(),
            else => unreachable,
        };

        return ast.Stmt{ .control_flow_stmt = cf };
    }

    fn parse_if_expr(self: *Parser) anyerror!ast.ControlFlowStmt {
        var tok = try self.lexer.next();
        var if_expr = ast.IfExpr{
            .cond = undefined,
            .then_body = .empty,
            .elifs = .empty,
            .else_body = null,
            .token = tok,
        };

        if_expr.cond = try self.parse_expression();
        if_expr.then_body = try self.parse_body();

        tok = try self.lexer.peek_token();
        if (tok.type == .kw_elif) {
            if_expr.elifs = try self.parse_elif_clause();
        }

        tok = try self.lexer.peek_token();
        if (tok.type == .kw_else) {
            _ = try self.lexer.next();
            if_expr.else_body = try self.parse_body();
        }

        return .{ .if_expr = if_expr };
    }

    fn parse_elif_clause(self: *Parser) !std.ArrayList(ast.ElifClause) {
        var elifs: std.ArrayList(ast.ElifClause) = .empty;
        while (true) {
            const tok = try self.lexer.next();
            const cond = try self.parse_expression();
            const body = try self.parse_body();
            try elifs.append(self.allocator, .{ .cond = cond, .body = body, .token = tok });
            if ((try self.lexer.peek_token()).type != .kw_elif) break;
        }
        return elifs;
    }

    fn parse_match_expr(self: *Parser) !ast.ControlFlowStmt {
        var tok = try self.lexer.next();
        var match = ast.MatchExpr{
            .subject = undefined,
            .arms = .empty,
            .else_body = null,
            .token = tok,
        };

        // parse expression
        match.subject = try self.parse_expression();

        // if "end" then no body
        tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.kw_end) {
            _ = try self.lexer.next();
        } else if (tok.type == token.TokenType.kw_case) {
            match.arms = try self.parse_match_arms();
        } else {
            // TODO:
        }

        tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.kw_else) {
            match.else_body = try self.parse_else_arm();
        }

        return .{ .match_expr = match };
    }

    fn parse_match_arms(self: *Parser) !std.ArrayList(ast.MatchArm) {
        var tok = try self.lexer.peek_token();
        var arms: std.ArrayList(ast.MatchArm) = .empty;
        while (tok.type != token.TokenType.kw_end and tok.type != token.TokenType.eof and tok.type != token.TokenType.kw_else and tok.type != token.TokenType.kw_match) {
            // parse match pattern
            try arms.append(self.allocator, try self.parse_match_arm());
            // check if the tok is 'case' for 'else'
            tok = try self.lexer.peek_token();
        }
        // 'end' keyword
        if (tok.type == token.TokenType.kw_end)
            _ = try self.lexer.next();

        return arms;
    }

    fn parse_match_arm(self: *Parser) anyerror!ast.MatchArm {
        var tok = try self.lexer.peek_token();
        var match_arm: ast.MatchArm = undefined;
        match_arm.token = tok;
        // expect case keyword
        if (try self.expect(.kw_case, "expected 'case'") == null) {
            try self.sync(&.{ .kw_case, .kw_end });
            return match_arm;
        }

        tok = try self.lexer.next();
        switch (tok.type) {
            .integer, .char, .kw_true, .kw_false => match_arm.pattern = try self.parse_literal_pattern(tok),
            .ident => match_arm.pattern = try self.parse_variant_pattern(),
            else => {
                // TODO: error handling
            },
        }

        match_arm.body = try self.parse_body();

        return match_arm;
    }

    fn parse_else_arm(self: *Parser) anyerror!std.ArrayList(ast.Stmt) {
        _ = try self.lexer.next();
        return try self.parse_body();
    }

    fn parse_literal_pattern(self: *Parser, tok: token.Token) !ast.Pattern {
        _ = self;
        return switch (tok.type) {
            .integer => .{ .integer = tok.val },
            .char => .{ .ident = tok.val },
            .kw_false => .{ .boolean = false },
            .kw_true => .{ .boolean = true },
            else => unreachable,
        };
    }

    fn parse_variant_pattern(self: *Parser) !ast.Pattern {
        _ = self;
        // TODO:
        return error.TODO;
    }

    fn parse_while_expr(self: *Parser) anyerror!ast.ControlFlowStmt {
        const tok = try self.lexer.next();
        var while_expr = ast.WhileExpr{
            .cond = undefined,
            .body = .empty,
            .token = tok,
        };

        while_expr.cond = try self.parse_expression();
        while_expr.body = try self.parse_body();

        return .{ .while_expr = while_expr };
    }

    fn parse_for_expr(self: *Parser) anyerror!ast.ControlFlowStmt {
        const tok = try self.lexer.next();
        var for_expr = ast.ForExpr{
            .binding = undefined,
            .iterable = undefined,
            .body = .empty,
            .token = tok,
        };

        const binding_tok = try self.expect(.ident, "expected identifier") orelse
            token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        for_expr.binding = binding_tok.val;

        var peek_tok = try self.lexer.peek_token();
        if (peek_tok.type == .comma) {
            _ = try self.lexer.next();
            const idx_tok = try self.expect(.ident, "expected identifier") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
            for_expr.index_binding = idx_tok.val;
        }

        if (try self.expect(.kw_in, "expected 'in'") == null) {
            try self.sync(&.{.kw_end});
            if ((try self.lexer.peek_token()).type == .kw_end) {
                _ = try self.lexer.next();
            }
            for_expr.iterable = try self.error_expr(tok);
            for_expr.body = try self.parse_body();
            return .{ .for_expr = for_expr };
        }

        for_expr.iterable = try self.parse_expression();

        var range_tok: ?token.Token = null;
        peek_tok = try self.lexer.peek_token();
        if (peek_tok.type == .comma) {
            range_tok = peek_tok;
            _ = try self.lexer.next();
            for_expr.index_start = try self.parse_expression_bp(16);
            _ = try self.expect(.dot_dot, "expected '..'");
        } else if (for_expr.index_binding != null and (peek_tok.type == .integer or peek_tok.type == .float)) {
            try self.compiler.addError("expected ',' before index range", err.Severity.Error, peek_tok);
            try self.sync(&.{.kw_end});
            if ((try self.lexer.peek_token()).type == .kw_end) {
                _ = try self.lexer.next();
            }
            for_expr.body = .empty;
            return .{ .for_expr = for_expr };
        }

        // so for case like for val, i in arr ... end
        // here enumerate start not give, so be default I make it 0
        if (for_expr.index_binding != null and for_expr.index_start == null) {
            const zero = try self.allocator.create(ast.Expr);
            zero.* = .{ .literal = .{ .kind = .integer, .raw = "0", .token = tok } };
            for_expr.index_start = zero;
        }
        // for val in arr, 0..
        if (for_expr.index_binding == null and for_expr.index_start != null) {
            try self.compiler.add_sem_error("index range needs a second binding, e.g. 'for val, idx in ...'", .{}, err.Severity.Error, range_tok.?);
        }

        for_expr.body = try self.parse_body();

        return .{ .for_expr = for_expr };
    }

    pub fn parse_type(self: *Parser) anyerror!*ast.Type {
        const start_tok = try self.lexer.peek_token();

        var is_optional = false;
        if (start_tok.type == token.TokenType.optional) {
            _ = try self.lexer.next();
            is_optional = true;
        }

        const base = try self.parse_base_type();

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

    fn error_expr(self: *Parser, tok: token.Token) !*ast.Expr {
        const e = try self.allocator.create(ast.Expr);
        e.* = .{ .ident = .{ .name = "<error>", .token = tok } };
        return e;
    }

    fn parse_base_type(self: *Parser) anyerror!ast.BaseType {
        const tok = try self.lexer.next();

        switch (tok.type) {
            .star => {
                const pointee = try self.parse_type();
                return ast.BaseType{ .pointer = pointee };
            },
            .l_bracket => {
                const nxt = try self.lexer.peek_token();
                if (nxt.type == .r_bracket) {
                    return try self.parse_slice_type(tok);
                }
                return try self.parse_array_type(tok);
            },
            .kw_func => return try self.parse_func_type(tok),
            .kw_proc => return try self.parse_proc_type(tok),
            .ident, .kw_ptr => {
                if (std.meta.stringToEnum(ast.PrimitiveType, tok.val)) |prim| {
                    return ast.BaseType{ .primitive = prim };
                }
                return try self.parse_named_type(tok);
            },
            else => {
                try self.compiler.addError("expected a type", err.Severity.Error, tok);
                return ast.BaseType{ .named = .{ .name = tok.val, .args = &[_]*ast.Type{}, .token = tok } };
            },
        }
    }

    fn parse_slice_type(self: *Parser, tok: token.Token) !ast.BaseType {
        _ = try self.lexer.next();
        const elem = try self.parse_type();
        return ast.BaseType{ .slice = .{ .elem = elem, .token = tok } };
    }

    fn parse_array_type(self: *Parser, tok: token.Token) !ast.BaseType {
        const size_tok = try self.lexer.peek_token();
        var size: ast.ArraySize = .inferred;

        if (size_tok.type == token.TokenType.integer) {
            _ = try self.lexer.next();
            size = .{ .fixed = size_tok.val };
        } else if (size_tok.type == token.TokenType.ident and std.mem.eql(u8, size_tok.val, "_")) {
            _ = try self.lexer.next();
            size = .inferred;
        } else {
            try self.compiler.addError("expected an INTEGER or '_'", err.Severity.Error, size_tok);
        }

        if (try self.expect(.r_bracket, "expected ']'") == null) {
            try self.sync(&.{ .comma, .r_paren });
            return ast.BaseType{ .array = .{ .size = size, .elem = try self.error_type(tok), .token = tok } };
        }

        const elem = try self.parse_type();

        return ast.BaseType{ .array = ast.ArrayType{ .size = size, .elem = elem, .token = tok } };
    }

    fn parse_func_type(self: *Parser, tok: token.Token) !ast.BaseType {
        _ = try self.expect(.l_paren, "expected '('");

        const params = try self.parse_type_list();

        if (try self.expect(.arrow, "expected '->'") == null) {
            try self.sync(&.{ .r_paren, .comma });
            return ast.BaseType{ .func = .{ .params = params, .result = try self.error_type(tok), .token = tok } };
        }
        const result = try self.parse_type();

        return ast.BaseType{ .func = ast.FuncType{ .params = params, .result = result, .token = tok } };
    }

    fn parse_proc_type(self: *Parser, tok: token.Token) !ast.BaseType {
        if (try self.expect(.l_paren, "expected '('") == null) {
            try self.sync(&.{ .r_paren, .comma });
            return ast.BaseType{ .proc = ast.ProcType{ .params = .empty, .token = tok } };
        }
        const params = try self.parse_type_list();
        return ast.BaseType{ .proc = ast.ProcType{ .params = params, .token = tok } };
    }

    fn parse_type_list(self: *Parser) !std.ArrayList(*ast.Type) {
        var types: std.ArrayList(*ast.Type) = .empty;

        const first = try self.lexer.peek_token();
        if (first.type == token.TokenType.r_paren) {
            _ = try self.lexer.next();
            return types;
        }

        while (true) {
            try types.append(self.allocator, try self.parse_type());

            const sep = try self.lexer.next();
            switch (sep.type) {
                .r_paren => break,
                .comma => {
                    const nxt = try self.lexer.peek_token();
                    if (nxt.type == token.TokenType.r_paren) {
                        _ = try self.lexer.next();
                        break;
                    }
                    continue;
                },
                else => {
                    try self.compiler.addError("expected ',' or ')'", err.Severity.Error, sep);

                    try self.sync(&.{ .comma, .r_paren });
                    const peek_tok = try self.lexer.peek_token();
                    if (peek_tok.type == .comma) {
                        _ = try self.lexer.next();
                        continue;
                    } else if (peek_tok.type == .r_paren) {
                        _ = try self.lexer.next();
                    } else {
                        break;
                    }
                },
            }
        }
        return types;
    }

    fn parse_named_type(self: *Parser, tok: token.Token) !ast.BaseType {
        var args: std.ArrayList(*ast.Type) = .empty;

        var nxt = try self.lexer.peek_token();
        if (nxt.type != token.TokenType.l_bracket) {
            return ast.BaseType{ .named = .{ .name = tok.val, .args = &[_]*ast.Type{}, .token = tok } };
        }
        _ = try self.lexer.next();

        while (true) {
            try args.append(self.allocator, try self.parse_type());

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

    pub fn parse_result(self: *Parser) !*ast.Type {
        return self.parse_type();
    }

    pub fn parse_import_def(self: *Parser) !ast.ImportDef {
        var tok = try self.lexer.next();
        var import_def = ast.ImportDef{ .path = .empty, .token = tok };
        while (true) {
            // expect an ident
            tok = try self.expect(.ident, "expected ident ") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };

            try import_def.path.append(self.allocator, tok.val);
            // can be a '.'
            tok = try self.lexer.next();
            if (tok.type == token.TokenType.semicolon) break;
            if (tok.type != token.TokenType.dot) {
                if (tok.type != token.TokenType.dot) {
                    try self.compiler.addError("expected . or ; ", err.Severity.Error, tok);
                    try self.sync(&.{ .semicolon, .kw_import, .kw_func, .kw_const, .kw_var, .kw_type, .kw_extern, .kw_pub, .kw_proc });
                    break;
                }
            }
        }
        return import_def;
    }

    pub fn parse_const_def(self: *Parser) !ast.ConstDef {
        var tok = try self.lexer.next();
        var const_def = ast.ConstDef{
            .is_pub = false,
            .is_global = false,
            .name = "",
            .type_ann = null,
            .value = undefined,
            .token = tok,
        };

        // expect name ident
        tok = try self.expect(.ident, "expected name ident ") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        const_def.name = tok.val;

        // if ':' parse type
        tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.colon) {
            _ = try self.lexer.next();
            const_def.type_ann = try self.parse_type();
        }

        // expect '='
        _ = try self.expect(.eq, "expected '='");
        const_def.value = try self.parse_expression();

        // extect ';' if not struct literal
        switch (const_def.value.*) {
            .struct_literal => {},
            else => {
                _ = try self.expect(.semicolon, "expected ';'");
            },
        }

        return const_def;
    }

    pub fn parse_var_def(self: *Parser) !ast.VarDef {
        var tok = try self.lexer.next();
        var var_def = ast.VarDef{
            .is_pub = false,
            .is_global = false,
            .name = "",
            .type_ann = null,
            .value = undefined,
            .token = tok,
        };

        // expect name ident
        tok = try self.expect(.ident, "expected name ident ") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
        var_def.name = tok.val;

        // if ':' parse type
        tok = try self.lexer.peek_token();
        if (tok.type == token.TokenType.colon) {
            _ = try self.lexer.next();
            var_def.type_ann = try self.parse_type();
        }

        // expect '='
        _ = try self.expect(.eq, "expected '='");
        var_def.value = try self.parse_expression();

        // extect ';' if not struct literal
        switch (var_def.value.*) {
            .struct_literal => {},
            else => {
                _ = try self.expect(.semicolon, "expected ';'");
            },
        }

        return var_def;
    }

    pub fn parse_expression_statement(self: *Parser) !ast.Stmt {
        const e = try self.parse_expression();
        // expect ';'
        _ = try self.expect(.semicolon, "expected ';'");
        return .{ .expr_stmt = .{ .value = e } };
    }

    pub fn parse_call_expression(self: *Parser, callee: *ast.Expr) anyerror!ast.CallExpr {
        // TODO: check if tok is ok to peek here
        var tok = try self.lexer.peek_token();
        var c_expr = ast.CallExpr{
            .callee = callee,
            .args = .empty,
            .token = tok,
        };

        // expect a '('
        tok = (try self.expect(.l_paren, "expected '('")).?;
        tok = try self.lexer.peek_token();
        if (tok.type == .r_paren) {
            _ = try self.lexer.next(); // consume ')'
            return c_expr;
        }
        while (true) {
            const arg = try self.parse_call_arg();
            try c_expr.args.append(self.allocator, arg);

            tok = try self.lexer.next();
            switch (tok.type) {
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
                    try self.compiler.addError("expected ',' or ')'", err.Severity.Error, tok);
                    try self.sync(&.{ .comma, .r_paren });
                    const peek_tok = try self.lexer.peek_token();
                    if (peek_tok.type == .comma) {
                        _ = try self.lexer.next();
                        continue;
                    } else if (peek_tok.type == .r_paren) {
                        _ = try self.lexer.next();
                        break;
                    } else break;
                },
            }
        }
        return c_expr;
    }

    pub fn parse_call_arg(self: *Parser) anyerror!ast.CallArg {
        var c_arg = ast.CallArg{
            .value = undefined,
        };

        c_arg.value = try self.parse_expression();

        return c_arg;
    }

    pub fn parse_expression(self: *Parser) !*ast.Expr {
        return try self.parse_expression_bp(0);
    }

    pub fn parse_expression_bp(self: *Parser, min_bp: usize) !*ast.Expr {
        var lhs: *ast.Expr = undefined;
        var tok = try self.lexer.next();
        switch (tok.type) {
            .integer => {
                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{ .literal = .{
                    .kind = ast.LiteralKind.integer,
                    .raw = tok.val,
                    .token = tok,
                } };
            },
            .float => {
                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{ .literal = .{
                    .kind = ast.LiteralKind.float,
                    .raw = tok.val,
                    .token = tok,
                } };
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
                    .kind = get_bool_type(tok.type),
                    .raw = tok.val,
                    .token = tok,
                } };
            },
            .kw_nil => {
                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{ .nil = .{ .token = tok } };
            },
            .l_paren => {
                lhs = try self.parse_expression_bp(0);
                // expect ')'
                _ = try self.expect(.r_paren, "expected ')'");
            },
            .minus, .bang, .tilde, .amp, .star, .kw_new => {
                const p_bp = prefix_binding_power(tok.type);
                const rhs = try self.parse_expression_bp(p_bp[1]);
                lhs = try self.allocator.create(ast.Expr);
                lhs.* = .{
                    .unary = .{
                        .op = get_unary_op(tok.type),
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
                        try elems.append(self.allocator, try self.parse_expression_bp(0));
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

            if (postfix_binding_power(op)) |p_bp| {
                if (p_bp[0] < min_bp) break;
                if (tok.type == token.TokenType.l_paren) {
                    const prev_lhs = lhs;
                    lhs = try self.allocator.create(ast.Expr);
                    lhs.* = .{ .call = try self.parse_call_expression(prev_lhs) };
                } else if (tok.type == .dot) {
                    _ = try self.lexer.next();
                    const f = try self.expect(.ident, "expected field name") orelse token.Token{ .type = .ident, .val = "<error>", .line = tok.line, .col = tok.col };
                    const tmp = lhs;
                    lhs = try self.allocator.create(ast.Expr);
                    lhs.* = .{ .field_access = .{ .target = tmp, .field = f.val, .token = f } };
                } else if (tok.type == .l_bracket) {
                    _ = try self.lexer.next();
                    var args: std.ArrayList(*ast.Expr) = .empty;
                    while (true) {
                        try args.append(self.allocator, try self.parse_expression_bp(0));
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
                                const f = try self.parse_struct_literal();
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

            const i_bp = infix_binding_power(op);
            if (i_bp[0] < min_bp) break;

            tok = try self.lexer.next();
            const rhs = try self.parse_expression_bp(i_bp[1]);

            const prev_lhs = lhs;
            lhs = try self.allocator.create(ast.Expr);
            lhs.* = .{
                .binary = .{
                    .lhs = prev_lhs,
                    .op = get_binary_op(op),
                    .rhs = rhs,
                    .token = tok,
                },
            };
        }

        return lhs;
    }
};

fn infix_binding_power(op: token.TokenType) [2]usize {
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

fn prefix_binding_power(op: token.TokenType) [2]usize {
    return switch (op) {
        .minus, .bang_eq, .tilde, .amp, .star, .kw_new => .{ 0, 5 },
        else => .{ 0, 0 },
    };
}

fn postfix_binding_power(op: token.TokenType) ?[2]usize {
    return switch (op) {
        .l_paren, .dot, .l_bracket, .kw_where => .{ 21, 22 },
        else => null,
    };
}

fn get_binary_op(op: token.TokenType) ast.BinaryOp {
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

fn get_unary_op(op: token.TokenType) ast.UnaryOp {
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

fn get_bool_type(op: token.TokenType) ast.LiteralKind {
    return switch (op) {
        .kw_true => ast.LiteralKind.bool_true,
        .kw_false => ast.LiteralKind.bool_false,
        else => unreachable,
    };
}
