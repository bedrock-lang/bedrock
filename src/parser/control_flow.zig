const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const Parser = @import("parser.zig").Parser;

const stmt_mod = @import("stmt.zig");
const expr_mod = @import("expr.zig");
const pattern_mod = @import("pattern.zig");

pub fn parse_control_flow_stmt(self: *Parser) anyerror!ast.Stmt {
    const tok = try self.lexer.peek_token();

    const cf = switch (tok.type) {
        .kw_if => try parse_if_expr(self),
        .kw_match => try parse_match_expr(self),
        .kw_while => try parse_while_expr(self),
        .kw_for => try parse_for_expr(self),
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

    if_expr.cond = try expr_mod.parse_expression(self);
    if_expr.then_body = try stmt_mod.parse_body(self);

    tok = try self.lexer.peek_token();
    if (tok.type == .kw_elif) {
        if_expr.elifs = try parse_elif_clause(self);
    }

    tok = try self.lexer.peek_token();
    if (tok.type == .kw_else) {
        _ = try self.lexer.next();
        if_expr.else_body = try stmt_mod.parse_body(self);
    }

    return .{ .if_expr = if_expr };
}

fn parse_elif_clause(self: *Parser) anyerror!std.ArrayList(ast.ElifClause) {
    var elifs: std.ArrayList(ast.ElifClause) = .empty;
    while (true) {
        const tok = try self.lexer.next();
        const cond = try expr_mod.parse_expression(self);
        const body = try stmt_mod.parse_body(self);
        try elifs.append(self.allocator, .{ .cond = cond, .body = body, .token = tok });
        if ((try self.lexer.peek_token()).type != .kw_elif) break;
    }
    return elifs;
}

fn parse_match_expr(self: *Parser) anyerror!ast.ControlFlowStmt {
    var tok = try self.lexer.next();
    var match = ast.MatchExpr{
        .subject = undefined,
        .arms = .empty,
        .else_body = null,
        .token = tok,
    };

    // parse expression
    match.subject = try expr_mod.parse_expression(self);

    // if "end" then no body
    tok = try self.lexer.peek_token();
    if (tok.type == token.TokenType.kw_end) {
        _ = try self.lexer.next();
    } else if (tok.type == token.TokenType.kw_case) {
        match.arms = try parse_match_arms(self);
    } else {
        try self.compiler.addError("expected 'case' or 'end' after match subject", err.Severity.Error, tok);
        try self.sync(&.{ .kw_end, .kw_case, .kw_else });
        if ((try self.lexer.peek_token()).type == .kw_case) {
            match.arms = try parse_match_arms(self);
        } else if ((try self.lexer.peek_token()).type == .kw_end) {
            _ = try self.lexer.next();
        }
    }

    tok = try self.lexer.peek_token();
    if (tok.type == token.TokenType.kw_else) {
        match.else_body = try parse_else_arm(self);
    }

    return .{ .match_expr = match };
}

fn parse_match_arms(self: *Parser) anyerror!std.ArrayList(ast.MatchArm) {
    var arms: std.ArrayList(ast.MatchArm) = .empty;
    while (true) {
        const tok = try self.lexer.peek_token();
        switch (tok.type) {
            .kw_case => {
                const arm = try parse_match_arm(self);
                try arms.append(self.allocator, arm);
                const nxt = try self.lexer.peek_token();
                if (nxt.type != .kw_case) break;
            },
            .kw_else => break,
            .kw_end => {
                _ = try self.lexer.next();
                break;
            },
            else => {
                try self.compiler.addError("expected 'case', 'else', or 'end'", err.Severity.Error, tok);
                try self.sync(&.{ .kw_case, .kw_else, .kw_end });
            },
        }
    }

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
        .integer, .char, .kw_true, .kw_false => match_arm.pattern = try pattern_mod.parse_literal_pattern(self, tok),
        .ident => match_arm.pattern = try pattern_mod.parse_variant_pattern(self, tok),
        else => {
            try self.compiler.addError("expected pattern", err.Severity.Error, tok);
            try self.sync(&.{ .comma, .r_paren, .kw_end });
        },
    }

    match_arm.body = try stmt_mod.parse_body(self);

    return match_arm;
}

fn parse_else_arm(self: *Parser) anyerror!std.ArrayList(ast.Stmt) {
    _ = try self.lexer.next();
    return try stmt_mod.parse_body(self);
}

fn parse_while_expr(self: *Parser) anyerror!ast.ControlFlowStmt {
    const tok = try self.lexer.next();
    var while_expr = ast.WhileExpr{
        .cond = undefined,
        .body = .empty,
        .token = tok,
    };

    while_expr.cond = try expr_mod.parse_expression(self);
    while_expr.body = try stmt_mod.parse_body(self);

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

    const binding_tok = try self.expect_ident("expected identifier", tok);
    for_expr.binding = binding_tok.val;

    var peek_tok = try self.lexer.peek_token();
    if (peek_tok.type == .comma) {
        _ = try self.lexer.next();
        const idx_tok = try self.expect_ident("expected identifier", tok);
        for_expr.index_binding = idx_tok.val;
    }

    if (try self.expect(.kw_in, "expected 'in'") == null) {
        try self.sync(&.{.kw_end});
        if ((try self.lexer.peek_token()).type == .kw_end) {
            _ = try self.lexer.next();
        }
        for_expr.iterable = try self.error_expr(tok);
        for_expr.body = try stmt_mod.parse_body(self);
        return .{ .for_expr = for_expr };
    }

    for_expr.iterable = try expr_mod.parse_expression(self);

    var range_tok: ?token.Token = null;
    peek_tok = try self.lexer.peek_token();
    if (peek_tok.type == .comma) {
        range_tok = peek_tok;
        _ = try self.lexer.next();
        for_expr.index_start = try expr_mod.parse_expression_bp(self, 16);
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
        for_expr.index_start = try self.alloc_expr(.{ .literal = .{ .kind = .integer, .raw = "0", .token = tok } });
    }
    // for val in arr, 0..
    if (for_expr.index_binding == null and for_expr.index_start != null) {
        try self.compiler.add_sem_error("index range needs a second binding, e.g. 'for val, idx in ...'", .{}, err.Severity.Error, range_tok.?);
    }

    for_expr.body = try stmt_mod.parse_body(self);

    return .{ .for_expr = for_expr };
}
