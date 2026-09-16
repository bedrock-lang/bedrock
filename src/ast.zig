const std = @import("std");
const token = @import("token.zig");
const Token = @import("token.zig").Token;

pub const Item = union(enum) {
    import_def: ImportDef,
    function: FunctionDef,
    proc: ProcDef,
    type_def: TypeDef,
    extern_def: ExternDef,
    var_def: VarDef,
    const_def: ConstDef,

    pub fn print(self: *Item, indent: usize) anyerror!void {
        switch (self.*) {
            .import_def => |*i| try i.print(indent),
            .function => |*f| try f.print(indent),
            .proc => |*p| try p.print(indent),
            .type_def => |*t| try t.print(indent),
            .extern_def => |*e| try e.print(indent),
            .var_def => |*v| try v.print(indent),
            .const_def => |*c| try c.print(indent),
        }
    }
};

pub const Program = struct {
    items: std.ArrayList(Item),
};

// import_def = "import" IDENT {"." IDENT} ";"
pub const ImportDef = struct {
    path: std.ArrayList([]const u8),
    token: Token,

    pub fn print(self: *ImportDef, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("import ", .{});
        for (self.path.items) |p| {
            std.debug.print("{s}", .{p});
            std.debug.print(".", .{});
        }
        std.debug.print("\n", .{});
    }

    pub fn deinit(self: *ImportDef, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
    }
};

// type_param = IDENT
pub const TypeParam = struct {
    name: []const u8 = "",
    token: Token,

    pub fn print(self: *TypeParam, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("type param: {s}\n", .{self.name});
    }
};

// param = IDENT ":" [ "const" ] type
pub const Param = struct {
    name: []const u8 = "",
    is_const: bool,
    type: *Type,
    token: Token,

    pub fn print(self: *Param, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("param: {s} -> ", .{self.name});
        try self.type.*.print(0);
    }

    pub fn deinit(self: *Param, allocator: std.mem.Allocator) void {
        self.type.deinit(allocator);
    }
};

// function = [ "pub" ] [ "inline" ] "func" IDENT [ type_params ] "(" [ params ] ")" result block "end"
pub const FunctionDef = struct {
    is_pub: bool,
    is_inline: bool,
    name: []const u8 = "",
    type_params: std.ArrayList(TypeParam),
    params: std.ArrayList(Param),
    result: *Type,
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn deinit(self: *FunctionDef, allocator: std.mem.Allocator) void {
        for (self.params.items) |param| {
            param.type.deinit(allocator);
            allocator.destroy(param.type);
        }
        self.params.deinit(allocator);
        self.type_params.deinit(allocator);
        self.result.deinit(allocator);
        allocator.destroy(self.result);
        for (self.body.items) |*stmt| stmt.deinit(allocator);
        self.body.deinit(allocator);
    }

    pub fn print(self: *FunctionDef, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("function: {s}\n", .{self.name});
        for (self.type_params.items) |*tp| try tp.print(indent + 4);
        for (self.params.items) |*p| try p.print(indent + 4);
        try self.result.print(indent + 4);
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }
};

pub const ProcDef = struct {
    is_pub: bool,
    is_inline: bool,
    name: []const u8 = "",
    type_params: std.ArrayList(TypeParam),
    params: std.ArrayList(Param),
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *ProcDef, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("proc: {s}\n", .{self.name});
        for (self.type_params.items) |*tp| try tp.print(indent + 4);
        for (self.params.items) |*p| try p.print(indent + 4);
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }
    pub fn deinit(self: *ProcDef, allocator: std.mem.Allocator) void {
        for (self.params.items) |param| {
            param.type.deinit(allocator);
            allocator.destroy(param.type);
        }
        self.params.deinit(allocator);
        self.type_params.deinit(allocator);
        for (self.body.items) |*stmt| {
            stmt.deinit(allocator);
        }
        self.body.deinit(allocator);
    }
};

pub const TypeVariant = union(enum) {
    struct_def: StructDef,
    enum_def: EnumDef,

    pub fn print(self: *TypeVariant, indent: usize) anyerror!void {
        switch (self.*) {
            .struct_def => |*s| try s.print(indent),
            .enum_def => |*e| try e.print(indent),
        }
    }

    pub fn deinit(self: *TypeVariant, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .struct_def => |*s| s.deinit(allocator),
            .enum_def => |*e| e.deinit(allocator),
        }
    }
};

// type_def = "type" IDENT [ type_params ] "=" ( "struct" [ struct_members ] "end"
//                                                     | "enum" [ enum_variants ] "end"
//                                                     | type ";" )
pub const TypeDef = struct {
    is_pub: bool,
    is_global: bool,
    variant: TypeVariant,

    pub fn print(self: *TypeDef, indent: usize) anyerror!void {
        try self.variant.print(indent);
    }

    pub fn deinit(self: *TypeDef, allocator: std.mem.Allocator) void {
        self.variant.deinit(allocator);
    }
};

