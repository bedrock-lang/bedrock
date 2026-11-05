const std = @import("std");
const bedrock = @import("bedrock");
const ast = bedrock.ast;
const compiler = bedrock.compiler;
const parser = bedrock.parser;
const p_expr = bedrock.parse_expr;
const p_stmt = bedrock.parse_stmt;
const p_type = bedrock.parse_type;
const cli = bedrock.cli;

const StmtResult = struct {
    stmt: ast.Stmt,
    c: *compiler.Compiler,
    fn deinit(self: *StmtResult, allocator: std.mem.Allocator) !void {
        self.stmt.deinit(allocator);
        try self.c.deinit();
        allocator.destroy(self.c);
    }
};

const TypeResult = struct {
    ty: *ast.Type,
    c: *compiler.Compiler,
    fn deinit(self: TypeResult, allocator: std.mem.Allocator) !void {
        self.ty.deinit(allocator);
        allocator.destroy(self.ty);
        try self.c.deinit();
        allocator.destroy(self.c);
    }
};

fn parse_type(allocator: std.mem.Allocator, source: []const u8) !TypeResult {
    const options = cli.Options{
        .file = "",
        .target = "",
        .emit_tokens = false,
        .emit_ast = false,
        .emit_ir = false,
        .sema = false,
        .run_jit = false,
        .testing = false,
    };
    const c = try allocator.create(compiler.Compiler);
    c.* = compiler.Compiler.init(allocator, std.testing.io, source, options);
    var p = parser.Parser.init(allocator, source, c);
    const ty = try p_type.parse_type(&p);
    return .{ .ty = ty, .c = c };
}

fn parse_expression(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const options = cli.Options{
        .file = "",
        .target = "",
        .emit_tokens = false,
        .emit_ast = false,
        .emit_ir = false,
        .sema = false,
        .run_jit = false,
        .testing = false,
    };

    var c = compiler.Compiler.init(allocator, std.testing.io, source, options);
    var p = parser.Parser.init(allocator, source, &c);
    var expr = try p_expr.parse_expression(&p);
    const buf = try expr.to_string(allocator);
    expr.deinit(allocator);
    try c.deinit();
    return buf;
}

fn parse_stmt(allocator: std.mem.Allocator, source: []const u8) !StmtResult {
    const options = cli.Options{
        .file = "",
        .target = "",
        .emit_tokens = false,
        .emit_ast = false,
        .emit_ir = false,
        .sema = false,
        .run_jit = false,
        .testing = false,
    };

    const c = try allocator.create(compiler.Compiler);
    c.* = compiler.Compiler.init(allocator, std.testing.io, source, options);
    var p = parser.Parser.init(allocator, source, c);
    const stmt = try p_stmt.parse_statement(&p);
    return .{ .stmt = stmt, .c = c };
}

test "primitive type" {
    const res = try parse_type(std.testing.allocator, "i8");
    try std.testing.expect(res.ty.base == .primitive);
    try std.testing.expectEqual(ast.PrimitiveType.i8, res.ty.base.primitive);
    try res.deinit(std.testing.allocator);
}

test "pointer type" {
    const res = try parse_type(std.testing.allocator, "*i32");
    try std.testing.expect(res.ty.base == .pointer);
    try std.testing.expect(res.ty.base.pointer.base == .primitive);
    try std.testing.expectEqual(ast.PrimitiveType.i32, res.ty.base.pointer.base.primitive);
    try res.deinit(std.testing.allocator);
}

test "array type" {
    const res = try parse_type(std.testing.allocator, "[10]i32");
    try std.testing.expect(res.ty.base == .array);
    try std.testing.expect(res.ty.base.array.size == .fixed);
    try std.testing.expectEqualStrings("10", res.ty.base.array.size.fixed);
    try std.testing.expectEqual(ast.PrimitiveType.i32, res.ty.base.array.elem.base.primitive);
    try res.deinit(std.testing.allocator);
}

