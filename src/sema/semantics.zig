const std = @import("std");
const ast = @import("../ast.zig");
const compiler = @import("../compiler.zig");
const err = @import("../error.zig");
const scope = @import("scope.zig");
const types = @import("type_system.zig");
const Token = @import("../token.zig").Token;

pub const Sema = struct {
    compiler: *compiler.Compiler,
    scope: *scope.Scope,
    types: types.TypeSystem,
    expr_types: std.AutoHashMapUnmanaged(*ast.Expr, types.TypeId) = .{},
    discard: bool = false, // this is for dicarded values check, like in proc

    pub fn init(c: *compiler.Compiler) Sema {
        return .{
            .compiler = c,
            .scope = undefined,
            .types = types.TypeSystem.init(c.allocator),
            .expr_types = .{},
        };
    }

    pub fn deinit(self: *Sema) void {
        self.types.deinit();
        self.expr_types.deinit(self.compiler.allocator);
    }

    pub fn analyze(self: *Sema) !void {
        // std.debug.print("\n-------\nanalyzing semantics!\n--------\n", .{});
        var root = scope.Scope.init(self.compiler.allocator, .root, null);
        defer root.deinit();
        self.scope = &root;
        const tree = &self.compiler.ast;

        for (tree.program.items.items) |*item| {
            try self.visit_item(item);
        }
    }

    fn enter_scope(self: *Sema, stmts: []ast.Stmt, kind: scope.Scope.Id) !void {
        var block_scope = scope.Scope.init(self.compiler.allocator, kind, self.scope);
        defer block_scope.deinit();

        const saved = self.scope;
        self.scope = &block_scope;
        defer self.scope = saved;

        for (stmts, 0..) |*stmt, idx| {
            if (idx > 0 and self.types.body_returns(stmts[0..idx])) {
                if (stmt.token_of()) |tok| {
                    try self.compiler.add_sem_error("unreachable code", .{}, .Error, tok);
                }
                break;
            }
            try self.visit_statement(stmt);
        }
    }

    fn check_undefined_array_infer(type_ann: ?*ast.Type, value: *ast.Expr) bool {
        if (type_ann) |ty| if (ty.base == .array and ty.base.array.size == .inferred and value.* == .undefined) {
            return true;
        };
        return false;
    }

    fn declare_func(self: *Sema, f: *ast.FunctionDef, name: []const u8) !void {
        var param_tys = std.ArrayList(types.TypeId).empty;
        for (f.params.items) |*param| {
            const pty = try self.types.resolve_type(param.type, self.scope);
            if (pty == .invalid) {
                try self.compiler.add_sem_error("unknown type for parameter '{s}'", .{param.name}, .Error, param.token);
            }
            try param_tys.append(self.compiler.allocator, pty);
        }
        const rty = try self.types.resolve_type(f.result, self.scope);
        if (rty == .invalid) {
            try self.compiler.add_sem_error("unknown return type for function '{s}'", .{name}, .Error, f.result.token);
        }
        const fnty = try self.types.intern(.{ .function = .{ .params = param_tys, .result = rty } });
        self.scope.declare(.{ .name = name, .kind = .func, .ty = fnty }) catch |e| {
            if (e == error.DuplicateName) {
                try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{name}, .Error, f.token);
            }
        };
    }

    fn declare_proc(self: *Sema, p: *ast.ProcDef, name: []const u8) !void {
        var param_tys = std.ArrayList(types.TypeId).empty;
        for (p.params.items) |*param| {
            const pty = try self.types.resolve_type(param.type, self.scope);
            if (pty == .invalid) {
                try self.compiler.add_sem_error("unknown type for parameter '{s}'", .{param.name}, .Error, param.token);
            }
            try param_tys.append(self.compiler.allocator, pty);
        }
        const prty = try self.types.intern(.{ .procedure = .{ .params = param_tys } });
        self.scope.declare(.{ .name = name, .kind = .func, .ty = prty }) catch |e| {
            if (e == error.DuplicateName) {
                try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{name}, .Error, p.token);
            }
        };
    }

    // just turn struct and field to struct.field
    pub fn qualify(self: *Sema, owner: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.types.arena.allocator(), "{s}.{s}", .{ owner, name });
    }

    // checks if method and field name clashes and give errors
    fn check_method(self: *Sema, s: *ast.StructDef, name: []const u8, tok: Token) !void {
        for (s.fields.items) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                try self.compiler.add_sem_error("method '{s}' clashes with the field of the same name", .{name}, .Error, tok);
            }
        }
    }

    // in two passes we first declare the signature
    // of all methods in struct (so methods can call
    // each other in any order) then again we do pass
    // and this time we visit the bodies of methods.
    fn visit_method(self: *Sema, s: *ast.StructDef) !void {
        for (s.methods.items) |*m| switch (m.*) {
            .func => |*f| {
                try self.check_method(s, f.name, f.token);
                try self.declare_func(f, try self.qualify(s.name, f.name));
            },
            .proc => |*p| {
                try self.check_method(s, p.name, p.token);
                try self.declare_proc(p, try self.qualify(s.name, p.name));
            },
        };
        for (s.methods.items) |*m| switch (m.*) {
            .func => |*f| try self.visit_function(f),
            .proc => |*p| try self.visit_proc(p),
        };
    }

    // it gets the struct type of a pointer struct
    // and a normal struct so (self: *P) and (self: P)
    // could be called in same way (p.foo()) and not (&p.foo())
    fn struct_of(self: *Sema, tty: types.TypeId) types.TypeId {
        if (tty == .invalid) return .invalid;
        return switch (self.types.get(tty).*) {
            .struct_ty => tty,
            .pointer => |p| if (p.child != .invalid and self.types.get(p.child).* == .struct_ty) p.child else .invalid,
            else => .invalid,
        };
    }

    fn visit_item(self: *Sema, item: *ast.Item) !void {
        switch (item.*) {
            .import_def => {},
            .function => |*f| {
                try self.declare_func(f, f.name);
                try self.visit_function(f);
            },
            .proc => |*p| {
                try self.declare_proc(p, p.name);
                try self.visit_proc(p);
            },
            .type_def => |*t_def| {
                switch (t_def.variant) {
                    .struct_def => |*s| {
                        var field_tys = std.ArrayList(types.StFieldTy).empty;
                        for (s.fields.items) |*s_f| {
                            const fty = try self.types.resolve_type(s_f.type, self.scope);
                            if (fty == .invalid) {
                                try self.compiler.add_sem_error("unknown type for field '{s}'", .{s_f.name}, .Error, s_f.token);
                            }
                            try field_tys.append(self.compiler.allocator, .{ .name = s_f.name, .ty = fty });
                        }

                        const sty = try self.types.intern(.{ .struct_ty = .{ .name = s.name, .fields = field_tys } });
                        try self.types.register(s.name, sty);
                        self.scope.declare(.{ .name = s.name, .kind = .@"struct", .ty = sty }) catch |e| {
                            if (e == error.DuplicateName) {
                                try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{s.name}, .Error, s.token);
                            }
                        };

                        try self.visit_struct_def(s);
                        try self.visit_method(s);
                    },
                    .enum_def => |*en| {
                        var vartys = std.ArrayList(types.EnumVaraintTy).empty;
                        for (en.variants.items) |*v| {
                            for (vartys.items) |vt| {
                                if (std.mem.eql(u8, vt.name, v.name)) {
                                    try self.compiler.add_sem_error("Duplicate variant name: {s}\n", .{v.name}, .Error, v.token);
                                }
                            }
                            var tys = std.ArrayList(types.TypeId).empty;
                            for (v.types.items) |t| {
                                try tys.append(self.compiler.allocator, try self.types.resolve_type(t, self.scope));
                            }
                            try vartys.append(self.compiler.allocator, .{ .name = v.name, .types = tys });
                        }

                        const ety = try self.types.intern(.{ .enum_ty = .{ .name = en.name, .variants = vartys } });
                        try self.types.register(en.name, ety);
                        self.scope.declare(.{ .name = en.name, .kind = .@"enum", .ty = ety }) catch |e| {
                            if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate declaration: {s}", .{en.name}, .Error, en.token);
                        };
                    },
                    .alias => |*a| {
                        const aty = try self.types.resolve_type(a.ty, self.scope);
                        if (aty == .invalid) {
                            try self.compiler.add_sem_error("cannot resolve aliased type for `{s}`", .{a.name}, .Error, a.token);
                        }
                        try self.types.register(a.name, aty);
                        self.scope.declare(.{ .name = a.name, .kind = .type_alias, .ty = aty }) catch |e| {
                            if (e == error.DuplicateName) {
                                try self.compiler.add_sem_error("Duplicate declaration: {s}", .{a.name}, .Error, a.token);
                            }
                        };
                    },
                }
            },
            .extern_def => |e_def| {
                switch (e_def.kind) {
                    .func => |f| {
                        var param_tys = std.ArrayList(types.TypeId).empty;
                        for (f.params.items) |*param| {
                            const pty = try self.types.resolve_type(param.type, self.scope);
                            if (pty == .invalid) {
                                try self.compiler.add_sem_error("unknown type for parameter '{s}'", .{param.name}, .Error, param.token);
                            }
                            try param_tys.append(self.compiler.allocator, pty);
                        }
                        const rty = try self.types.resolve_type(f.result, self.scope);
                        if (rty == .invalid) {
                            try self.compiler.add_sem_error("unknown return type for extern func '{s}'", .{f.name}, .Error, e_def.token);
                        }
                        const fnty = try self.types.intern(.{ .function = .{ .params = param_tys, .result = rty, .is_variadic = f.is_variadic } });
                        self.scope.declare(.{ .name = f.name, .kind = .func, .ty = fnty }) catch |e| {
                            if (e == error.DuplicateName) {
                                try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{f.name}, .Error, e_def.token);
                            }
                        };
                    },
                    .proc => |p| {
                        var param_tys = std.ArrayList(types.TypeId).empty;
                        for (p.params.items) |*param| {
                            const pty = try self.types.resolve_type(param.type, self.scope);
                            if (pty == .invalid) {
                                try self.compiler.add_sem_error("unknown type for parameter '{s}'", .{param.name}, .Error, param.token);
                            }
                            try param_tys.append(self.compiler.allocator, pty);
                        }
                        const prty = try self.types.intern(.{ .procedure = .{ .params = param_tys, .is_variadic = p.is_variadic } });
                        self.scope.declare(.{ .name = p.name, .kind = .func, .ty = prty }) catch |e| {
                            if (e == error.DuplicateName) {
                                try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{p.name}, .Error, e_def.token);
                            }
                        };
                    },
                }
            },
            .var_def => |*v| {
                const dty: types.TypeId = if (v.type_ann) |ty| blk: {
                    const t = try self.types.resolve_type(ty, self.scope);
                    const inferred = ty.base == .array and ty.base.array.size == .inferred;
                    if (t == .invalid and !inferred) {
                        try self.compiler.add_sem_error("unknown type for variable '{s}'", .{v.name}, .Error, ty.token);
                    }
                    break :blk t;
                } else .invalid;
                const aty = if (check_undefined_array_infer(v.type_ann, v.value)) blk: {
                    try self.compiler.add_sem_error("cannot infer array length: 'undefined' has no length to infer from", .{}, .Error, v.token);
                    break :blk .invalid;
                } else try self.visit_expression(v.value, if (dty != .invalid) dty else null);

                if (dty != .invalid and aty != .invalid and !self.types.assignable(aty, dty)) {
                    try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(dty), self.types.name_of(aty) }, .Error, v.token);
                }
                self.scope.declare(.{ .name = v.name, .kind = .variable, .ty = if (dty != .invalid) dty else aty }) catch |e| {
                    if (e == error.DuplicateName) {
                        try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{v.name}, .Error, v.token);
                    }
                };
            },
            .const_def => |*c| {
                const dty: types.TypeId = if (c.type_ann) |ty| blk: {
                    const t = try self.types.resolve_type(ty, self.scope);
                    const inferred = ty.base == .array and ty.base.array.size == .inferred;
                    if (t == .invalid and !inferred) {
                        try self.compiler.add_sem_error("unknown type for constant '{s}'", .{c.name}, .Error, ty.token);
                    }
                    break :blk t;
                } else .invalid;
                if (c.value.* == .undefined) {
                    try self.compiler.add_sem_error("constant '{s}' cannot be 'undefined'", .{c.name}, .Error, c.token);
                }
                const aty = if (check_undefined_array_infer(c.type_ann, c.value)) blk: {
                    try self.compiler.add_sem_error("cannot infer array length: 'undefined' has no length to infer from", .{}, .Error, c.token);
                    break :blk .invalid;
                } else try self.visit_expression(c.value, if (dty != .invalid) dty else null);
                if (dty != .invalid and aty != .invalid and !self.types.assignable(aty, dty)) {
                    try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(dty), self.types.name_of(aty) }, .Error, c.token);
                }
                self.scope.declare(.{ .name = c.name, .kind = .constant, .ty = if (dty != .invalid) dty else aty, .const_val = types.TypeSystem.const_int(c.value, self.scope) }) catch |e| {
                    if (e == error.DuplicateName) {
                        try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{c.name}, .Error, c.token);
                    }
                };
            },
        }
    }

    fn visit_struct_def(self: *Sema, s: *ast.StructDef) !void {
        var s_scope = scope.Scope.init(self.compiler.allocator, .@"struct", self.scope);
        defer s_scope.deinit();
        const saved = self.scope;
        self.scope = &s_scope;
        defer self.scope = saved;

        for (s.fields.items) |*f| {
            const f_ty = try self.types.resolve_type(f.type, self.scope);
            s_scope.declare(.{ .name = f.name, .kind = .st_field, .ty = f_ty }) catch |e| {
                if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate struct field: {s}\n", .{f.name}, .Error, s.token);
            };
        }
    }

    fn visit_function(self: *Sema, func: *ast.FunctionDef) !void {
        // std.debug.print("visiting function\n", .{});
        const rty = try self.types.resolve_type(func.result, self.scope);

        var func_scope = scope.Scope.init(self.compiler.allocator, .func, self.scope);
        func_scope.fn_info = .{ .func = rty };
        defer func_scope.deinit();
        const saved = self.scope;
        self.scope = &func_scope;
        defer self.scope = saved;

        for (func.params.items) |*param| {
            const param_ty = try self.types.resolve_type(param.type, self.scope);
            const kind: scope.SymbolKind = if (param.is_const) .constant else .variable;
            func_scope.declare(.{ .name = param.name, .kind = kind, .ty = param_ty }) catch |e| {
                if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate parameter: {s}\n", .{param.name}, .Error, param.token);
            };
        }

        try self.enter_scope(func.body.items, .block);

        if (rty != .invalid and !self.types.body_returns(func.body.items)) {
            try self.compiler.add_sem_error("control reaches the end of the function", .{}, .Warn, func.token);
        }
    }

    fn visit_proc(self: *Sema, proc: *ast.ProcDef) !void {
        // std.debug.print("visiting proc\n", .{});
        var proc_scope = scope.Scope.init(self.compiler.allocator, .func, self.scope);
        proc_scope.fn_info = .proc;
        defer proc_scope.deinit();
        const saved = self.scope;
        self.scope = &proc_scope;
        defer self.scope = saved;

        for (proc.params.items) |*param| {
            const param_ty = try self.types.resolve_type(param.type, self.scope);
            const kind: scope.SymbolKind = if (param.is_const) .constant else .variable;
            proc_scope.declare(.{ .name = param.name, .kind = kind, .ty = param_ty }) catch |e| {
                if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate parameter: {s}\n", .{param.name}, .Error, param.token);
            };
        }

        try self.enter_scope(proc.body.items, .block);
    }

    // to find if the expression a place stored inline in an array for now
    // todo: could be expanded to structs, slice, etc.
    fn is_inline_value(self: *Sema, e: *ast.Expr) bool {
        const t = self.expr_types.get(e) orelse return false;
        if (t == .invalid) return false;
        return switch (self.types.get(t).*) {
            .array => true,
            else => false,
        };
    }

    // to find name of const owning this place
    fn const_root(self: *Sema, e: *ast.Expr) ?[]const u8 {
        return switch (e.*) {
            .ident => |i| blk: {
                const sym = self.scope.resolve(i.name) orelse break :blk null;
                break :blk if (sym.kind == .constant) sym.name else null;
            },
            .field_access => |f| if (self.is_inline_value(f.target)) self.const_root(f.target) else null,
            .index => |i| if (self.is_inline_value(i.target)) self.const_root(i.target) else null,
            else => null,
        };
    }

    fn visit_statement(self: *Sema, stmt: *ast.Stmt) anyerror!void {
        // std.debug.print("visiting statement\n", .{});
        switch (stmt.*) {
            .var_stmt => |*v| {
                const dty: types.TypeId = if (v.type_ann) |ty| blk: {
                    const t = try self.types.resolve_type(ty, self.scope);
                    const inferred = ty.base == .array and ty.base.array.size == .inferred;
                    if (t == .invalid and !inferred) {
                        try self.compiler.add_sem_error("unknown type for variable '{s}'", .{v.name}, .Error, ty.token);
                    }
                    break :blk t;
                } else .invalid;
                const aty = if (check_undefined_array_infer(v.type_ann, v.value)) blk: {
                    try self.compiler.add_sem_error("cannot infer array length: 'undefined' has no length to infer from", .{}, .Error, v.token);
                    break :blk .invalid;
                } else try self.visit_expression(v.value, if (dty != .invalid) dty else null);

                if (dty != .invalid and aty != .invalid and !self.types.assignable(aty, dty)) {
                    try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(dty), self.types.name_of(aty) }, .Error, v.token);
                }
                self.scope.declare(.{ .name = v.name, .kind = .variable, .ty = if (dty != .invalid) dty else aty }) catch |e| {
                    if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{v.name}, .Error, v.token);
                };
            },
            .const_stmt => |*c| {
                const dty: types.TypeId = if (c.type_ann) |ty| blk: {
                    const t = try self.types.resolve_type(ty, self.scope);
                    const inferred = ty.base == .array and ty.base.array.size == .inferred;
                    if (t == .invalid and !inferred) {
                        try self.compiler.add_sem_error("unknown type for constant '{s}'", .{c.name}, .Error, ty.token);
                    }
                    break :blk t;
                } else .invalid;
                if (c.value.* == .undefined) {
                    try self.compiler.add_sem_error("constant '{s}' cannot be 'undefined'", .{c.name}, .Error, c.token);
                }
                const aty = if (check_undefined_array_infer(c.type_ann, c.value)) blk: {
                    try self.compiler.add_sem_error("cannot infer array length: 'undefined' has no length to infer from", .{}, .Error, c.token);
                    break :blk .invalid;
                } else try self.visit_expression(c.value, if (dty != .invalid) dty else null);
                if (dty != .invalid and aty != .invalid and !self.types.assignable(aty, dty)) {
                    try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(dty), self.types.name_of(aty) }, .Error, c.token);
                }
                self.scope.declare(.{ .name = c.name, .kind = .constant, .ty = if (dty != .invalid) dty else aty, .const_val = types.TypeSystem.const_int(c.value, self.scope) }) catch |e| {
                    if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{c.name}, .Error, c.token);
                };
            },
            .local_static_var_stmt => |lv| {
                const dty: types.TypeId = if (lv.type_ann) |ty| blk: {
                    const t = try self.types.resolve_type(ty, self.scope);
                    const inferred = ty.base == .array and ty.base.array.size == .inferred;
                    if (t == .invalid and !inferred) {
                        try self.compiler.add_sem_error("unknown type for variable '{s}'", .{lv.name}, .Error, ty.token);
                    }
                    break :blk t;
                } else .invalid;
                const aty = if (check_undefined_array_infer(lv.type_ann, lv.value)) blk: {
                    try self.compiler.add_sem_error("cannot infer array length: 'undefined' has no length to infer from", .{}, .Error, lv.token);
                    break :blk .invalid;
                } else try self.visit_expression(lv.value, if (dty != .invalid) dty else null);
                if (dty != .invalid and aty != .invalid and !self.types.assignable(aty, dty)) {
                    try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(dty), self.types.name_of(aty) }, .Error, lv.token);
                }
                self.scope.declare(.{ .name = lv.name, .kind = .variable, .ty = if (dty != .invalid) dty else aty }) catch |e| {
                    if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate declaration: {s}\n", .{lv.name}, .Error, lv.token);
                };
            },
            .assign_stmt => |*a| {
                const is_discard = a.target.* == .ident and std.mem.eql(u8, a.target.ident.name, "_");
                if (is_discard) {
                    _ = try self.visit_expression(a.value, null);
                } else {
                    const tty = try self.visit_expression(a.target, null);
                    if (self.const_root(a.target)) |name| {
                        try self.compiler.add_sem_error("cannot assign to constant '{s}'", .{name}, .Error, a.token);
                    }
                    const vty = try self.visit_expression(a.value, if (tty != .invalid) tty else null);
                    if (tty != .invalid and vty != .invalid and !self.types.assignable(vty, tty)) {
                        try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(tty), self.types.name_of(vty) }, .Error, a.target.token_of());
                    }
                }
            },
            .defer_stmt => |*d| {
                try self.enter_scope(d.statement_list.items, .block);
            },
            .unsafe_stmt => |*u| {
                try self.enter_scope(u.body.items, .unsafe);
            },
            .control_flow_stmt => |*c| try self.visit_control_flow(c),
            .return_stmt => |*r| {
                const fn_scope = self.scope.enclosing(.func);
                // note: should we handle nil explicitly ??
                if (fn_scope == null) {
                    try self.compiler.add_sem_error("return used outside of function\n", .{}, .Error, r.token);
                    _ = if (r.value) |val| try self.visit_expression(val, null);
                } else if (fn_scope.?.fn_info) |i| switch (i) {
                    .func => |rty| {
                        if (r.value) |val| {
                            const vty = try self.visit_expression(val, if (rty != .invalid) rty else null);
                            if (rty != .invalid and !self.types.assignable(vty, rty)) {
                                try self.compiler.add_sem_error("type mismatch expected {s}, found {s}", .{ self.types.name_of(rty), self.types.name_of(vty) }, .Error, r.token);
                            }
                        } else {
                            try self.compiler.add_sem_error("return should return a value of type {s}", .{self.types.name_of(rty)}, .Error, r.token);
                        }
                    },
                    .proc => {
                        if (r.value) |val| {
                            _ = try self.visit_expression(val, null);
                            try self.compiler.add_sem_error("proc cannot return a value", .{}, .Error, r.token);
                        }
                    },
                };
            },
            .expr_stmt => |*e| {
                if (e.value) |val| {
                    const tmp = self.discard;
                    self.discard = true;
                    defer self.discard = tmp;

                    const ty = try self.visit_expression(val, null);
                    // info: I could check here func/proc as func have
                    // to always return a value and proc could never
                    // but .invalid already does that shit if u think of it
                    const is_wrong = ty != .invalid and val.* == .call;
                    if (is_wrong) try self.compiler.add_sem_error("unused return value: use '_ = ...' to discard", .{}, .Error, val.call.token);
                }
            },
            .break_stmt => |*b| {
                if (self.scope.enclosing(.loop) == null) {
                    try self.compiler.add_sem_error("break used outside of loop\n", .{}, .Error, b.token);
                }
            },
            .continue_stmt => |*c| {
                if (self.scope.enclosing(.loop) == null) {
                    try self.compiler.add_sem_error("continue used outside of loop\n", .{}, .Error, c.token);
                }
            },
            else => {},
        }
    }

    fn visit_control_flow(self: *Sema, stmt: *ast.ControlFlowStmt) !void {
        // std.debug.print("visiting control flow\n", .{});
        switch (stmt.*) {
            .if_expr => |*i| {
                _ = try self.visit_expression(i.cond, null);
                try self.enter_scope(i.then_body.items, .block);
                for (i.elifs.items) |*e| {
                    _ = try self.visit_expression(e.cond, null);
                    try self.enter_scope(e.body.items, .block);
                }
                if (i.else_body) |*body| {
                    try self.enter_scope(body.items, .block);
                }
            },
            .match_expr => |*m| {
                _ = try self.visit_expression(m.subject, null);

                for (m.arms.items) |*arm| {
                    try self.enter_scope(arm.body.items, .block);
                }

                if (m.else_body) |*body| {
                    try self.enter_scope(body.items, .block);
                }
            },
            .while_expr => |*w| {
                _ = try self.visit_expression(w.cond, null);
                try self.enter_scope(w.body.items, .loop);
            },
            .for_expr => |*f| {
                const ity = try self.visit_expression(f.iterable, null);
                const elemty: types.TypeId = if (ity == .invalid) .invalid else switch (self.types.get(ity).*) {
                    .range => |r| r.elem,
                    .array => |a| a.child,
                    .slice => |s| s.child,
                    else => blk: {
                        try self.compiler.add_sem_error("cannot iterate over type {s}", .{self.types.name_of(ity)}, .Error, f.token);
                        break :blk .invalid;
                    },
                };

                var loop_scope = scope.Scope.init(self.compiler.allocator, .loop, self.scope);
                defer loop_scope.deinit();
                if (f.index_binding) |ib| {
                    const ty = try self.types.primitive(.usize);
                    const sty = try self.visit_expression(f.index_start.?, ty); // expeting the type of idx to be usize always
                    if (sty != .invalid and !self.types.assignable(sty, ty)) {
                        try self.compiler.add_sem_error("enumerate start must be usize, found {s}", .{self.types.name_of(sty)}, .Error, f.index_start.?.token_of());
                    }
                    loop_scope.declare(.{ .name = ib, .kind = .variable, .ty = ty }) catch |e| {
                        if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate declaration: {s}", .{ib}, .Error, f.token);
                    };
                }

                loop_scope.declare(.{ .name = f.binding, .kind = .variable, .ty = elemty }) catch |e| {
                    if (e == error.DuplicateName) try self.compiler.add_sem_error("Duplicate declaration: {s}", .{f.binding}, .Error, f.token);
                };

                const tmp = self.scope;
                self.scope = &loop_scope;
                defer self.scope = tmp;

                for (f.body.items) |*s| try self.visit_statement(s);
            },
        }
    }

    // check if expression is lvalue or not
    fn is_lvalue(e: *ast.Expr) bool {
        return switch (e.*) {
            .ident, .field_access, .index => true,
            .unary => |u| u.op == .deref,
            else => false,
        };
    }

    // method is dot callable only if it's first param is the struct (owner)
    fn takes_reciever(self: *Sema, fnty: types.TypeId, owner: types.TypeId) bool {
        const params = switch (self.types.get(fnty).*) {
            .function => |f| f.params.items,
            .procedure => |p| p.params.items,
            else => return false,
        };
        if (params.len == 0 or params[0] == .invalid) return false;
        const p0 = params[0];
        return p0 == owner or (self.types.get(p0).* == .pointer and self.types.get(p0).pointer.child == owner);
    }

    // auto & and auto * so reciever mathces the method's first param
    fn reciever_arg(self: *Sema, target: *ast.Expr, tty: types.TypeId, fnty: types.TypeId) !*ast.Expr {
        const first = switch (self.types.get(fnty).*) {
            .function => |f| f.params.items[0],
            .procedure => |p| p.params.items[0],
            else => unreachable,
        };
        const wantsptr = self.types.get(first).* == .pointer;
        const isptr = self.types.get(tty).* == .pointer;
        if (wantsptr == isptr) return target;

        const e = try self.compiler.allocator.create(ast.Expr);
        e.* = .{ .unary = .{ .op = if (wantsptr) .addr_of else .deref, .operand = target, .token = target.token_of() } };
        return e;
    }

    // rewrite P.foo(a) into plain call to symbol "P.foo", so
    // normal call checking does the method work too for us!
    fn lower_method_call(self: *Sema, c: *ast.CallExpr) anyerror!bool {
        const fa = c.callee.field_access;
        const mname = switch (fa.field.*) {
            .ident => |i| i.name,
            else => return false,
        };

        var owner: types.TypeId = .invalid;
        var tty: types.TypeId = .invalid;
        const via_type = fa.target.* == .ident and blk: {
            const sym = self.scope.resolve(fa.target.ident.name) orelse break :blk false;
            if (sym.kind != .@"struct") break :blk false;
            owner = sym.ty;
            break :blk true;
        };
        if (!via_type) {
            tty = try self.visit_expression(fa.target, null);
            if (tty == .invalid) return true;
            owner = self.struct_of(tty);
            if (owner == .invalid) return false;
        }

        const qname = try self.qualify(self.types.get(owner).struct_ty.name, mname);
        const sym = self.scope.resolve(qname) orelse {
            if (!via_type) return false;
            try self.compiler.add_sem_error("struct '{s}' has no method '{s}'", .{ self.types.name_of(owner), mname }, .Error, fa.token);
            return true;
        };

        if (!via_type) {
            if (!self.takes_reciever(sym.ty, owner)) {
                try self.compiler.add_sem_error("'{s}' is a static method; call it as {s}.{s}(...)", .{ mname, self.types.name_of(owner), mname }, .Error, fa.token);
                return true;
            }
            const recv = try self.reciever_arg(fa.target, tty, sym.ty);
            try c.args.insert(self.compiler.allocator, 0, .{ .value = recv });
        }

        fa.field.deinit(self.compiler.allocator);
        if (via_type) fa.target.deinit(self.compiler.allocator);

        c.callee.* = .{ .ident = .{ .name = qname, .token = fa.token } };
        return false;
    }

    fn visit_expression(self: *Sema, expr: *ast.Expr, expected: ?types.TypeId) !types.TypeId {
        // std.debug.print("visiting expression\n", .{});
        const ty = switch (expr.*) {
            .literal => |*lit| blk: {
                if (expected) |exp| {
                    if (self.types.literal_fits(lit.kind, exp)) break :blk exp;
                }
                break :blk try self.types.literal_type(lit.kind);
            },
            .ident => |i| blk: {
                const sym = self.scope.resolve(i.name) orelse {
                    try self.compiler.add_sem_error("Unknown identifier '{s}'", .{i.name}, .Error, i.token);
                    break :blk .invalid;
                };
                break :blk sym.ty;
            },
            .binary => |*b| blk: {
                if (b.op == .range or b.op == .range_incl) {
                    const lty = try self.visit_expression(b.lhs, expected);
                    const rty = try self.visit_expression(b.rhs, expected orelse if (lty != .invalid) lty else null);
                    const elemty = self.types.unify(lty, rty) orelse {
                        try self.compiler.add_sem_error("range bounds must have the same type: {s} and {s}", .{ self.types.name_of(lty), self.types.name_of(rty) }, .Error, b.token);
                        break :blk .invalid;
                    };
                    break :blk if (elemty == .invalid) .invalid else try self.types.intern(.{ .range = .{ .elem = elemty } });
                }
                if (b.op == .orelse_op) {
                    break :blk .invalid; //todo: oresle unwrap
                }
                const is_logical = switch (b.op) {
                    .logical_and, .logical_or => true,
                    else => false,
                };
                const is_comparison = switch (b.op) {
                    .eq, .ne, .lt, .gt, .le, .ge => true,
                    else => false,
                };

                // implicit type conversion (numeric widening) is allowed for now
                // those who need explicit type conversion give error here
                if (is_logical) {
                    const boolty = try self.types.primitive(.bool);
                    const lty = try self.visit_expression(b.lhs, boolty);
                    const rty = try self.visit_expression(b.rhs, boolty);
                    if (lty != .invalid and !self.types.assignable(lty, boolty)) {
                        try self.compiler.add_sem_error("expected bool, found {s}", .{self.types.name_of(lty)}, .Error, b.lhs.token_of());
                    }
                    if (lty != .invalid and !self.types.assignable(rty, boolty)) {
                        try self.compiler.add_sem_error("expected bool, found {s}", .{self.types.name_of(rty)}, .Error, b.rhs.token_of());
                    }
                    break :blk boolty;
                }

                var lty: types.TypeId = undefined;
                var rty: types.TypeId = undefined;
                if (expected == null and b.lhs.* == .literal and b.rhs.* != .literal) {
                    rty = try self.visit_expression(b.rhs, null);
                    lty = try self.visit_expression(b.lhs, if (rty != .invalid) rty else null);
                } else {
                    lty = try self.visit_expression(b.lhs, expected);
                    rty = try self.visit_expression(b.rhs, expected orelse if (lty != .invalid) lty else null);
                }

                const result_ty = self.types.unify(lty, rty) orelse {
                    try self.compiler.add_sem_error("type mismatch in binary expression {s} and {s}", .{ self.types.name_of(lty), self.types.name_of(rty) }, .Error, b.token);
                    break :blk .invalid;
                };

                break :blk if (is_comparison) try self.types.primitive(.bool) else result_ty;
            },
            .unary => |*u| blk: {
                switch (u.op) {
                    .neg => {
                        const ty = try self.visit_expression(u.operand, expected);
                        if (ty == .invalid) break :blk .invalid;

                        const is_unsigned = switch (self.types.get(ty).*) {
                            .primitive => |p| switch (p) {
                                .u8, .u16, .u32, .u64, .usize => true,
                                else => false,
                            },
                            else => false,
                        };

                        if (is_unsigned) {
                            try self.compiler.add_sem_error("cannot negate value of unsiged type {s}", .{self.types.name_of(ty)}, .Error, u.token);
                            break :blk .invalid;
                        }

                        if (!self.types.literal_fits(.integer, ty)) {
                            try self.compiler.add_sem_error("cannot negate non-numeric type {s}", .{self.types.name_of(ty)}, .Error, u.token);
                        }
                        break :blk ty;
                    },
                    .not => {
                        const ty = try self.visit_expression(u.operand, try self.types.primitive(.bool));
                        if (ty != .invalid and !self.types.assignable(ty, try self.types.primitive(.bool))) {
                            try self.compiler.add_sem_error("expected a bool, but found {s}", .{self.types.name_of(ty)}, .Error, u.token);
                        }
                        break :blk try self.types.primitive(.bool);
                    },
                    .bit_not => {
                        const ty = try self.visit_expression(u.operand, expected);
                        if (ty != .invalid) {
                            const is_int = switch (self.types.get(ty).*) {
                                .primitive => |p| switch (p) {
                                    .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize, .isize => true,
                                    else => false,
                                },
                                else => false,
                            };
                            if (!is_int) {
                                try self.compiler.add_sem_error("cannot bitwise-not non-integer type {s}", .{self.types.name_of(ty)}, .Error, u.token);
                            }
                        }
                        break :blk ty;
                    },
                    .addr_of => {
                        if (!is_lvalue(u.operand)) {
                            try self.compiler.add_sem_error("cannot take address of a non-lvalue expression", .{}, .Error, u.token);
                            break :blk .invalid;
                        }
                        const innerty = try self.visit_expression(u.operand, null);
                        if (!self.expr_types.contains(expr)) {
                            if (self.const_root(u.operand)) |name| {
                                try self.compiler.add_sem_error("cannot take the address of constant '{s}'", .{name}, .Error, u.token);
                            }
                        }
                        break :blk if (innerty == .invalid) .invalid else try self.types.intern(.{ .pointer = .{ .child = innerty } });
                    },
                    .deref => {
                        const ty = try self.visit_expression(u.operand, null);
                        if (ty == .invalid) break :blk .invalid;
                        break :blk switch (self.types.get(ty).*) {
                            .pointer => |p| p.child,
                            else => blk2: {
                                try self.compiler.add_sem_error("cannot dereference non pointer type {s}", .{self.types.name_of(ty)}, .Error, u.token);
                                break :blk2 .invalid;
                            },
                        };
                    },
                    .new => {
                        const ty = try self.visit_expression(u.operand, null);
                        if (ty == .invalid) break :blk .invalid;
                        break :blk try self.types.intern(.{
                            .pointer = .{
                                .child = ty,
                            },
                        });
                    },
                }
                return .invalid;
            },
            .field_access => |*fa| blk: {
                const tty = try self.visit_expression(fa.target, null);
                if (tty == .invalid) break :blk .invalid;

                const stty = self.struct_of(tty);

                switch (fa.field.*) {
                    .ident => |id| {
                        if (stty == .invalid) {
                            try self.compiler.add_sem_error("cannot access field '{s}' on non-struct type '{s}'", .{ id.name, self.types.name_of(tty) }, .Error, fa.token);
                            break :blk .invalid;
                        }

                        const sdef = self.types.get(stty).struct_ty;
                        for (sdef.fields.items) |sf| {
                            if (std.mem.eql(u8, sf.name, id.name)) break :blk sf.ty;
                        }
                        try self.compiler.add_sem_error("struct '{s}' has no field '{s}'", .{ sdef.name, id.name }, .Error, fa.token);
                        break :blk .invalid;
                    },
                    else => {
                        break :blk .invalid;
                    },
                }
            },
            .call => |*c| blk: {
                const tmp = self.discard;
                self.discard = false;

                if (c.callee.* == .field_access and try self.lower_method_call(c)) break :blk .invalid;
                const cty = try self.visit_expression(c.callee, null);
                for (c.args.items) |arg| {
                    _ = try self.visit_expression(arg.value, null);
                }
                if (cty == .invalid) break :blk .invalid;

                break :blk switch (self.types.get(cty).*) {
                    .function => |fnty| result: {
                        if (fnty.is_variadic) {
                            if (c.args.items.len < fnty.params.items.len) {
                                try self.compiler.add_sem_error("expected atleast {d} arguments, found {d}", .{ fnty.params.items.len, c.args.items.len }, .Error, c.token);
                            }
                        } else if (c.args.items.len != fnty.params.items.len) {
                            try self.compiler.add_sem_error("expected {d} arguments, found {d}", .{ fnty.params.items.len, c.args.items.len }, .Error, c.token);
                            break :result fnty.result;
                        } else {
                            for (c.args.items, fnty.params.items) |arg, pty| {
                                const argty = try self.visit_expression(arg.value, pty);
                                if (argty != .invalid and !self.types.assignable(argty, pty)) {
                                    try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(pty), self.types.name_of(argty) }, .Error, c.token);
                                }
                            }
                        }
                        break :result fnty.result;
                    },
                    .procedure => |prty| result: {
                        if (prty.is_variadic) {
                            if (c.args.items.len < prty.params.items.len) {
                                try self.compiler.add_sem_error("expected atleast {d} arguments, found {d}", .{ prty.params.items.len, c.args.items.len }, .Error, c.token);
                            }
                        } else if (c.args.items.len != prty.params.items.len) {
                            try self.compiler.add_sem_error("expected {d} arguments, found {d}", .{ prty.params.items.len, c.args.items.len }, .Error, c.token);
                        } else {
                            for (c.args.items, prty.params.items) |arg, pty| {
                                const argty = try self.visit_expression(arg.value, pty);
                                if (argty != .invalid and !self.types.assignable(argty, pty)) {
                                    try self.compiler.add_sem_error("type mismatch: expected {s}, found {s}", .{ self.types.name_of(pty), self.types.name_of(argty) }, .Error, c.token);
                                }
                            }
                        }
                        if (!tmp) try self.compiler.add_sem_error("the call is of a proc, and there's no return value to store", .{}, .Error, c.token);
                        break :result .invalid;
                    },
                    else => result: {
                        try self.compiler.add_sem_error("cannot call non-function type {s}", .{self.types.name_of(cty)}, .Error, c.token);
                        break :result .invalid;
                    },
                };
            },
            .index => |*i| blk: {
                const tty = try self.visit_expression(i.target, null);
                for (i.args.items) |arg| _ = try self.visit_expression(arg, null);

                if (i.args.items.len != 1) break :blk .invalid; //todo: generics

                if (tty == .invalid) break :blk .invalid;

                break :blk switch (self.types.get(tty).*) {
                    .array => |a| blk2: {
                        // note: bound check is only for constants (which are known during comptime)
                        const idx = i.args.items[0];
                        const is_neg = idx.* == .unary and idx.unary.op == .neg;
                        const lit: ?*ast.LiteralExpr = if (idx.* == .literal)
                            &idx.literal
                        else if (is_neg and idx.unary.operand.* == .literal)
                            &idx.unary.operand.literal
                        else
                            null;

                        if (lit) |l| {
                            if (l.kind == .integer) {
                                const n = l.ivalue;
                                if (is_neg) {
                                    try self.compiler.add_sem_error("index -{d} out of bounds of array of length {d}", .{ n, a.len }, .Error, idx.token_of());
                                } else if (n >= a.len) {
                                    try self.compiler.add_sem_error("index {d} out of bounds of array of length {d}", .{ n, a.len }, .Error, idx.token_of());
                                }
                            }
                        }
                        break :blk2 a.child;
                    },
                    .slice => |s| s.child,
                    else => res: {
                        try self.compiler.add_sem_error("cannot index type {s}", .{self.types.name_of(tty)}, .Error, i.token);
                        break :res .invalid;
                    },
                };
            },
            .optional_unwrap => |*o| {
                _ = try self.visit_expression(o.operand, null);
                return .invalid; //todo: optianal type
            },
            .array_literal => |*al| blk: {
                // note: if [1,2,3] becomes i32, and if we have [1,2,3,4.5] it gives error, so if
                // want floats array have to do explicitly 'const a = [1.0, 2.0, 3.0]'
                const hint: ?types.TypeId = if (expected) |exp| switch (self.types.get(exp).*) {
                    .array => |*a| a.child,
                    .slice => |s| s.child,
                    else => null,
                } else null;

                if (al.elements.items.len == 0) {
                    if (hint) |h| break :blk try self.types.intern(.{ .array = .{ .child = h, .len = 0 } });
                    try self.compiler.add_sem_error("cannot infer type or size of empty array literal", .{}, .Error, al.token);
                    break :blk .invalid;
                }

                var elemty: types.TypeId = hint orelse .invalid;

                for (al.elements.items) |elem| {
                    const want: ?types.TypeId = hint orelse (if (elemty != .invalid) elemty else null);
                    const ety = try self.visit_expression(elem, want);
                    if (ety == .invalid) continue;
                    if (hint == null) {
                        elemty = self.types.unify(elemty, ety) orelse {
                            try self.compiler.add_sem_error(
                                "array elements must have the same type: expected {s}, found {s}",
                                .{ self.types.name_of(elemty), self.types.name_of(ety) },
                                .Error,
                                al.token,
                            );
                            break :blk .invalid;
                        };
                        continue;
                    }
                    if (!self.types.assignable(ety, elemty)) {
                        try self.compiler.add_sem_error(
                            "array elements must have the same type: expected {s}, found {s}",
                            .{ self.types.name_of(elemty), self.types.name_of(ety) },
                            .Error,
                            al.token,
                        );
                    }
                }

                if (elemty == .invalid) break :blk .invalid;

                break :blk try self.types.intern(.{ .array = .{ .child = elemty, .len = @intCast(al.elements.items.len) } });
            },
            .comptime_expr => |*ce| {
                try self.enter_scope(ce.body.items, .block);
                return .invalid; //todo: comptime type
            },
            .nil => |*n| blk: {
                const fits = if (expected) |exp| switch (self.types.get(exp).*) {
                    .optional => true,
                    .error_union => |inner| self.types.get(inner).* == .optional,
                    else => false,
                } else false;

                if (fits) break :blk expected.?;

                try self.compiler.add_sem_error("cannot infer type of nil without context", .{}, .Error, n.token);
                break :blk .invalid;
            },
            .undefined => blk: {
                if (expected) |e| break :blk e;
                try self.compiler.add_sem_error("cannot infer type of 'undefined' without context", .{}, .Error, expr.token_of());
                break :blk .invalid;
            },
            .struct_literal => |*sl| blk: {
                var stty: types.TypeId = .invalid;
                if (std.mem.eql(u8, sl.name, "_")) {
                    if (expected) |exp| {
                        if (self.types.get(exp).* == .struct_ty) stty = exp;
                    }
                    if (stty == .invalid) {
                        try self.compiler.add_sem_error("cannot infer struct type: no target type available", .{}, .Error, sl.token);
                        break :blk .invalid;
                    }
                } else {
                    const sym = self.scope.resolve(sl.name) orelse {
                        try self.compiler.add_sem_error("unknown type '{s}'", .{sl.name}, .Error, sl.token);
                        break :blk .invalid;
                    };
                    if (sym.kind != .@"struct") {
                        try self.compiler.add_sem_error("'{s}' is not a struct type", .{sl.name}, .Error, sl.token);
                        break :blk .invalid;
                    }
                    stty = sym.ty;
                }

                const sdef = self.types.get(stty).struct_ty;
                var seen = std.StringHashMap(bool).init(self.compiler.allocator);
                defer seen.deinit();

                for (sl.field_inits.items) |*fi| {
                    var flty: ?types.TypeId = null;
                    for (sdef.fields.items) |f| {
                        if (std.mem.eql(u8, f.name, fi.name)) {
                            flty = f.ty;
                            break;
                        }
                    }
                    if (flty == null) {
                        try self.compiler.add_sem_error("struct '{s}' has no field '{s}'", .{ sdef.name, fi.name }, .Error, fi.token);
                        _ = try self.visit_expression(fi.value, null);
                        continue;
                    }
                    if (seen.contains(fi.name)) {
                        try self.compiler.add_sem_error("field '{s}' is initialized more than one time", .{fi.name}, .Error, fi.token);
                    }
                    try seen.put(fi.name, true);
                    const vty = try self.visit_expression(fi.value, flty);
                    if (vty != .invalid and !self.types.assignable(vty, flty.?)) {
                        try self.compiler.add_sem_error("type mismatch for field '{s}': expected {s}, found {s}", .{ fi.name, self.types.name_of(flty.?), self.types.name_of(vty) }, .Error, fi.token);
                    }
                }
                for (sdef.fields.items) |f| {
                    if (!seen.contains(f.name)) {
                        try self.compiler.add_sem_error("uninitialized field '{s}' in struct literal for '{s}'", .{ f.name, sdef.name }, .Error, sl.token);
                    }
                }
                break :blk stty;
            },
        };
        try self.expr_types.put(self.compiler.allocator, expr, ty);
        return ty;
    }

    // note: so the structure is that we visit these different definitions and all the things
    // like basically make visitors and check for our decided semantics...
    // so progressively we keep developing the semantics here.
};