// struct_def = [ "pub" ] "type" IDENT [ type_params ] "=" "struct" [ struct_members ] "end"
pub const StructDef = struct {
    is_pub: bool,
    name: []const u8 = "",
    type_params: std.ArrayList(TypeParam),
    fields: std.ArrayList(StructField),
    methods: std.ArrayList(MethodDef),
    token: Token,

    pub fn print(self: *StructDef, indent: usize) anyerror!void {
        std.debug.print("StructDef: {s}\n", .{self.name});
        for (self.type_params.items) |*tp| try tp.print(indent + 4);
        for (self.fields.items) |*f| try f.print(indent + 4);
        for (self.methods.items) |*m| try m.print(indent + 4);
    }

    pub fn deinit(self: *StructDef, allocator: std.mem.Allocator) void {
        self.type_params.deinit(allocator);
        for (self.fields.items) |*f| {
            f.deinit(allocator);
        }
        self.fields.deinit(allocator);
        self.methods.deinit(allocator);
    }
};

// enum_variants   = enum_variant { "," enum_variant } [ "," ]
// enum_variant    = IDENT
pub const EnumVariant = struct {
    name: []const u8 = "",
    token: Token,

    pub fn print(self: *EnumVariant, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("enum variant: {s}\n", .{self.name});
    }
};

// enum_def = [ "pub" ] "type" IDENT [ type_params ] "=" "enum" [ enum_variants ] "end"
pub const EnumDef = struct {
    is_pub: bool,
    name: []const u8 = "",
    type_params: std.ArrayList(TypeParam),
    variants: std.ArrayList(EnumVariant),
    token: Token,

    pub fn print(self: *EnumDef, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("enum: {s}\n", .{self.name});
        for (self.type_params.items) |*tp| try tp.print(indent + 4);
        for (self.variants.items) |*v| try v.print(indent + 4);
    }

    pub fn deinit(self: *EnumDef, allocator: std.mem.Allocator) void {
        self.type_params.deinit(allocator);
    }
};

// extern_params   = extern_param { "," extern_param } [ "," "..." ] | "..."
// extern_param    = IDENT ":" type
pub const ExternParam = struct {
    name: []const u8 = "",
    type: *Type,
    token: Token,

    pub fn print(self: *ExternParam, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("extern param: {s}\n", .{self.name});
    }

    pub fn deinit(self: *ExternParam, allocator: std.mem.Allocator) void {
        self.name.deinit(allocator);
    }
};

// extern_def = "extern" ( "func" IDENT "(" [ extern_params ] ")" "->" type
//            | "proc" IDENT "(" [ extern_params ] ")" )
pub const ExternDef = struct {
    kind: union(enum) {
        func: struct {
            name: []const u8 = "",
            params: std.ArrayList(Param),
            is_variadic: bool,
            result: *Type,
        },
        proc: struct {
            name: []const u8 = "",
            params: std.ArrayList(Param),
            is_variadic: bool,
        },
    },
    token: Token,

    pub fn print(self: *ExternDef, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        switch (self.kind) {
            .func => |f| {
                std.debug.print("extern func: {s}{s}\n", .{ f.name, if (f.is_variadic) " (variadic)" else "" });
                for (f.params.items) |*p| try p.print(indent + 4);
                try f.result.print(indent + 4);
            },
            .proc => |p| {
                std.debug.print("extern proc: {s}{s}\n", .{ p.name, if (p.is_variadic) " (variadic)" else "" });
                for (p.params.items) |*param| try param.print(indent + 4);
            },
        }
    }
    pub fn deinit(self: *ExternDef, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .func => |*f| {
                for (f.params.items) |p| {
                    p.type.deinit(allocator);
                    allocator.destroy(p.type);
                }
                f.params.deinit(allocator);
                f.result.deinit(allocator);
                allocator.destroy(f.result);
            },
            .proc => |*pr| {
                for (pr.params.items) |p| {
                    p.type.deinit(allocator);
                    allocator.destroy(p.type);
                }
                pr.params.deinit(allocator);
            },
        }
    }
};

// var_def  = [ "pub" ] "var" IDENT [ ":" type ] "=" expression ";"
pub const VarDef = struct {
    is_pub: bool,
    is_global: bool,
    name: []const u8 = "",
    type_ann: ?*Type,
    value: *Expr,
    token: Token,

    pub fn print(self: *VarDef, indent: usize) anyerror!void {
        std.debug.print("VarDef:\n", .{});
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("var {s}\n", .{self.name});
        if (self.type_ann) |ty| {
            try ty.print(indent + 2);
        }
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("value:\n", .{});
        try self.value.print(indent + 2);
    }

    pub fn deinit(self: *VarDef, allocator: std.mem.Allocator) void {
        if (self.type_ann) |ty| {
            ty.deinit(allocator);
            allocator.destroy(ty);
        }
        self.value.deinit(allocator);
    }
};

// const_def = [ "pub" ] "const" IDENT [ ":" type ] "=" expression ";"
pub const ConstDef = struct {
    is_pub: bool,
    is_global: bool,
    name: []const u8 = "",
    type_ann: ?*Type,
    value: *Expr,
    token: Token,

    pub fn print(self: *ConstDef, indent: usize) anyerror!void {
        std.debug.print("ConstDef:\n", .{});
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("const {s}\n", .{self.name});
        if (self.type_ann) |ty| {
            try ty.print(indent + 2);
        }
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("value:\n", .{});
        try self.value.print(indent + 2);
    }

    pub fn deinit(self: *ConstDef, allocator: std.mem.Allocator) void {
        if (self.type_ann) |ty| {
            ty.deinit(allocator);
            allocator.destroy(ty);
        }
        self.value.deinit(allocator);
    }
};

