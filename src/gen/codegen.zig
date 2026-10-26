const std = @import("std");
const llvm = @import("llvm");
const compiler = @import("../compiler.zig");
const ast = @import("../ast.zig");
const types = @import("../sema/type_system.zig");
const lower_types = @import("lower_types.zig");
const numeric = @import("numeric.zig");
const stmt_mod = @import("stmt.zig");
const expr_mod = @import("expr.zig");

const log = std.log.scoped(.codegen);
const Error = error{CodegenFail};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    compiler: *compiler.Compiler,
    tm: llvm.LLVMTargetMachineRef,
    triple: [*c]u8,
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    entry: llvm.LLVMBasicBlockRef,
    opt: bool,
    stack_map: std.StringHashMap(llvm.LLVMValueRef),
    global_map: std.StringHashMap(llvm.LLVMValueRef),
    break_targets: std.ArrayList(llvm.LLVMBasicBlockRef),
    continue_targets: std.ArrayList(llvm.LLVMBasicBlockRef),
    struct_types: std.StringHashMap(llvm.LLVMTypeRef),
    enum_types: std.StringHashMap(llvm.LLVMTypeRef),
    enum_tag: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator, c: *compiler.Compiler) !Codegen {
        // initialize target machine and code emission
        var trip = llvm.LLVMGetDefaultTargetTriple();
        if (std.mem.eql(u8, c.opt.target, "aarch64")) {
            llvm.LLVMInitializeAArch64TargetInfo();
            llvm.LLVMInitializeAArch64Target();
            llvm.LLVMInitializeAArch64TargetMC();
            llvm.LLVMInitializeAArch64AsmPrinter();
        } else if (std.mem.eql(u8, c.opt.target, "x86")) {
            llvm.LLVMInitializeX86TargetInfo();
            llvm.LLVMInitializeX86Target();
            llvm.LLVMInitializeX86TargetMC();
            llvm.LLVMInitializeX86AsmPrinter();
        } else if (std.mem.eql(u8, c.opt.target, "wasm")) {
            llvm.LLVMInitializeWebAssemblyTargetInfo();
            llvm.LLVMInitializeWebAssemblyTarget();
            llvm.LLVMInitializeWebAssemblyTargetMC();
            llvm.LLVMInitializeWebAssemblyAsmPrinter();
            trip = @ptrCast(@constCast("wasm32-unknown-unknown"));
        } else {
            log.err("{s} target is not currently supported\n", .{c.opt.target});
            return Error.CodegenFail;
        }

        const g_ctx = llvm.LLVMContextCreate();
        var c_gen = Codegen{
            .allocator = allocator,
            .compiler = c,
            .tm = undefined,
            .triple = trip,
            .ctx = g_ctx,
            .mod = llvm.LLVMModuleCreateWithNameInContext("module", g_ctx),
            .builder = llvm.LLVMCreateBuilderInContext(g_ctx),
            .entry = undefined,
            .opt = false,
            .stack_map = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .global_map = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .break_targets = .empty,
            .continue_targets = .empty,
            .struct_types = std.StringHashMap(llvm.LLVMTypeRef).init(allocator),
            .enum_types = std.StringHashMap(llvm.LLVMTypeRef).init(allocator),
            .enum_tag = std.StringHashMap(usize).init(allocator),
        };

        var target: llvm.LLVMTargetRef = undefined;
        var err_msg: [*c]u8 = null;
        _ = llvm.LLVMGetTargetFromTriple(c_gen.triple, &target, &err_msg);
        if (err_msg) |msg| {
            log.err("{s}\n", .{std.mem.span(msg)});
            llvm.LLVMDisposeMessage(msg);
            return Error.CodegenFail;
        }

        // create target machine for code emmision
        c_gen.tm = llvm.LLVMCreateTargetMachine(
            target,
            c_gen.triple,
            "generic",
            "",
            llvm.LLVMCodeGenLevelDefault,
            llvm.LLVMRelocPIC,
            llvm.LLVMCodeModelDefault,
        );
        llvm.LLVMSetModuleDataLayout(c_gen.mod, llvm.LLVMCreateTargetDataLayout(c_gen.tm));
        llvm.LLVMSetTarget(c_gen.mod, c_gen.triple);

        return c_gen;
    }

    pub fn deinit(self: *Codegen) void {
        llvm.LLVMDisposeTargetMachine(self.tm);
        llvm.LLVMDisposeMessage(self.triple);
        self.stack_map.deinit();
        self.global_map.deinit();
        self.break_targets.deinit(self.allocator);
        self.continue_targets.deinit(self.allocator);
        self.struct_types.deinit();
        var it = self.enum_types.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.enum_types.deinit();
        self.enum_tag.deinit();
    }

    pub fn ts(self: *Codegen) *types.TypeSystem {
        return &self.compiler.sema.types;
    }

    pub fn expr_type(self: *Codegen, e: *ast.Expr) types.TypeId {
        return self.compiler.sema.expr_types.get(e) orelse .invalid;
    }

    pub fn cstr(self: *Codegen, name: []const u8) ![:0]u8 {
        const buf = try self.allocator.alloc(u8, name.len + 1);
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        return buf[0..name.len :0];
    }

    pub fn get_type(self: *Codegen, t: *ast.Type) anyerror!llvm.LLVMTypeRef {
        return lower_types.get_type(self, t);
    }

    pub fn get_llvm_type_of(self: *Codegen, ty: types.TypeId) anyerror!llvm.LLVMTypeRef {
        return lower_types.llvm_type_of(self, ty);
    }

    pub fn coerce_numeric(self: *Codegen, val: llvm.LLVMValueRef, from: types.TypeId, to: types.TypeId) !llvm.LLVMValueRef {
        return numeric.coerce(self, val, from, to);
    }

    pub fn codegen_expression(self: *Codegen, e: *ast.Expr) anyerror!llvm.LLVMValueRef {
        return expr_mod.codegen_expression(self, e);
    }

    pub fn codegen_expression_with_type(self: *Codegen, e: *ast.Expr, expected_ty: ?llvm.LLVMTypeRef) anyerror!llvm.LLVMValueRef {
        return expr_mod.codegen_expression_with_type(self, e, expected_ty);
    }

    pub fn codegen_statements(self: *Codegen, stmts: std.ArrayList(ast.Stmt)) anyerror!void {
        return stmt_mod.codegen_statements(self, stmts);
    }

    pub fn codegen_alloc_mem(self: *Codegen) !void {
        const ret_init = llvm.LLVMVoidTypeInContext(self.ctx);
        const func_type_init: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_init, null, 0, 0);
        const func_init: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, "bok_init", func_type_init);
        llvm.LLVMSetLinkage(func_init, llvm.LLVMExternalLinkage);

        const ret_deinit = llvm.LLVMVoidTypeInContext(self.ctx);
        const func_type_deinit: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_deinit, null, 0, 0);
        const func_deinit: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, "bok_deinit", func_type_deinit);
        llvm.LLVMSetLinkage(func_deinit, llvm.LLVMExternalLinkage);

        const ret_alloc = llvm.LLVMPointerTypeInContext(self.ctx, 0);
        var params_alloc: [1]llvm.LLVMTypeRef = .{llvm.LLVMInt64TypeInContext(self.ctx)};
        const func_type_alloc: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_alloc, @ptrCast(&params_alloc), 1, 0);
        const func_alloc: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, "bok_alloc", func_type_alloc);
        llvm.LLVMSetLinkage(func_alloc, llvm.LLVMExternalLinkage);
    }

    pub fn codegen(self: *Codegen) !llvm.LLVMModuleRef {
        if (!std.mem.eql(u8, self.compiler.opt.target, "wasm"))
            try self.codegen_alloc_mem();
        try self.codegen_program(self.compiler.ast.program);

        // verify module
        var err_msg: [*c]u8 = null;
        const v_ret = llvm.LLVMVerifyModule(self.mod, llvm.LLVMPrintMessageAction, &err_msg);
        if (v_ret != 0) {
            if (err_msg) |msg| {
                log.err("{s}\n", .{std.mem.span(msg)});
                llvm.LLVMDisposeMessage(msg);
                return Error.CodegenFail;
            }
        }

        // set the pass managers
        if (self.opt) {
            const options: llvm.LLVMPassBuilderOptionsRef = llvm.LLVMCreatePassBuilderOptions();
            _ = llvm.LLVMRunPasses(self.mod, "function(sroa,instcombine,simplifycfg)", null, options);
        }

        return self.mod;
    }

    pub fn codegen_program(self: *Codegen, program: ast.Program) !void {
        try self.codegen_items(program.items);
    }

    pub fn codegen_items(self: *Codegen, items: std.ArrayList(ast.Item)) !void {
        for (items.items) |*item| {
            switch (item.*) {
                .function => |*f| _ = try self.declare_function(f, f.name),
                .proc => |*p| _ = try self.declare_proc(p, p.name),
                .extern_def => |*e| try self.codegen_extern(e),
                .type_def => |*t| try self.codegen_typedef(t),
                .var_def => |*v| try self.codegen_global(v.name, v.type_ann, v.value),
                .const_def => |*c| try self.codegen_global(c.name, c.type_ann, c.value),
                else => {},
            }
        }

        for (items.items) |*item| {
            switch (item.*) {
                .function => |*f| try self.codegen_function(f, f.name),
                .proc => |*p| try self.codegen_proc(p, p.name),
                else => {},
            }
        }
    }

    pub fn codegen_typedef(self: *Codegen, t_def: *ast.TypeDef) !void {
        return switch (t_def.variant) {
            .struct_def => |*s| {
                try self.codegen_struct_def(s);
                try self.declare_methods(s);
                try self.codegen_methods(s);
            },
            .enum_def => |*e| try self.codegen_enum(e),
            else => {},
        };
    }

    pub fn codegen_struct_def(cg: *Codegen, s_def: *ast.StructDef) !void {
        const fields = try cg.allocator.alloc(llvm.LLVMTypeRef, s_def.fields.items.len);
        defer cg.allocator.free(fields);
        for (s_def.fields.items, 0..) |f, idx| {
            fields[idx] = try get_type(cg, f.type);
        }

        const s_ty = llvm.LLVMStructTypeInContext(cg.ctx, fields.ptr, @intCast(fields.len), 0);
        try cg.struct_types.put(s_def.name, s_ty);

        // TODO: the named struct is created but never used (struct_types holds the literal type)
        const name = try cg.cstr(s_def.name);
        defer cg.allocator.free(name);
        _ = llvm.LLVMStructCreateNamed(cg.ctx, name.ptr);
    }

    pub fn codegen_enum(cg: *Codegen, e_def: *ast.EnumDef) !void {
        // get the largest enum variant to allocate enough space
        // TODO: multiple type variant
        var l_width: usize = 0;
        for (e_def.variants.items, 0..) |*ev, i| {
            if (ev.types.items.len == 0) continue;

            const v_elems = try cg.allocator.alloc(llvm.LLVMTypeRef, ev.types.items.len + 1);
            defer cg.allocator.free(v_elems);
            // tagged variant with i8
            v_elems[0] = llvm.LLVMInt8TypeInContext(cg.ctx);
            for (ev.types.items, 1..) |t, idx| {
                const ty = try get_type(cg, t);
                const tar_data = llvm.LLVMGetModuleDataLayout(cg.mod);
                const w_ty = llvm.LLVMABISizeOfType(tar_data, ty);
                if (w_ty > l_width) l_width = w_ty;
                v_elems[idx] = ty;
            }

            // allocate for variant types
            const name = try cg.allocator.dupe(u8, ev.name);
            const v_ty = llvm.LLVMStructTypeInContext(cg.ctx, v_elems.ptr, @intCast(ev.types.items.len + 1), 0);
            try cg.enum_types.put(name, v_ty);
            try cg.enum_tag.put(name, i);
        }

        // c type simple enum
        if (l_width == 0) return;

        // allocate a range of bytes(i8), with alignment and padding
        const name = try cg.allocator.dupe(u8, e_def.name);
        const arr_ty = llvm.LLVMArrayType(llvm.LLVMInt8TypeInContext(cg.ctx), @intCast(l_width));
        var elems: [2]llvm.LLVMTypeRef = .{ llvm.LLVMInt8TypeInContext(cg.ctx), arr_ty };
        const e_ty = llvm.LLVMStructTypeInContext(cg.ctx, @ptrCast(&elems), 2, 0);
        log.debug("enum type registered: {s}", .{name});
        try cg.enum_types.put(name, e_ty);
    }

    fn codegen_global(self: *Codegen, name: []const u8, type_ann: ?*ast.Type, value: *ast.Expr) !void {
        const ty = if (type_ann) |a| try self.get_type(a) else try self.get_llvm_type_of(self.expr_type(value));
        const name_z = try self.cstr(name);
        defer self.allocator.free(name_z);
        const global = llvm.LLVMAddGlobal(self.mod, ty, name_z.ptr);

        const initializer: llvm.LLVMValueRef = switch (value.*) {
            .array_literal => |a_lit| blk: {
                const values = try self.allocator.alloc(llvm.LLVMValueRef, a_lit.elements.items.len);
                defer self.allocator.free(values);
                for (a_lit.elements.items, 0..) |ele, idx| {
                    values[idx] = try self.codegen_expression(ele);
                }
                break :blk llvm.LLVMConstArray(llvm.LLVMGetElementType(ty), values.ptr, @intCast(values.len));
            },
            .undefined => llvm.LLVMConstNull(ty),
            else => try self.codegen_expression(value),
        };
        llvm.LLVMSetInitializer(global, initializer);
        try self.global_map.put(name, global);
    }

    pub fn codegen_params(self: *Codegen, params: std.ArrayList(ast.Param)) ![]llvm.LLVMTypeRef {
        const p_types = try self.allocator.alloc(llvm.LLVMTypeRef, params.items.len);
        for (params.items, 0..) |param, idx| {
            p_types[idx] = try self.get_type(param.type);
        }
        return p_types;
    }

    // stack slot for a parameter
    fn codegen_alloca(self: *Codegen, p: ast.Param) !llvm.LLVMValueRef {
        const t = try self.get_type(p.type);
        const name = try self.cstr(p.name);
        defer self.allocator.free(name);
        return llvm.LLVMBuildAlloca(self.builder, t, name.ptr);
    }

    // adds a function to the module: the shared part of functions, procs and externs
    fn declare_callable(self: *Codegen, name: []const u8, params: std.ArrayList(ast.Param), ret_type: llvm.LLVMTypeRef, is_variadic: bool) !llvm.LLVMValueRef {
        const param_types = try self.codegen_params(params);
        defer self.allocator.free(param_types);
        const func_type = llvm.LLVMFunctionType(ret_type, param_types.ptr, @intCast(params.items.len), if (is_variadic) 1 else 0);

        const name_z = try self.cstr(name);
        defer self.allocator.free(name_z);
        const func = llvm.LLVMAddFunction(self.mod, name_z.ptr, func_type);

        // set function arg names
        for (params.items, 0..) |p, idx| {
            const arg = llvm.LLVMGetParam(func, @intCast(idx));
            llvm.LLVMSetValueName2(arg, @ptrCast(p.name), p.name.len);
        }
        return func;
    }

    fn declare_function(self: *Codegen, f: *ast.FunctionDef, name: []const u8) !llvm.LLVMValueRef {
        return self.declare_callable(name, f.params, try self.get_type(f.result), false);
    }

    fn declare_proc(self: *Codegen, p: *ast.ProcDef, name: []const u8) !llvm.LLVMValueRef {
        return self.declare_callable(name, p.params, llvm.LLVMVoidTypeInContext(self.ctx), false);
    }

    // the body of an already declared function / proc
    fn codegen_callable_body(self: *Codegen, name: []const u8, params: std.ArrayList(ast.Param), body: std.ArrayList(ast.Stmt), comptime is_proc: bool) !void {
        const name_z = try self.cstr(name);
        defer self.allocator.free(name_z);
        const func = llvm.LLVMGetNamedFunction(self.mod, name_z.ptr) orelse return error.FunctionNotDeclared;

        self.entry = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, self.entry);

        // store params on stack
        self.stack_map.clearRetainingCapacity();
        for (params.items, 0..) |p, idx| {
            const alloca = try self.codegen_alloca(p);
            const arg = llvm.LLVMGetParam(func, @intCast(idx));
            _ = llvm.LLVMBuildStore(self.builder, arg, alloca);
            try self.stack_map.put(p.name, alloca);
        }

        self.emit_runtime_init();
        try self.codegen_statements(body);

        // terminates the block: a proc ends with a void return
        const cur_bb = llvm.LLVMGetInsertBlock(self.builder);
        if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
            _ = if (is_proc) llvm.LLVMBuildRetVoid(self.builder) else llvm.LLVMBuildUnreachable(self.builder);
        }
    }

    fn emit_runtime_init(self: *Codegen) void {
        if (std.mem.eql(u8, self.compiler.opt.target, "wasm")) return;
        const init_fn = llvm.LLVMGetNamedFunction(self.mod, "bok_init");
        const init_type = llvm.LLVMGlobalGetValueType(init_fn);
        _ = llvm.LLVMBuildCall2(self.builder, init_type, init_fn, null, 0, "");
    }

    pub fn codegen_function(self: *Codegen, f: *ast.FunctionDef, name: []const u8) !void {
        try self.codegen_callable_body(name, f.params, f.body, false);
    }

    pub fn codegen_proc(self: *Codegen, p: *ast.ProcDef, name: []const u8) !void {
        try self.codegen_callable_body(name, p.params, p.body, true);
    }

    pub fn codegen_extern(self: *Codegen, e: *ast.ExternDef) !void {
        const func = switch (e.kind) {
            .func => |f| try self.declare_callable(f.name, f.params, try self.get_type(f.result), f.is_variadic),
            .proc => |p| try self.declare_callable(p.name, p.params, llvm.LLVMVoidTypeInContext(self.ctx), p.is_variadic),
        };
        llvm.LLVMSetLinkage(func, llvm.LLVMExternalLinkage);
    }

    pub fn declare_methods(self: *Codegen, s_def: *ast.StructDef) !void {
        for (s_def.methods.items) |*m| switch (m.*) {
            .func => |*f| _ = try self.declare_function(f, try self.compiler.sema.qualify(s_def.name, f.name)),
            .proc => |*p| _ = try self.declare_proc(p, try self.compiler.sema.qualify(s_def.name, p.name)),
        };
    }

    pub fn codegen_methods(self: *Codegen, s_def: *ast.StructDef) !void {
        for (s_def.methods.items) |*m| switch (m.*) {
            .func => |*f| try self.codegen_function(f, try self.compiler.sema.qualify(s_def.name, f.name)),
            .proc => |*p| try self.codegen_proc(p, try self.compiler.sema.qualify(s_def.name, p.name)),
        };
    }
};
