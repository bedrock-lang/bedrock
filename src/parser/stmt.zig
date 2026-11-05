const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const ops = @import("ops.zig");
const Parser = @import("parser.zig").Parser;

const decls_mod = @import("decls.zig");
const control_mod = @import("control_flow.zig");
const expr_mod = @import("expr.zig");

pub fn parse_body(self: *Parser) anyerror!std.ArrayList(ast.Stmt) {
    var stmts: std.ArrayList(ast.Stmt) = .empty;
    while (true) {
        const tok = try self.lexer.peek_token();
        if (tok.type == .kw_end or tok.type == .kw_elif or tok.type == .kw_else or tok.type == .eof or tok.type == .kw_case) break;
        var stmt = try parse_statement(self);
        try stmts.append(self.allocator, stmt);
        // `var a = 1, b = 2;` style continuations
        while ((try self.lexer.peek_token()).type == .comma) {
            stmt = switch (stmt) {
                .var_stmt => try decls_mod.parse_var_stmt(self),
                .const_stmt => try decls_mod.parse_const_stmt(self),
                .local_static_var_stmt => try decls_mod.parse_local_static_var_stmt(self),
                else => break,
            };
            try stmts.append(self.allocator, stmt);
        }
    }
    const tok = try self.lexer.peek_token();
    switch (tok.type) {
        .kw_end => _ = try self.lexer.next(),
        .kw_elif, .kw_else, .kw_case => {},
        else => {
            try self.compiler.add_sem_error("expected 'end' to close block", .{}, err.Severity.Error, tok);
        },
    }
    return stmts;
}

pub fn parse_statement(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.peek_token();

    return switch (tok.type) {
        .kw_var => try decls_mod.parse_var_stmt(self),
        .kw_const => try decls_mod.parse_const_stmt(self),
        .kw_static => try decls_mod.parse_local_static_var_stmt(self),
        .kw_defer => try parse_defer_stmt(self),
        .kw_unsafe => try parse_unsafe_stmt(self),
        .kw_return => try parse_return_stmt(self),
        .kw_break => try parse_break(self),
        .kw_continue => try parse_continue(self),
        .kw_if, .kw_match, .kw_while, .kw_for => try control_mod.parse_control_flow_stmt(self),
        // NOTE: "bokbok" is a temporary print stub
        .ident => if (std.mem.eql(u8, tok.val, "bokbok"))
            try parse_print_stub(self)
        else
            try parse_expr_or_assign_stmt(self),
        else => try parse_expr_or_assign_stmt(self),
    };
}

pub fn parse_expression_statement(self: *Parser) anyerror!ast.Stmt {
    const e = try expr_mod.parse_expression(self);
    // expect ';'
    _ = try self.expect(.semicolon, "expected ';'");
    return .{ .expr_stmt = .{ .value = e } };
}

fn parse_break(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.next();
    _ = try self.expect(.semicolon, "expected ';'");
    return ast.Stmt{ .break_stmt = .{ .token = tok } };
}

fn parse_continue(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.next();
    _ = try self.expect(.semicolon, "expected ';'");
    return ast.Stmt{ .continue_stmt = .{ .token = tok } };
}

fn parse_defer_stmt(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.next();
    const statement_list = try parse_body(self);
    return ast.Stmt{ .defer_stmt = .{ .statement_list = statement_list, .token = tok } };
}

fn parse_unsafe_stmt(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.next();
    const body = try parse_body(self);
    return ast.Stmt{ .unsafe_stmt = .{ .body = body, .token = tok } };
}

fn parse_return_stmt(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.next();
    if ((try self.lexer.peek_token()).type == .semicolon) {
        _ = try self.lexer.next();
        return ast.Stmt{ .return_stmt = .{ .value = null, .token = tok } };
    }
    const value = try expr_mod.parse_expression(self);
    _ = try self.expect(.semicolon, "expected ';'");
    return ast.Stmt{ .return_stmt = .{ .value = value, .token = tok } };
}

fn parse_expr_or_assign_stmt(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.peek_token();
    const expr = try expr_mod.parse_expression(self);
    const op = try self.lexer.peek_token();
    const coop = ops.get_compound_op(op.type);
    if (op.type == .eq or coop != null) {
        _ = try self.lexer.next();
        const value = try expr_mod.parse_expression(self);
        _ = try self.expect(.semicolon, "expected ';'");
        return ast.Stmt{ .assign_stmt = .{ .target = expr, .op = coop, .value = value, .token = tok } };
    }
    _ = try self.expect(.semicolon, "expected ';'");
    return ast.Stmt{ .expr_stmt = .{ .value = expr } };
}

fn parse_print_stub(self: *Parser) anyerror!ast.Stmt {
    var tok = try self.lexer.next();
    var stub = ast.PrintStub{ .value = undefined, .token = tok };
    // expect '('
    if (try self.expect(.l_paren, "expected '('") == null) {
        try self.sync(&.{.semicolon});
    }

    tok = try self.lexer.peek_token();
    switch (tok.type) {
        .integer => stub.value = .{ .stub_literal = try expr_mod.parse_literal(self) },
        .ident => stub.value = .{ .stub_ident = try expr_mod.parse_ident(self) },
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