pub const FieldInit = struct {
    name: []const u8,
    value: *Expr,
    token: Token,

    pub fn print(self: *FieldInit, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("{s}:\n", .{self.name});
        try self.value.print(indent + 4);
    }

    pub fn deinit(self: *FieldInit, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }
};

pub const StructLiteral = struct {
    name: []const u8,
    field_inits: std.ArrayList(FieldInit),
    token: Token,

    pub fn print(self: *StructLiteral, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("struct literal: {s}\n", .{self.name});
        for (self.field_inits.items) |*f| {
            try f.print(indent + 4);
        }
    }

    pub fn deinit(self: *StructLiteral, allocator: std.mem.Allocator) void {
        for (self.field_inits.items) |*f| {
            f.deinit(allocator);
        }
        self.field_inits.deinit(allocator);
    }
};

// struct_field = ["pub"] IDENT ":" type
pub const StructField = struct {
    is_pub: bool,
    name: []const u8 = "",
    type: *Type,
    token: Token,

    pub fn print(self: *StructField, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        if (self.is_pub) std.debug.print("pub ", .{});
        std.debug.print("struct field: {s}\n", .{self.name});
        try self.type.print(indent + 4);
    }

    pub fn deinit(self: *StructField, allocator: std.mem.Allocator) void {
        self.type.deinit(allocator);
        allocator.destroy(self.type);
    }
};

// method_def = [ "pub" ] [ "inline" ] "func" IDENT [ type_params ] "(" [ params ] ")" result block "end"
//            | [ "pub" ] [ "inline" ] "proc" IDENT [ type_params ] "(" [ params ] ")" block "end"
pub const MethodDef = union(enum) {
    func: FunctionDef,
    proc: ProcDef,

    pub fn print(self: *MethodDef, indent: usize) anyerror!void {
        switch (self.*) {
            .func => |*f| try f.print(indent),
            .proc => |*p| try p.print(indent),
        }
    }
};

// type = "i8" | "i16" | "i32" | "i64" //
//      | "u8" | "u16" | "u32" | "u64" //
//      | "usize" | "isize"            //
//      | "f32" | "f64"                //
//      | "bool" | "char" | "str"      //
//      | "*" type                     //
//      | array_type                   //
//      | named_type                   //
//      | func_type                    //
//      | proc_type                    //

pub const PrimitiveType = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    usize,
    isize,
    f32,
    f64,
    bool,
    char,
    str,
    ptr,

    pub fn print(self: *PrimitiveType, indent: usize) anyerror!void {
        _ = indent;
        std.debug.print("primitive type: {s}\n", .{@tagName(self.*)});
    }
};

pub const ArraySize = union(enum) {
    fixed: []const u8, // INTEGER
    inferred, // "_"

    pub fn print(self: *ArraySize, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        switch (self.*) {
            .fixed => |s| std.debug.print("array size: {s}\n", .{s}),
            .inferred => std.debug.print("array size: inferred\n", .{}),
        }
    }
};

// array_type = "[" ( INTEGER | "_" ) "]" type
pub const ArrayType = struct {
    size: ArraySize,
    elem: *Type,
    token: Token,

    pub fn print(self: *ArrayType, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("array type\n", .{});
        try self.size.print(indent + 4);
        try self.elem.print(indent + 4);
    }
};

pub const SliceType = struct {
    elem: *Type,
    token: Token,
    pub fn print(self: *SliceType, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("slice type\n", .{});
        try self.elem.print(indent + 4);
    }
};

// named_type = IDENT [ "[" type { "," type } [ "," ] "]" ]
pub const NamedType = struct {
    name: []const u8 = "",
    args: []*Type,
    token: Token,

    pub fn print(self: *NamedType, indent: usize) anyerror!void {
        // for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("named_type: {s}\n", .{self.name});
        for (self.args) |arg| try arg.print(indent + 4);
    }
};

// func_type  = "func" "(" [ type_list ] ")" result
pub const FuncType = struct {
    params: std.ArrayList(*Type),
    result: *Type,
    token: Token,

    pub fn print(self: *FuncType, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("func type\n", .{});
        std.debug.print("params:\n", .{});
        for (self.params.items) |param| try param.print(indent + 4);
        std.debug.print("result:\n", .{});
        try self.result.print(indent + 4);
    }
};

// proc_type  = "proc" "(" [ type_list ] ")"
pub const ProcType = struct {
    params: std.ArrayList(*Type),
    token: Token,

    pub fn print(self: *ProcType, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("proc type\n", .{});
        for (self.params.items) |param| try param.print(indent + 4);
    }
};

