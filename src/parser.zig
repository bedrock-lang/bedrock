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
            .lexer = lexer.Lexer.init(source),
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
        // TODO: replace the [] fields with arrayList
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
                    //todo:implement parse_type_item
                },
                .kw_extern => {
                    //todo: error if is_pub or is_inline set (extern takes no modifiers)
                    //todo: parse_extern_def();
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

                    const hmm = try self.lexer.peek_token();
                    if (hmm.type == .comma) {
                        _ = try self.lexer.next();
                        continue;
                    } else if (hmm.type == .r_paren) {
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

        const tok = try self.lexer.next();
        try params.append(self.allocator, ast.TypeParam{ .name = tok.val, .token = tok });
        _ = try self.expect(.r_bracket, "expected ']'");

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
            .kw_if, .kw_match, .kw_while, .kw_for => try self.parse_control_flow_stmt(),
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

        // extect ';'
        _ = try self.expect(.semicolon, "expected ';'");

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

        // extect ';'
        _ = try self.expect(.semicolon, "expected ';'");

        return ast.Stmt{ .const_stmt = const_stmt };
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
        const value = try self.parse_expression();
        _ = try self.expect(.semicolon, "expected ';'");
        return ast.Stmt{ .return_stmt = .{ .value = value, .token = tok } };
    }

    // todo: make this such to be able to parse assign statements like
    // a = 10;
    // a = b;
    fn parse_expr_or_assign_stmt(self: *Parser) !ast.Stmt {
        const value = try self.parse_expression();
        _ = try self.expect(.semicolon, "expected ';'");
        return ast.Stmt{ .expr_stmt = .{ .value = value } };
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

        return .{ .match_expr = match };
    }

    fn parse_match_arms(self: *Parser) !std.ArrayList(ast.MatchArm) {
        var tok = try self.lexer.peek_token();
        var arms: std.ArrayList(ast.MatchArm) = .empty;
        while (tok.type != token.TokenType.kw_end and tok.type != token.TokenType.eof) {
            // parse match pattern
            try arms.append(self.allocator, try self.parse_match_arm());
            // check if the tok is 'case' for 'else'
            tok = try self.lexer.peek_token();
        }
        // 'end' keyword
        _ = try self.expect(.kw_end, "expected 'end'");

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
            .integer => {
                match_arm.pattern = try self.parse_literal_pattern(tok);
            },
            else => {
                // TODO:
            },
        }

        match_arm.body = try self.parse_body();

        return match_arm;
    }

    fn parse_literal_pattern(self: *Parser, tok: token.Token) !ast.Pattern {
        _ = self;
        return switch (tok.type) {
            .integer => .{ .integer = tok.val },
            .ident => .{ .ident = tok.val },
            .kw_false => .{ .boolean = false },
            .kw_true => .{ .boolean = true },
            else => unreachable,
        };
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

        _ = try self.expect(.kw_in, "expected 'in'");

        for_expr.iterable = try self.parse_expression();
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

    fn parse_base_type(self: *Parser) anyerror!ast.BaseType {
        const tok = try self.lexer.next();

        switch (tok.type) {
            .star => {
                const pointee = try self.parse_type();
                return ast.BaseType{ .pointer = pointee };
            },
            .l_bracket => return try self.parse_array_type(tok),
            .kw_func => return try self.parse_func_type(tok),
            .kw_proc => return try self.parse_proc_type(tok),
            .ident => {
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

    fn parse_array_type(self: *Parser, tok: token.Token) !ast.BaseType {
        const size_tok = try self.lexer.peek_token();
        var size: ast.ArraySize = .inferred;

        if (size_tok.type == token.TokenType.integer) {
            _ = try self.lexer.next();
            size = .{ .fixed = size_tok.val };
        } else if (size_tok.type == token.TokenType.ident and std.mem.eql(u8, size_tok.val, "_")) {
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
                    const hmm = try self.lexer.peek_token();
                    if (hmm.type == .comma) {
                        _ = try self.lexer.next();
                        continue;
                    } else if (hmm.type == .r_paren) {
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
                const hmm = try self.lexer.peek_token();
                if (hmm.type == .comma) {
                    _ = try self.lexer.next();
                    continue;
                } else if (hmm.type == .r_bracket) {
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

        // extect ';'
        _ = try self.expect(.semicolon, "expected ';'");

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

        // extect ';'
        _ = try self.expect(.semicolon, "expected ';'");

        return var_def;
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
            .l_paren => {
                lhs = try self.parse_expression_bp(0);
                // expect ')'
                _ = try self.expect(.r_paren, "expected ')'");
            },
            .minus, .bang, .tilde, .amp, .star => {
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
            else => {
                // TODO:
            },
        }

        while (true) {
            tok = try self.lexer.peek_token();
            // expect a operator
            const op = switch (tok.type) {
                .plus, .minus, .star, .slash, .eq_eq, .gt_eq, .lt_eq, .bang_eq, .gt, .lt => tok.type,
                else => break,
            };

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
        .eq_eq, .gt_eq, .lt_eq, .bang_eq, .gt, .lt => .{ 1, 2 },
        .plus, .minus => .{ 3, 4 },
        .star, .slash => .{ 5, 6 },
        else => .{ 0, 0 },
    };
}

fn prefix_binding_power(op: token.TokenType) [2]usize {
    return switch (op) {
        .minus, .bang_eq, .tilde, .amp, .star => .{ 0, 5 },
        else => .{ 0, 0 },
    };
}

fn get_binary_op(op: token.TokenType) ast.BinaryOp {
    return switch (op) {
        .plus => ast.BinaryOp.add,
        .minus => ast.BinaryOp.sub,
        .star => ast.BinaryOp.mul,
        .slash => ast.BinaryOp.div,
        .eq_eq => ast.BinaryOp.eq,
        .gt_eq => ast.BinaryOp.ge,
        .lt_eq => ast.BinaryOp.le,
        .bang_eq => ast.BinaryOp.ne,
        .gt => ast.BinaryOp.gt,
        .lt => ast.BinaryOp.lt,
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
