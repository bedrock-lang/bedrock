const std = @import("std");
const token = @import("../token.zig");
const ast = @import("../ast.zig");
const err = @import("../error.zig");
const Parser = @import("parser.zig").Parser;

const items_mod = @import("items.zig");
const types_mod = @import("types.zig");

pub fn parse_type_def(self: *Parser) anyerror!ast.TypeDef {
    var type_def = ast.TypeDef{
        .is_pub = false,
        .is_global = false,
        .variant = undefined,
    };
    // NOTE: no type params for now
    _ = try self.lexer.next(); // 'type'
    // ident
    const name = try self.lexer.next();
    _ = try self.expect(.eq, "expected '='");

    const tok = try self.lexer.peek_token();
    switch (tok.type) {
        .kw_struct => {
            _ = try self.lexer.next();
            const s = try parse_struct(self, name.val);
            type_def.variant = .{ .struct_def = s };
        },
        .kw_enum => {
            _ = try self.lexer.next();
            const e = try parse_enum(self, name.val);
            type_def.variant = .{ .enum_def = e };
        },
        else => {
            const aliased = try types_mod.parse_type(self);
            _ = try self.expect(.semicolon, "expected ';'");
            type_def.variant = .{ .alias = .{ .name = name.val, .ty = aliased, .token = tok } };
        },
    }

    return type_def;
}

pub fn parse_enum(self: *Parser, name: []const u8) anyerror!ast.EnumDef {
    const tok = try self.lexer.peek_token();
    var e = ast.EnumDef{
        .is_pub = false,
        .name = name,
        .type_params = .empty,
        .variants = .empty,
        .token = tok,
    };

    try parse_enum_variants(self, &e);

    _ = try self.expect(.kw_end, "expected 'end'");

    return e;
}

pub fn parse_enum_variants(self: *Parser, e: *ast.EnumDef) anyerror!void {
    var tok = try self.lexer.peek_token();
    while (true) {
        switch (tok.type) {
            .kw_end => break,
            .ident => {
                const f = try parse_enum_variant(self);
                try e.variants.append(self.allocator, f);
                const nxt = try self.lexer.peek_token();
                if (nxt.type == .comma) {
                    _ = try self.lexer.next();
                } else if (nxt.type != .kw_end) {
                    try self.compiler.addError("expected ',' or 'end'", err.Severity.Error, nxt);
                    break;
                }
                tok = try self.lexer.peek_token();
            },
            else => {
                try self.compiler.addError("expected enum variant", err.Severity.Error, tok);
                try self.sync(&.{ .kw_import, .kw_func, .kw_const, .kw_var, .kw_type, .kw_extern, .kw_pub, .kw_proc });
                break;
            },
        }
    }
}

pub fn parse_enum_variant(self: *Parser) anyerror!ast.EnumVariant {
    const tok = try self.lexer.next();
    var variant = ast.EnumVariant{ .name = tok.val, .token = tok };
    const next = try self.lexer.peek_token();
    if (next.type == .l_paren) {
        _ = try self.lexer.next();
        variant.types = try types_mod.parse_type_list(self);
    }
    return variant;
}

pub fn parse_struct(self: *Parser, name: []const u8) anyerror!ast.StructDef {
    const tok = try self.lexer.peek_token();
    var s = ast.StructDef{
        .is_pub = false,
        .name = name,
        .type_params = .empty,
        .fields = .empty,
        .methods = .empty,
        .token = tok,
    };

    try parse_struct_members(self, &s);

    _ = try self.expect(.kw_end, "expected 'end'");

    return s;
}

// so ',' between member is optional only if it's before end
// also methods don't need ',' at all as seperators, as they
// are explictly blocks that ends with 'end'
fn check_struct_member_seperator(self: *Parser) !bool {
    const nxt = try self.lexer.peek_token();
    switch (nxt.type) {
        .comma => {
            _ = try self.lexer.next();
            return true;
        },
        .kw_end => return true,
        else => {
            try self.compiler.addError("expected ',' or 'end'", err.Severity.Error, nxt);
            return false;
        },
    }
}

pub fn parse_struct_members(self: *Parser, s: *ast.StructDef) anyerror!void {
    var tok = try self.lexer.peek_token();
    // parse struct fields and members
    while (true) {
        switch (tok.type) {
            .kw_end => break,
            .kw_func => {
                const f = try items_mod.parse_func_def(self, false, false);
                try s.methods.append(self.allocator, .{ .func = f });
                tok = try self.lexer.peek_token();
            },
            .kw_proc => {
                const f = try items_mod.parse_proc_def(self, false, false);
                try s.methods.append(self.allocator, .{ .proc = f });
                tok = try self.lexer.peek_token();
            },
            .kw_pub => {
                _ = try self.lexer.next();
                const nxt = try self.lexer.peek_token();
                switch (nxt.type) {
                    .ident => {
                        const name_tok = try self.lexer.next();
                        _ = try self.expect(.colon, "expected ':'");
                        const ty = try types_mod.parse_type(self);
                        try s.fields.append(self.allocator, .{
                            .is_pub = true,
                            .name = name_tok.val,
                            .type = ty,
                            .token = nxt,
                        });
                        if (!try check_struct_member_seperator(self)) break;
                        tok = try self.lexer.peek_token();
                    },
                    .kw_func => {
                        const f = try items_mod.parse_func_def(self, true, false);
                        try s.methods.append(self.allocator, .{ .func = f });
                        tok = try self.lexer.peek_token();
                    },
                    .kw_proc => {
                        const p = try items_mod.parse_proc_def(self, true, false);
                        try s.methods.append(self.allocator, .{ .proc = p });
                        tok = try self.lexer.peek_token();
                    },
                    else => {
                        try self.compiler.addError("expected an ident, 'func', or `proc` after `pub`", err.Severity.Error, nxt);
                        try self.sync(&.{ .kw_end, .kw_func, .kw_proc, .kw_pub });
                        tok = try self.lexer.peek_token();
                    },
                }
            },

            .ident => {
                const f = try parse_struct_fields(self);
                try s.fields.append(self.allocator, f);
                if (!try check_struct_member_seperator(self)) break;
                tok = try self.lexer.peek_token();
            },

            else => {
                try self.compiler.addError("expected struct field", err.Severity.Error, tok);
                try self.sync(&.{ .kw_end, .kw_pub });
                tok = try self.lexer.peek_token();
            },
        }
    }
}

pub fn parse_struct_fields(self: *Parser) anyerror!ast.StructField {
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
    _ = try self.expect(.colon, "expected ':'");

    // parse type
    sf.type = try types_mod.parse_type(self);

    return sf;
}
