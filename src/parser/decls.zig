const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const Parser = @import("parser.zig").Parser;

const types_mod = @import("types.zig");
const expr_mod = @import("expr.zig");

// Everything `var`, `const` and `static var` have in common
// <kw> name [: type] = expr
const Binding = struct {
    name: []const u8,
    type_ann: ?*ast.Type,
    value: *ast.Expr,
    token: token.Token,
};

// When the trailing ',' / ';' is required after the initializer.
const DeclEnd = enum {
    // always expect it
    always,
    // not after a struct literal or comptime block (they end with 'end')
    unless_literal,
    // same as above, plus `<unary> <struct literal>` such as `new T where ... end`
    unless_literal_or_new,
};

fn needs_decl_end(value: *const ast.Expr, end: DeclEnd) bool {
    if (end == .always) return true;
    return switch (value.*) {
        .struct_literal, .comptime_expr => false,
        .unary => |u| if (end == .unless_literal_or_new) u.operand.* != .struct_literal else true,
        else => true,
    };
}

/// Consumes the leading token (`var`, `const`, `static`, or the ',' of a
/// `a = 1, b = 2` continuation), then name, optional type, '=' and value.
fn parse_binding(self: *Parser, end: DeclEnd) anyerror!Binding {
    const lead = try self.lexer.next();
    if (lead.type == .kw_static) _ = try self.expect(.kw_var, "expected 'var'");

    const name_tok = try self.expect_ident("expected name ident", lead);
    // if ':' parse type
    var type_ann: ?*ast.Type = null;
    if ((try self.lexer.peek_token()).type == token.TokenType.colon) {
        _ = try self.lexer.next();
        type_ann = try types_mod.parse_type(self);
    }

    // expect '='
    _ = try self.expect(.eq, "expected '='");
    const value = try expr_mod.parse_expression(self);

    // expect ',' or ';'
    if (needs_decl_end(value, end)) try self.expect_decl_end();

    return .{ .name = name_tok.val, .type_ann = type_ann, .value = value, .token = lead };
}

pub fn parse_var_stmt(self: *Parser) anyerror!ast.Stmt {
    const b = try parse_binding(self, .unless_literal_or_new);
    return ast.Stmt{ .var_stmt = .{ .name = b.name, .type_ann = b.type_ann, .value = b.value, .token = b.token } };
}

pub fn parse_const_stmt(self: *Parser) anyerror!ast.Stmt {
    const b = try parse_binding(self, .unless_literal);
    return ast.Stmt{ .const_stmt = .{ .name = b.name, .type_ann = b.type_ann, .value = b.value, .token = b.token } };
}

pub fn parse_local_static_var_stmt(self: *Parser) anyerror!ast.Stmt {
    const b = try parse_binding(self, .always);
    return ast.Stmt{ .local_static_var_stmt = .{ .name = b.name, .type_ann = b.type_ann, .value = b.value, .token = b.token } };
}

pub fn parse_var_def(self: *Parser) anyerror!ast.VarDef {
    const b = try parse_binding(self, .unless_literal);
    return ast.VarDef{
        .is_pub = false,
        .is_global = false,
        .name = b.name,
        .type_ann = b.type_ann,
        .value = b.value,
        .token = b.token,
    };
}

pub fn parse_const_def(self: *Parser) anyerror!ast.ConstDef {
    const b = try parse_binding(self, .unless_literal);
    return ast.ConstDef{
        .is_pub = false,
        .is_global = false,
        .name = b.name,
        .type_ann = b.type_ann,
        .value = b.value,
        .token = b.token,
    };
}