test "optional and error-union modifiers" {
    const res = try parse_type(std.testing.allocator, "?i32!");
    try std.testing.expect(res.ty.is_optional);
    try std.testing.expect(res.ty.is_error_union);
    try std.testing.expectEqual(ast.PrimitiveType.i32, res.ty.base.primitive);
    try res.deinit(std.testing.allocator);
}

test "named type with no args" {
    const res = try parse_type(std.testing.allocator, "Foo");

    try std.testing.expect(res.ty.base == .named);
    try std.testing.expectEqualStrings("Foo", res.ty.base.named.name);
    try std.testing.expectEqual(@as(usize, 0), res.ty.base.named.args.len);
    try res.deinit(std.testing.allocator);
}

test "func type" {
    const res = try parse_type(std.testing.allocator, "func(i32, i32) -> i32");
    try std.testing.expect(res.ty.base == .func);
    try std.testing.expectEqual(@as(usize, 2), res.ty.base.func.params.items.len);
    try std.testing.expectEqual(ast.PrimitiveType.i32, res.ty.base.func.result.base.primitive);
    try res.deinit(std.testing.allocator);
}

test "proc type" {
    const res = try parse_type(std.testing.allocator, "proc(i32)");
    try std.testing.expect(res.ty.base == .proc);
    try std.testing.expectEqual(@as(usize, 1), res.ty.base.proc.params.items.len);
    try res.deinit(std.testing.allocator);
}

test "named type with args" {
    const res = try parse_type(std.testing.allocator, "Map[str, List[Option[i32]]]");

    try std.testing.expect(res.ty.base == .named);
    try std.testing.expectEqualStrings("Map", res.ty.base.named.name);
    try std.testing.expectEqual(@as(usize, 2), res.ty.base.named.args.len);
    try std.testing.expectEqual(ast.PrimitiveType.str, res.ty.base.named.args[0].base.primitive);

    const ls = res.ty.base.named.args[1];
    try std.testing.expect(ls.base == .named);
    try std.testing.expectEqualStrings("List", ls.base.named.name);
    try std.testing.expectEqual(@as(usize, 1), ls.base.named.args.len);
    try res.deinit(std.testing.allocator);
}

