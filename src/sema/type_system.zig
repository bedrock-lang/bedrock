const std = @import("std");
const ast = @import("../ast.zig");
const scope_mod = @import("scope.zig");

pub const TypeId = enum(u32) {
    invalid = 0,
    _,
};

pub const Primitive = enum {
    // zig fmt: off
    bool, char, str,
    i8, i16, i32, i64,
    u8, u16, u32, u64,
    f32, f64,
    usize, isize,
    ptr,
    // zig fmt: on
};

pub const StFieldTy = struct { name: []const u8, ty: TypeId }; // struct field ka type

pub const Type = union(enum) {
    primitive: Primitive,
    pointer: struct { child: TypeId },
    array: struct { child: TypeId, len: u64 },
    slice: struct { child: TypeId },
    optional: TypeId,
    error_union: TypeId,
    function: struct { params: std.ArrayList(TypeId), result: TypeId, is_variadic: bool = false },
    procedure: struct { params: std.ArrayList(TypeId), is_variadic: bool = false },
    range: struct { elem: TypeId },
    struct_ty: struct { name: []const u8, fields: std.ArrayList(StFieldTy) },
};

pub const TypeSystem = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Type),
    arena: std.heap.ArenaAllocator,
    pids: [@typeInfo(Primitive).@"enum".fields.len]TypeId, // primtive ids
    struct_reg: std.StringArrayHashMapUnmanaged(TypeId) = .empty, // struct registry for storing all defined struct (for codegen)

    pub fn init(allocator: std.mem.Allocator) TypeSystem {
        return .{
            .allocator = allocator,
            .types = .empty,
            .pids = [_]TypeId{.invalid} ** @typeInfo(Primitive).@"enum".fields.len,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *TypeSystem) void {
        for (self.types.items) |*ty| {
            switch (ty.*) {
                .function => |*f| f.params.deinit(self.allocator),
                .procedure => |*p| p.params.deinit(self.allocator),
                .struct_ty => |*s| s.fields.deinit(self.allocator),
                else => {},
            }
        }
        self.types.deinit(self.allocator);
        self.arena.deinit();
        self.struct_reg.deinit(self.allocator);
    }

    pub fn get(self: *TypeSystem, id: TypeId) *Type {
        std.debug.assert(id != .invalid);
        return &self.types.items[@intFromEnum(id) - 1];
    }

    pub fn add(self: *TypeSystem, ty: Type) !TypeId {
        try self.types.append(self.allocator, ty);
        return @enumFromInt(self.types.items.len);
    }

    pub fn primitive(self: *TypeSystem, p: Primitive) !TypeId {
        const idx = @intFromEnum(p);
        if (self.pids[idx] != .invalid) {
            return self.pids[idx];
        }
        const id = try self.add(.{ .primitive = p });
        self.pids[idx] = id;
        return id;
    }

    //todo: implment other types

    // this does same work as visit type but now returns the typeid too,
    // as it will become complete then there will be no need for visit_type, then
    // just resolve_type will be used everywhere then we can remove visit_type
    pub fn resolve_type(self: *TypeSystem, ty: *ast.Type, scope: *scope_mod.Scope) !TypeId {
        var id: TypeId = switch (ty.base) {
            .primitive => |p| try self.from_ast_primitive(p),
            .pointer => |inner| blk: {
                const cid = try self.resolve_type(inner, scope);
                break :blk try self.intern(.{ .pointer = .{ .child = cid } });
            },
            .slice => |*s| blk: {
                const cid = try self.resolve_type(s.elem, scope);
                break :blk try self.intern(.{ .slice = .{ .child = cid } });
            },
            .array => |*a| blk: {
                const cid = try self.resolve_type(a.elem, scope);
                break :blk switch (a.size) {
                    .fixed => |d| self.intern(.{ .array = .{ .child = cid, .len = std.fmt.parseInt(u64, d, 10) catch return .invalid } }) catch return .invalid,
                    .inferred => .invalid,
                };
            },
            .func => |*f| blk: {
                var params: std.ArrayList(TypeId) = .empty;
                for (f.params.items) |p| try params.append(self.allocator, try self.resolve_type(p, scope));
                const rid = try self.resolve_type(f.result, scope);
                break :blk try self.intern(.{ .function = .{ .params = params, .result = rid } });
            },
            .proc => |*pr| blk: {
                var params: std.ArrayList(TypeId) = .empty;
                for (pr.params.items) |p| try params.append(self.allocator, try self.resolve_type(p, scope));
                break :blk try self.intern(.{ .procedure = .{ .params = params } });
            },
            .named => |n| blk: {
                const sym = scope.resolve(n.name) orelse break :blk .invalid;
                break :blk if (sym.kind == .@"struct") sym.ty else .invalid;
            },
        };

        if (ty.is_optional) id = try self.intern(.{ .optional = id });
        if (ty.is_error_union) id = try self.intern(.{ .error_union = id });
        return id;
    }

    fn is_type_eql(a: Type, b: Type) bool {
        if (@as(std.meta.Tag(Type), a) != @as(std.meta.Tag(Type), b)) return false;
        return switch (a) {
            .primitive => a.primitive == b.primitive,
            .pointer => a.pointer.child == b.pointer.child,
            .array => a.array.child == b.array.child,
            .slice => a.slice.child == b.slice.child,
            .optional => a.optional == b.optional,
            .error_union => a.error_union == b.error_union,
            .function => (a.function.result == b.function.result) and
                (a.function.is_variadic == b.function.is_variadic) and
                std.mem.eql(TypeId, a.function.params.items, b.function.params.items),
            .procedure => (a.procedure.is_variadic == b.procedure.is_variadic) and
                std.mem.eql(TypeId, a.procedure.params.items, b.procedure.params.items),
            .range => a.range.elem == b.range.elem,
            .struct_ty => std.mem.eql(u8, a.struct_ty.name, b.struct_ty.name),
        };
    }

    // function for helping in adding type to
    // our types if it does not exisit already
    // for use in resolve_type
    pub fn intern(self: *TypeSystem, ty: Type) !TypeId {
        for (self.types.items, 0..) |e, i| {
            if (is_type_eql(e, ty)) {
                return @enumFromInt(i + 1);
            }
        }
        return self.add(ty);
    }

    // for mapping ast primitive to sema primitive
    pub fn from_ast_primitive(self: *TypeSystem, p: ast.PrimitiveType) !TypeId {
        const mapped = std.meta.stringToEnum(Primitive, @tagName(p)) orelse unreachable;
        return self.primitive(mapped);
    }

    pub fn body_returns(self: TypeSystem, stms: []ast.Stmt) bool {
        if (stms.len == 0) return false;
        return switch (stms[stms.len - 1]) {
            .return_stmt => true,
            .control_flow_stmt => |cf| switch (cf) {
                .if_expr => |i| blk: {
                    const eb = i.else_body orelse break :blk false;
                    if (!self.body_returns(i.then_body.items)) break :blk false;
                    for (i.elifs.items) |e| if (!self.body_returns(e.body.items)) break :blk false;
                    break :blk self.body_returns(eb.items);
                },
                .match_expr => |m| blk: {
                    const eb = m.else_body orelse break :blk false;
                    for (m.arms.items) |arm| if (!self.body_returns(arm.body.items)) break :blk false;
                    break :blk self.body_returns(eb.items);
                },
                else => false,
            },
            else => false,
        };
    }

    const NumKind = enum { signed, unsigned, float };
    const NumRank = struct { kind: NumKind, bits: u8 };

    // the numrank is rank of types in our bedrock
    // according to their signededness and no. of bits
    fn numeric_rank(p: Primitive) ?NumRank {
        return switch (p) {
            .i8 => .{ .kind = .signed, .bits = 8 },
            .i16 => .{ .kind = .signed, .bits = 16 },
            .i32 => .{ .kind = .signed, .bits = 32 },
            .i64, .isize => .{ .kind = .signed, .bits = 64 },
            .u8 => .{ .kind = .unsigned, .bits = 8 },
            .u16 => .{ .kind = .unsigned, .bits = 16 },
            .u32 => .{ .kind = .unsigned, .bits = 32 },
            .u64, .usize => .{ .kind = .unsigned, .bits = 64 },
            .f32 => .{ .kind = .float, .bits = 32 },
            .f64 => .{ .kind = .float, .bits = 64 },
            .bool, .char, .str, .ptr => null,
        };
    }

    // when conversion situation arise we will use to find out
    // if we can implicitly convert between two types (from -> to)
    pub fn can_implicit_convert(from: Primitive, to: Primitive) bool {
        if (from == to) return true;
        const f = numeric_rank(from) orelse return false;
        const t = numeric_rank(to) orelse return false;
        if (f.kind != t.kind) return t.kind == .float and f.kind != .float;
        // i8 -> i16 (common sense)
        // or i64 -> isize and u64 -> usize (same)
        return t.bits >= f.bits;
    }

    // to check if an id (from) can be assign to another id (to)
    // it's useful for type conversion checking.
    pub fn assignable(self: *TypeSystem, from: TypeId, to: TypeId) bool {
        if (from == .invalid or to == .invalid) return true;
        if (from == to) return true;
        return switch (self.get(to).*) {
            .primitive => |pto| switch (self.get(from).*) {
                .primitive => |pfrom| can_implicit_convert(pfrom, pto),
                else => false,
            },
            .optional => |inner| from == inner or self.assignable(from, inner),
            .error_union => |inner| from == inner or self.assignable(from, inner),
            .slice => |s| switch (self.get(from).*) {
                .array => |a| self.assignable(a.child, s.child),
                else => false,
            },
            else => false,
        };
    }

    pub fn unify(self: *TypeSystem, a: TypeId, b: TypeId) ?TypeId {
        if (a == .invalid) return b;
        if (b == .invalid or a == b) return a;
        if (self.assignable(a, b)) return b;
        if (self.assignable(a, b)) return b;
        return null;
    }

    // find type of literal "hi" -> string, 24 -> i32
    pub fn literal_type(self: *TypeSystem, kind: ast.LiteralKind) !TypeId {
        return switch (kind) {
            .integer => self.primitive(.i32),
            .float => self.primitive(.f64),
            .string => self.primitive(.str),
            .char => self.primitive(.char),
            .bool_true, .bool_false => self.primitive(.bool),
        };
    }

    // does literal fits this type
    pub fn literal_fits(self: *TypeSystem, kind: ast.LiteralKind, id: TypeId) bool {
        if (id == .invalid) return false;
        const p = switch (self.get(id).*) {
            .primitive => |p| p,
            else => return false,
        };
        return switch (kind) {
            .integer => switch (p) {
                .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .usize, .isize => true,
                else => false,
            },
            .float => switch (p) {
                .f32, .f64 => true,
                else => false,
            },
            else => false,
        };
    }

    pub fn name_of(self: *TypeSystem, id: TypeId) []const u8 {
        if (id == .invalid) return "<invalid>";
        return switch (self.get(id).*) {
            .primitive => |p| @tagName(p),
            .array => |a| std.fmt.allocPrint(self.arena.allocator(), "[{d}]{s}", .{ a.len, self.name_of(a.child) }) catch "<oom>",
            .slice => |s| std.fmt.allocPrint(self.arena.allocator(), "[]{s}", .{self.name_of(s.child)}) catch "<oom>",
            .struct_ty => |*s| s.name,
            else => "not implemented",
        };
    }

    // struct or named type specific things //
    pub fn register(self: *TypeSystem, name: []const u8, id: TypeId) !void {
        try self.struct_reg.put(self.allocator, name, id);
    }

    pub fn resolve(self: *TypeSystem, name: []const u8) ?TypeId {
        return self.struct_reg.get(name);
    }
};