pub const BaseType = union(enum) {
    primitive: PrimitiveType,
    pointer: *Type,
    array: ArrayType,
    slice: SliceType,
    named: NamedType,
    func: FuncType,
    proc: ProcType,

    pub fn print(self: *BaseType, indent: usize) anyerror!void {
        switch (self.*) {
            .primitive => |*p| try p.print(indent),
            .pointer => |p| {
                for (0..indent) |_| std.debug.print(" ", .{});
                std.debug.print("pointer type\n", .{});
                try p.print(indent + 4);
            },
            .array => |*a| try a.print(indent),
            .slice => |*s| try s.print(indent),
            .named => |*n| try n.print(indent),
            .func => |*f| try f.print(indent),
            .proc => |*p| try p.print(indent),
        }
    }

    pub fn deinit(self: *BaseType, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .primitive => {},
            .pointer => |p| {
                p.deinit(allocator);
                allocator.destroy(p);
            },
            .array => |*a| {
                a.elem.deinit(allocator);
                allocator.destroy(a.elem);
            },
            .slice => |*s| {
                s.elem.deinit(allocator);
                allocator.destroy(s.elem);
            },
            .named => |*n| {
                for (n.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                if (n.args.len > 0) allocator.free(n.args);
            },
            .func => |*f| {
                for (f.params.items) |p| {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
                f.params.deinit(allocator);
                f.result.deinit(allocator);
                allocator.destroy(f.result);
            },
            .proc => |*p| {
                for (p.params.items) |pa| {
                    pa.deinit(allocator);
                    allocator.destroy(pa);
                }
                p.params.deinit(allocator);
            },
        }
    }
};

// type = [ "?" ] base_type [ "!" ]
pub const Type = struct {
    is_optional: bool = false,
    is_error_union: bool = false,
    base: BaseType,
    token: Token,
    pub fn print(self: *Type, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        if (self.is_optional) std.debug.print("optional ", .{});
        try self.base.print(indent + 4);
        if (self.is_error_union) {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("(error union)\n", .{});
        }
    }
    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
    }
};

// Expressions //

pub const LiteralKind = enum {
    integer,
    float,
    char,
    string,
    bool_true,
    bool_false,

    pub fn print(self: *LiteralKind, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("literal kind: {s}\n", .{@tagName(self.*)});
    }
};

pub const LiteralExpr = struct {
    kind: LiteralKind,
    raw: []const u8,
    token: Token,

    pub fn print(self: *LiteralExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("{s}\n", .{self.raw});
        try self.kind.print(indent + 2);
    }

    pub fn to_string(self: *LiteralExpr, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}", .{self.raw});
    }

    pub fn deinit(self: *LiteralExpr, allocator: std.mem.Allocator) void {
        if (self.kind == .string) {
            allocator.free(self.token.val);
        }
    }
};

pub const IdentExpr = struct {
    name: []const u8 = "",
    token: Token,

    pub fn print(self: *IdentExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("identifier: {s}\n", .{self.name});
    }
};

pub const UnaryOp = enum {
    neg,
    not,
    bit_not,
    addr_of,
    deref,
    new,

    pub fn print(self: *UnaryOp, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("unary op: {s}\n", .{@tagName(self.*)});
    }
};

pub const BinaryOp = enum {
    orelse_op,
    logical_or,
    logical_and,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    bit_or,
    bit_xor,
    bit_and,
    shl,
    shr,
    range,
    range_incl,
    add,
    sub,
    mul,
    div,
    mod,

    pub fn print(self: *BinaryOp, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("binary op: {s}\n", .{@tagName(self.*)});
    }
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    token: Token,

    pub fn print(self: *BinaryExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("binary expr\n", .{});
        try self.op.print(indent + 4);
        try self.lhs.print(indent + 4);
        try self.rhs.print(indent + 4);
    }

    pub fn deinit(self: *BinaryExpr, allocator: std.mem.Allocator) void {
        self.lhs.deinit(allocator);
        self.rhs.deinit(allocator);
    }

    pub fn to_string(self: *BinaryExpr, allocator: std.mem.Allocator) anyerror![]const u8 {
        const lhs = try self.lhs.to_string(allocator);
        const rhs = try self.rhs.to_string(allocator);
        defer {
            allocator.free(lhs);
            allocator.free(rhs);
        }
        const op = switch (self.op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .eq => "==",
            .gt => ">",
            .ge => ">=",
            .lt => "<",
            .le => "<=",
            .ne => "!=",
            .logical_or => "||",
            .logical_and => "&&",
            .bit_or => "|",
            .bit_xor => "^",
            .bit_and => "&",
            .shr => ">>",
            .shl => "<<",
            else => "",
        };
        return try std.fmt.allocPrint(allocator, "({s} {s} {s})", .{ lhs, op, rhs });
    }
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    token: Token,

    pub fn print(self: *UnaryExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("unary expr\n", .{});
        try self.op.print(indent + 4);
        try self.operand.print(indent + 4);
    }

    pub fn deinit(self: *UnaryExpr, allocator: std.mem.Allocator) void {
        self.operand.deinit(allocator);
    }

    pub fn to_string(self: *UnaryExpr, allocator: std.mem.Allocator) anyerror![]const u8 {
        const o = try self.operand.to_string(allocator);
        defer {
            allocator.free(o);
        }
        const op = switch (self.op) {
            .neg => "-",
            .bit_not => "~",
            .not => "!",
            .addr_of => "&",
            .deref => "*",
            .new => "new",
        };
        return try std.fmt.allocPrint(allocator, "({s}{s})", .{ op, o });
    }
};