test "expression precedence parsing" {
    const allocator = std.testing.allocator;
    var buf = try parse_expression(std.testing.allocator, "10");
    try std.testing.expectEqualStrings(buf, "10");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 + 10");
    try std.testing.expectEqualStrings(buf, "(10 + 10)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 + 10 * 10");
    try std.testing.expectEqualStrings(buf, "(10 + (10 * 10))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 + 10 * 10 - 10");
    try std.testing.expectEqualStrings(buf, "((10 + (10 * 10)) - 10)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "100 / 10 - 10");
    try std.testing.expectEqualStrings(buf, "((100 / 10) - 10)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "-10");
    try std.testing.expectEqualStrings(buf, "(-10)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 + -10");
    try std.testing.expectEqualStrings(buf, "(10 + (-10))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "--10");
    try std.testing.expectEqualStrings(buf, "(-(-10))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "(((10)))");
    try std.testing.expectEqualStrings(buf, "10");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "(10 + 10) * 10");
    try std.testing.expectEqualStrings(buf, "((10 + 10) * 10)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "(10 + 10) * !10");
    try std.testing.expectEqualStrings(buf, "((10 + 10) * (!10))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 * 10 * *10");
    try std.testing.expectEqualStrings(buf, "((10 * 10) * (*10))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 == 10");
    try std.testing.expectEqualStrings(buf, "(10 == 10)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 * 10 == 100");
    try std.testing.expectEqualStrings(buf, "((10 * 10) == 100)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "(10 + 10 > -10)");
    try std.testing.expectEqualStrings(buf, "((10 + 10) > (-10))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 << 2 + 1");
    try std.testing.expectEqualStrings(buf, "(10 << (2 + 1))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 < 20 == true");
    try std.testing.expectEqualStrings(buf, "((10 < 20) == true)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 & 20 == 0");
    try std.testing.expectEqualStrings(buf, "((10 & 20) == 0)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 ^ 20 & 30");
    try std.testing.expectEqualStrings(buf, "(10 ^ (20 & 30))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 | 20 ^ 30");
    try std.testing.expectEqualStrings(buf, "(10 | (20 ^ 30))");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "true && false || true");
    try std.testing.expectEqualStrings(buf, "((true && false) || true)");
    allocator.free(buf);
    buf = try parse_expression(std.testing.allocator, "10 || 20 && 30");
    try std.testing.expectEqualStrings(buf, "(10 || (20 && 30))");
    allocator.free(buf);
}

test "var statement" {
    var res = try parse_stmt(std.testing.allocator, "var b: i16 = 10;");
    try std.testing.expect(res.stmt == .var_stmt);
    try std.testing.expectEqualStrings("b", res.stmt.var_stmt.name);
    try std.testing.expectEqual(ast.PrimitiveType.i16, res.stmt.var_stmt.type_ann.?.base.primitive);
    try std.testing.expect(res.stmt.var_stmt.value.* == .literal);
    try std.testing.expectEqualStrings("10", res.stmt.var_stmt.value.literal.raw);
    try res.deinit(std.testing.allocator);
}

test "const statement" {
    var res = try parse_stmt(std.testing.allocator, "const b: i16 = 10;");
    try std.testing.expect(res.stmt == .const_stmt);
    try std.testing.expectEqualStrings("b", res.stmt.const_stmt.name);
    try std.testing.expectEqual(ast.PrimitiveType.i16, res.stmt.const_stmt.type_ann.?.base.primitive);
    try std.testing.expect(res.stmt.const_stmt.value.* == .literal);
    try std.testing.expectEqualStrings("10", res.stmt.const_stmt.value.literal.raw);
    try res.deinit(std.testing.allocator);
}

test "local static var statement" {
    var res = try parse_stmt(std.testing.allocator, "static var b: i16 = 10;");
    try std.testing.expect(res.stmt == .local_static_var_stmt);
    try std.testing.expectEqualStrings("b", res.stmt.local_static_var_stmt.name);
    try std.testing.expectEqual(ast.PrimitiveType.i16, res.stmt.local_static_var_stmt.type_ann.?.base.primitive);
    try std.testing.expect(res.stmt.local_static_var_stmt.value.* == .literal);
    try std.testing.expectEqualStrings("10", res.stmt.local_static_var_stmt.value.literal.raw);
    try res.deinit(std.testing.allocator);
}

test "if/elif/else expression" {
    var res = try parse_stmt(std.testing.allocator,
        \\if 2
        \\  var a = 20;
        \\elif 1
        \\  var b = 30;
        \\else
        \\  var c = 42;
        \\end
    );

    try std.testing.expect(res.stmt == .control_flow_stmt);
    const cf = res.stmt.control_flow_stmt;
    try std.testing.expect(cf == .if_expr);
    const if_expr = cf.if_expr;

    try std.testing.expect(if_expr.cond.* == .literal);
    try std.testing.expectEqualStrings("2", if_expr.cond.literal.raw);

    try std.testing.expectEqual(@as(usize, 1), if_expr.then_body.items.len);
    try std.testing.expect(if_expr.then_body.items[0] == .var_stmt);
    try std.testing.expectEqualStrings("a", if_expr.then_body.items[0].var_stmt.name);
    try std.testing.expectEqualStrings("20", if_expr.then_body.items[0].var_stmt.value.literal.raw);

    try std.testing.expectEqual(@as(usize, 1), if_expr.elifs.items.len);
    try std.testing.expectEqualStrings("1", if_expr.elifs.items[0].cond.literal.raw);
    try std.testing.expectEqual(@as(usize, 1), if_expr.elifs.items[0].body.items.len);
    try std.testing.expectEqualStrings("b", if_expr.elifs.items[0].body.items[0].var_stmt.name);

    try std.testing.expect(if_expr.else_body != null);
    try std.testing.expectEqual(@as(usize, 1), if_expr.else_body.?.items.len);
    try std.testing.expectEqualStrings("c", if_expr.else_body.?.items[0].var_stmt.name);
    try res.deinit(std.testing.allocator);
}