// A "." Ident
pub const FieldAccessExpr = struct {
    target: *Expr,
    field: []const u8,
    token: Token,

    pub fn print(self: *FieldAccessExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("field access: {s}\n", .{self.field});
        try self.target.print(indent + 4);
    }

    pub fn deinit(self: *FieldAccessExpr, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
    }
};

pub const CallArg = struct {
    value: *Expr,

    pub fn print(self: *CallArg, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("call arg\n", .{});
        try self.value.print(indent + 4);
    }

    pub fn deinit(self: *CallArg, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }
};

pub const CallExpr = struct {
    callee: *Expr,
    args: std.ArrayList(CallArg),
    token: Token,

    pub fn print(self: *CallExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("call expr\n", .{});
        try self.callee.print(indent + 4);
        for (self.args.items) |*arg| try arg.print(indent + 4);
    }

    pub fn deinit(self: *CallExpr, allocator: std.mem.Allocator) void {
        self.callee.deinit(allocator);
        for (self.args.items) |*arg| {
            arg.deinit(allocator);
        }
        self.args.deinit(allocator);
    }
};

// this support both, arr[i] and also
// foo[Type] -> generic instantiations
pub const IndexExpr = struct {
    target: *Expr,
    args: std.ArrayList(*Expr),
    token: Token,

    pub fn print(self: *IndexExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("index expr\n", .{});
        try self.target.print(indent + 4);
        for (self.args.items) |arg| try arg.print(indent + 4);
    }

    pub fn deinit(self: *IndexExpr, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        for (self.args.items) |arg| arg.deinit(allocator);
        self.args.deinit(allocator);
    }
};

// ?
pub const OptionalUnwrapExpr = struct {
    operand: *Expr,
    token: Token,

    pub fn print(self: *OptionalUnwrapExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("optional unwrap expr\n", .{});
        try self.operand.print(indent + 4);
    }
};

// array_literal = "[" [ array_elems ] "]"
pub const ArrayLiteralExpr = struct {
    elements: std.ArrayList(*Expr),
    token: Token,

    pub fn print(self: *ArrayLiteralExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("array literal\n", .{});
        for (self.elements.items) |elem| try elem.print(indent + 4);
    }

    pub fn deinit(self: *ArrayLiteralExpr, allocator: std.mem.Allocator) void {
        for (self.elements.items) |e| e.deinit(allocator);
        self.elements.deinit(allocator);
    }
};

// elif_clause = "elif" expression block
pub const ElifClause = struct {
    cond: *Expr,
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *ElifClause, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("elif clause\n", .{});
        try self.cond.print(indent + 4);
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }
    pub fn deinit(self: *ElifClause, allocator: std.mem.Allocator) void {
        self.cond.deinit(allocator);
        for (self.body.items) |*s| s.deinit(allocator);
        self.body.deinit(allocator);
    }
};

// if_expr = "if" expression block { elif_clause } [ else_clause ] "end"
pub const IfExpr = struct {
    cond: *Expr,
    then_body: std.ArrayList(Stmt),
    elifs: std.ArrayList(ElifClause),
    else_body: ?std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *IfExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("if expr\n", .{});
        try self.cond.print(indent + 4);
        for (self.then_body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
        for (self.elifs.items) |*elif| try elif.print(indent + 4);
        if (self.else_body) |*else_body| {
            for (else_body.items) |*stmt| {
                for (0..indent + 4) |_|
                    std.debug.print(" ", .{});
                std.debug.print("else clause\n", .{});
                try stmt.print(indent + 4);
            }
        }
    }
    pub fn deinit(self: *IfExpr, allocator: std.mem.Allocator) void {
        self.cond.deinit(allocator);
        for (self.then_body.items) |*s| s.deinit(allocator);
        self.then_body.deinit(allocator);
        for (self.elifs.items) |*s| s.deinit(allocator);
        self.elifs.deinit(allocator);
        if (self.else_body) |*body| {
            for (body.items) |*i| i.deinit(allocator);
            body.deinit(allocator);
        }
    }
};

// pattern = INTEGER | BOOL | IDENT
pub const Pattern = union(enum) {
    integer: []const u8,
    boolean: bool,
    ident: []const u8,

    pub fn print(self: *Pattern, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        switch (self.*) {
            .integer => |*i| std.debug.print("pattern integer: {s}\n", .{i.*}),
            .boolean => |*b| std.debug.print("pattern boolean: {}\n", .{b.*}),
            .ident => |*id| std.debug.print("pattern ident: {s}\n", .{id.*}),
        }
    }
};

// match_arm = "case" pattern block
pub const MatchArm = struct {
    pattern: Pattern,
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *MatchArm, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("match arm\n", .{});
        try self.pattern.print(indent + 4);
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }

    pub fn deinit(self: *MatchArm, allocator: std.mem.Allocator) void {
        for (self.body.items) |*s| s.deinit(allocator);
        self.body.deinit(allocator);
    }
};

// match_expr = "match" expression [ match_arms ] "end"
pub const MatchExpr = struct {
    subject: *Expr,
    arms: std.ArrayList(MatchArm),
    else_body: ?std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *MatchExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("match\n", .{});
        for (0..indent + 2) |_| std.debug.print(" ", .{});
        std.debug.print("expr\n", .{});
        try self.subject.print(indent + 4);
        for (self.arms.items) |*arm| try arm.print(indent + 4);
        if (self.else_body) |*else_body| {
            for (else_body.items) |*stmt| {
                for (0..indent + 4) |_|
                    std.debug.print(" ", .{});
                std.debug.print("else clause\n", .{});
                try stmt.print(indent + 4);
            }
        }
    }

    pub fn deinit(self: *MatchExpr, allocator: std.mem.Allocator) void {
        self.subject.deinit(allocator);
        for (self.arms.items) |*a| a.deinit(allocator);
        self.arms.deinit(allocator);
        if (self.else_body) |*body| {
            for (body.items) |*i| i.deinit(allocator);
            body.deinit(allocator);
        }
    }
};

// while_expr = "while" expression block "end"
pub const WhileExpr = struct {
    cond: *Expr,
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *WhileExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("while expr\n", .{});
        try self.cond.print(indent + 4);
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }
    pub fn deinit(self: *WhileExpr, allocator: std.mem.Allocator) void {
        self.cond.deinit(allocator);
        for (self.body.items) |*s| s.deinit(allocator);
        self.body.deinit(allocator);
    }
};

// for_expr = "for" IDENT "in" expression block "end"
pub const ForExpr = struct {
    binding: []const u8,
    index_binding: ?[]const u8 = null,
    index_start: ?*Expr = null,
    iterable: *Expr,
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *ForExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        if (self.index_binding) |ib| {
            std.debug.print("for expr: {s}, {s}\n", .{ self.binding, ib });
        } else {
            std.debug.print("for expr: {s}\n", .{self.binding});
        }
        try self.iterable.print(indent + 4);
        if (self.index_start) |s| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("index start:\n", .{});
            try s.print(indent + 8);
        }
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }
    pub fn deinit(self: *ForExpr, allocator: std.mem.Allocator) void {
        self.iterable.deinit(allocator);
        if (self.index_start) |s| s.deinit(allocator);
        for (self.body.items) |*i| i.deinit(allocator);
        self.body.deinit(allocator);
    }
};

// comptime_expr = "comptime" block "end"
pub const ComptimeExpr = struct {
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *ComptimeExpr, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("comptime expr\n", .{});
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }
};

pub const Nil = struct {
    token: Token,

    pub fn print(self: *Nil, indent: usize) anyerror!void {
        _ = self;
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("nil\n", .{});
    }
};

pub const Expr = union(enum) {
    literal: LiteralExpr,
    ident: IdentExpr,
    binary: BinaryExpr,
    unary: UnaryExpr,
    field_access: FieldAccessExpr,
    call: CallExpr,
    index: IndexExpr,
    optional_unwrap: OptionalUnwrapExpr,
    array_literal: ArrayLiteralExpr,
    comptime_expr: ComptimeExpr,
    struct_literal: StructLiteral,
    nil: Nil,

    pub fn print(self: *Expr, indent: usize) anyerror!void {
        switch (self.*) {
            .literal => |*l| try l.print(indent),
            .ident => |*i| try i.print(indent),
            .binary => |*b| try b.print(indent),
            .unary => |*u| try u.print(indent),
            .field_access => |*f| try f.print(indent),
            .call => |*c| try c.print(indent),
            .index => |*i| try i.print(indent),
            .optional_unwrap => |*o| try o.print(indent),
            .array_literal => |*a| try a.print(indent),
            .comptime_expr => |*c| try c.print(indent),
            .struct_literal => |*s| try s.print(indent),
            .nil => |*n| try n.print(indent),
        }
    }

    pub fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .literal => |*l| {
                l.deinit(allocator);
                allocator.destroy(self);
            },
            .binary => |*b| {
                b.deinit(allocator);
                allocator.destroy(self);
            },
            .unary => |*u| {
                u.deinit(allocator);
                allocator.destroy(self);
            },
            .ident => allocator.destroy(self),
            .field_access => |*f| {
                f.deinit(allocator);
                allocator.destroy(self);
            },
            .call => |*c| {
                c.deinit(allocator);
                allocator.destroy(self);
            },
            .index => |*i| {
                i.deinit(allocator);
                allocator.destroy(self);
            },
            .array_literal => |*a| {
                a.deinit(allocator);
                allocator.destroy(self);
            },
            .struct_literal => |*s| {
                s.deinit(allocator);
                allocator.destroy(self);
            },
            .nil => allocator.destroy(self),
            else => {
                // TODO:
            },
        }
    }

    pub fn to_string(self: *Expr, allocator: std.mem.Allocator) anyerror![]const u8 {
        return switch (self.*) {
            .literal => |*l| l.to_string(allocator),
            .binary => |*b| b.to_string(allocator),
            .unary => |*u| u.to_string(allocator),
            else => try std.fmt.allocPrint(allocator, "", .{}),
        };
    }

    // return token of subexpression
    pub fn token_of(self: *Expr) Token {
        return switch (self.*) {
            .literal => self.literal.token,
            .ident => self.ident.token,
            .binary => self.binary.token,
            .unary => self.unary.token,
            .field_access => self.field_access.token,
            .call => self.call.token,
            .index => self.index.token,
            .optional_unwrap => self.optional_unwrap.token,
            .array_literal => self.array_literal.token,
            .comptime_expr => self.comptime_expr.token,
            .struct_literal => self.struct_literal.token,
            .nil => self.nil.token,
        };
    }
};

// break;
pub const BreakStmt = struct {
    token: Token,

    pub fn print(self: *BreakStmt, indent: usize) anyerror!void {
        _ = self;
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("break stmt\n", .{});
    }
};

// continue;
pub const ContinueStmt = struct {
    token: Token,

    pub fn print(self: *ContinueStmt, indent: usize) anyerror!void {
        _ = self;
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("continue stmt\n", .{});
    }
};

// statement       = var_stmt | const_stmt | local_static_var_stmt | assign_stmt | defer_stmt
//                 | unsafe_stmt | control_flow_stmt | return_stmt | expr_stmt
pub const Stmt = union(enum) {
    var_stmt: VarStmt,
    const_stmt: ConstStmt,
    assign_stmt: AssignStmt,
    local_static_var_stmt: LocalStaticVarStmt,
    defer_stmt: DeferStmt,
    unsafe_stmt: UnsafeStmt,
    control_flow_stmt: ControlFlowStmt,
    return_stmt: ReturnStmt,
    expr_stmt: ExprStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    // NOTE: temporary print stub
    print_stub: PrintStub,

    pub fn print(self: *Stmt, indent: usize) anyerror!void {
        switch (self.*) {
            .var_stmt => |*v| try v.print(indent),
            .const_stmt => |*c| try c.print(indent),
            .assign_stmt => |*a| try a.print(indent),
            .local_static_var_stmt => |*l| try l.print(indent),
            .defer_stmt => |*d| try d.print(indent),
            .unsafe_stmt => |*u| try u.print(indent),
            .control_flow_stmt => |*c| try c.print(indent),
            .return_stmt => |*r| try r.print(indent),
            .expr_stmt => |*e| try e.print(indent),
            .print_stub => |*p| try p.print(indent),
            .break_stmt => |*b| try b.print(indent),
            .continue_stmt => |*c| try c.print(indent),
        }
    }
    pub fn deinit(self: *Stmt, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .var_stmt => |*v| v.deinit(allocator),
            .const_stmt => |*c| c.deinit(allocator),
            .assign_stmt => |*a| a.deinit(allocator),
            .local_static_var_stmt => |*l| l.deinit(allocator),
            .defer_stmt => |*d| d.deinit(allocator),
            .unsafe_stmt => |*u| u.deinit(allocator),
            .return_stmt => |*r| r.deinit(allocator),
            .expr_stmt => |*e| e.deinit(allocator),
            .control_flow_stmt => |*c_f| c_f.deinit(allocator),
            else => {},
        }
    }
};

pub const PrintStub = struct {
    value: StubExpr,
    token: Token,

    pub fn print(self: *PrintStub, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("print stub:\n", .{});
        try self.value.print(indent + 4);
    }
};

pub const StubExpr = union(enum) {
    stub_literal: LiteralExpr,
    stub_ident: IdentExpr,

    pub fn print(self: *StubExpr, indent: usize) anyerror!void {
        switch (self.*) {
            .stub_literal => |*l| try l.print(indent + 4),
            .stub_ident => |*i| try i.print(indent + 4),
        }
    }
};

pub const ControlFlowStmt = union(enum) {
    if_expr: IfExpr,
    match_expr: MatchExpr,
    while_expr: WhileExpr,
    for_expr: ForExpr,

    pub fn print(self: *ControlFlowStmt, indent: usize) anyerror!void {
        switch (self.*) {
            .if_expr => |*i| try i.print(indent + 2),
            .match_expr => |*m| try m.print(indent + 2),
            .while_expr => |*w| try w.print(indent + 2),
            .for_expr => |*f| try f.print(indent + 2),
        }
    }
    pub fn deinit(self: *ControlFlowStmt, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .match_expr => |*m| m.deinit(allocator),
            .if_expr => |*i| i.deinit(allocator),
            .for_expr => |*f| f.deinit(allocator),
            .while_expr => |*w| w.deinit(allocator),
        }
    }
};

// var_stmt = "var" IDENT [ ":" type ] "=" expression ";"
pub const VarStmt = struct {
    name: []const u8 = "",
    type_ann: ?*Type,
    value: *Expr,
    token: Token,

    pub fn print(self: *VarStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("var stmt: {s}\n", .{self.name});
        if (self.type_ann) |t| try t.print(indent + 4);
        try self.value.print(indent + 4);
    }
    pub fn deinit(self: *VarStmt, allocator: std.mem.Allocator) void {
        if (self.type_ann) |ty| {
            ty.deinit(allocator);
            allocator.destroy(ty);
        }
        self.value.deinit(allocator);
    }
};

// const_stmt = "const" IDENT [ ":" type ] "=" expression ";"
pub const ConstStmt = struct {
    name: []const u8 = "",
    type_ann: ?*Type,
    value: *Expr,
    token: Token,

    pub fn print(self: *ConstStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("const stmt: {s}\n", .{self.name});
        if (self.type_ann) |t| try t.print(indent + 4);
        try self.value.print(indent + 4);
    }
    pub fn deinit(self: *ConstStmt, allocator: std.mem.Allocator) void {
        if (self.type_ann) |ty| {
            ty.deinit(allocator);
            allocator.destroy(ty);
        }
        self.value.deinit(allocator);
    }
};

// local_static_var_stmt = "static" "var" IDENT [ ":" type ] "=" expression ";"
pub const LocalStaticVarStmt = struct {
    name: []const u8 = "",
    type_ann: ?*Type,
    value: *Expr,
    token: Token,

    pub fn print(self: *LocalStaticVarStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("local static var stmt: {s}\n", .{self.name});
        if (self.type_ann) |t| try t.print(indent + 4);
        try self.value.print(indent + 4);
    }
    pub fn deinit(self: *LocalStaticVarStmt, allocator: std.mem.Allocator) void {
        if (self.type_ann) |ty| {
            ty.deinit(allocator);
            allocator.destroy(ty);
        }
        self.value.deinit(allocator);
    }
};

pub const CompoundOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,

    pub fn print(self: *CompoundOp, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("compound op: {s}\n", .{@tagName(self.*)});
    }
};

// assign_stmt = place_expr ( "=" | compound_op ) expression ";"
pub const AssignStmt = struct {
    target: *Expr,
    op: ?CompoundOp, // if null -> simple '='
    value: *Expr,
    token: Token,

    pub fn print(self: *AssignStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("assign stmt\n", .{});
        try self.target.print(indent + 4);
        if (self.op) |*op| try op.print(indent + 4);
        try self.value.print(indent + 4);
    }
    pub fn deinit(self: *AssignStmt, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        self.value.deinit(allocator);
    }
};

pub const DeferStmt = struct {
    statement_list: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *DeferStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("defer stmt\n", .{});
        for (self.statement_list.items) |*s| {
            try s.print(indent + 4);
        }
    }
    pub fn deinit(self: *DeferStmt, allocator: std.mem.Allocator) void {
        for (self.statement_list.items) |*s| s.deinit(allocator);
        self.statement_list.deinit(allocator);
    }
};

// unsafe_stmt = "unsafe" block "end"
pub const UnsafeStmt = struct {
    body: std.ArrayList(Stmt),
    token: Token,

    pub fn print(self: *UnsafeStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("unsafe stmt\n", .{});
        for (self.body.items) |*stmt| {
            for (0..indent + 4) |_| std.debug.print(" ", .{});
            std.debug.print("stmt\n", .{});
            try stmt.print(indent + 4);
        }
    }
    pub fn deinit(self: *UnsafeStmt, allocator: std.mem.Allocator) void {
        for (self.body.items) |*s| s.deinit(allocator);
        self.body.deinit(allocator);
    }
};

// return_stmt = return_expr ";"
pub const ReturnStmt = struct {
    value: ?*Expr,
    token: Token,

    pub fn print(self: *ReturnStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("return stmt\n", .{});
        if (self.value) |v| try v.print(indent + 4);
    }
    pub fn deinit(self: *ReturnStmt, allocator: std.mem.Allocator) void {
        if (self.value) |v| v.deinit(allocator);
    }
};

// expr_stmt = expression ";"
pub const ExprStmt = struct {
    value: ?*Expr,

    pub fn print(self: *ExprStmt, indent: usize) anyerror!void {
        for (0..indent) |_| std.debug.print(" ", .{});
        std.debug.print("expr stmt\n", .{});
        if (self.value) |v| try v.print(indent + 4);
    }
    pub fn deinit(self: *ExprStmt, allocator: std.mem.Allocator) void {
        if (self.value) |v| v.deinit(allocator);
    }
};

// ast have it's own allocator and deinit
// and ofc it has internal arena, all nodes
// get freed in one shot by deinit, not individually freed
pub const AST = struct {
    program: Program,

    pub fn init() AST {
        return .{
            .program = .{ .items = .empty },
        };
    }

    pub fn deinit(self: *AST, allocator: std.mem.Allocator) void {
        for (self.program.items.items) |*item| {
            switch (item.*) {
                .function => |*func| func.deinit(allocator),
                .import_def => |*i_def| i_def.deinit(allocator),
                .const_def => |*c_def| c_def.deinit(allocator),
                .var_def => |*v_def| v_def.deinit(allocator),
                .proc => |*p_def| p_def.deinit(allocator),
                .extern_def => |*e_def| e_def.deinit(allocator),
                .type_def => |*t_def| t_def.deinit(allocator),
            }
        }
        self.program.items.deinit(allocator);
    }

    pub fn print(self: *AST) anyerror!void {
        std.debug.print("AST:\n", .{});
        for (self.program.items.items) |*item| {
            try item.print(2);
        }
    }
};
