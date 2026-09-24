const std = @import("std");
const llvm = @import("llvm");
const compiler = @import("compiler.zig");
const ast = @import("ast.zig");
const token = @import("token.zig");
const types = @import("sema/type_system.zig");

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

    pub fn init(allocator: std.mem.Allocator, c: *compiler.Compiler) !Codegen {
        // initialize target machine and code emission
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
        } else {
            log.err("{s} target is not currently supported\n", .{c.opt.target});
            return Error.CodegenFail;
        }

        const g_ctx = llvm.LLVMContextCreate();
        var c_gen = Codegen{
            .allocator = allocator,
            .compiler = c,
            .tm = undefined,
            .triple = llvm.LLVMGetDefaultTargetTriple(),
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
    }

    pub fn codegen_alloc_mem(self: *Codegen) !void {
        const ret_init = llvm.LLVMVoidTypeInContext(self.ctx);
        const func_type_init: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_init, null, 0, 0);
        const name_init = try self.allocator.dupeZ(u8, "bok_init");
        defer self.allocator.free(name_init);
        const func_init: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, name_init.ptr, func_type_init);
        llvm.LLVMSetLinkage(func_init, llvm.LLVMExternalLinkage);

        const ret_deinit = llvm.LLVMVoidTypeInContext(self.ctx);
        const func_type_deinit: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_deinit, null, 0, 0);
        const name_deinit = try self.allocator.dupeZ(u8, "bok_deinit");
        defer self.allocator.free(name_deinit);
        const func_deinit: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, name_deinit.ptr, func_type_deinit);
        llvm.LLVMSetLinkage(func_deinit, llvm.LLVMExternalLinkage);

        const ret_alloc = llvm.LLVMPointerTypeInContext(self.ctx, 0);
        var params_alloc: [1]llvm.LLVMTypeRef = .{llvm.LLVMInt64TypeInContext(self.ctx)};
        const func_type_alloc: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_alloc, @ptrCast(&params_alloc), 1, 0);
        const name_alloc = try self.allocator.dupeZ(u8, "bok_alloc");
        defer self.allocator.free(name_alloc);
        const func_alloc: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, name_alloc.ptr, func_type_alloc);
        llvm.LLVMSetLinkage(func_alloc, llvm.LLVMExternalLinkage);
    }

    pub fn codegen(self: *Codegen) !llvm.LLVMModuleRef {
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
                .function => |*f| try self.codegen_function(f),
                .proc => |*p| try self.codegen_proc(p),
                .extern_def => |*e| try self.codegen_extern(e),
                .type_def => |*t| try self.codegen_typedef(t),
                .var_def => |*v| try self.codegen_var_def(v),
                .const_def => |*c| try self.codegen_const_def(c),
                else => {
                    // TODO:
                },
            }
        }
    }

    pub fn codegen_var_def(self: *Codegen, v: *ast.VarDef) !void {
        const ty = if (v.type_ann) |a|
            try self.get_type(a)
        else
            try self.get_llvm_type_of(self.expr_type(v.value));

        const name = try self.allocator.dupeZ(u8, v.name);
        defer self.allocator.free(name);

        const global = llvm.LLVMAddGlobal(self.mod, ty, name.ptr);

        const init_val = try self.codegen_expression(v.value);
        llvm.LLVMSetInitializer(global, init_val);
        try self.global_map.put(v.name, global);
    }

    pub fn codegen_const_def(self: *Codegen, c: *ast.ConstDef) !void {
        const ty = if (c.type_ann) |a|
            try self.get_type(a)
        else
            try self.get_llvm_type_of(self.expr_type(c.value));

        const name = try self.allocator.dupeZ(u8, c.name);
        defer self.allocator.free(name);

        const global = llvm.LLVMAddGlobal(self.mod, ty, name.ptr);

        const init_val = try self.codegen_expression(c.value);
        llvm.LLVMSetInitializer(global, init_val);
        llvm.LLVMSetGlobalConstant(global, 1);
        try self.global_map.put(c.name, global);
    }

    pub fn codegen_function(self: *Codegen, function: *ast.FunctionDef) !void {
        const ret_type = try self.get_type(function.result);
        const params = try self.codegen_params(function.params);
        defer self.allocator.free(params);
        const params_len: c_uint = @intCast(function.params.items.len);
        const func_type: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_type, params.ptr, params_len, 0);
        const name = try self.allocator.dupeZ(u8, function.name);
        defer self.allocator.free(name);
        const main_func: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, name.ptr, func_type);
        if (main_func != null) {
            // log.debug("add function {s} to module\n", .{name});
        } // set function arg names
        for (function.params.items, 0..) |p, idx| {
            const arg = llvm.LLVMGetParam(main_func, @intCast(idx));
            llvm.LLVMSetValueName2(arg, @ptrCast(p.name), p.name.len);
        }

        self.entry = llvm.LLVMAppendBasicBlockInContext(self.ctx, main_func, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, self.entry);

        // store params on stack
        self.stack_map.clearRetainingCapacity();
        for (function.params.items, 0..) |p, idx| {
            // allocate the space on stack
            const alloca = try self.codegen_alloca(p);
            const arg = llvm.LLVMGetParam(main_func, @intCast(idx));
            // store value on stack space
            _ = llvm.LLVMBuildStore(self.builder, arg, alloca);
            try self.stack_map.put(p.name, alloca);
        }

        const bok_init_fn = llvm.LLVMGetNamedFunction(self.mod, "bok_init");
        const bok_init_type = llvm.LLVMGlobalGetValueType(bok_init_fn);
        _ = llvm.LLVMBuildCall2(
            self.builder,
            bok_init_type,
            bok_init_fn,
            null,
            0,
            "",
        );

        _ = try self.codegen_statements(function.body);

        // terminates the block.
        const cur_bb = llvm.LLVMGetInsertBlock(self.builder);
        if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
            _ = llvm.LLVMBuildUnreachable(self.builder);
        }
    }

    pub fn codegen_proc(self: *Codegen, proc: *ast.ProcDef) !void {
        const ret_type = llvm.LLVMVoidTypeInContext(self.ctx);
        const params = try self.codegen_params(proc.params);
        defer self.allocator.free(params);
        const params_len: c_uint = @intCast(proc.params.items.len);
        const func_type: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_type, params.ptr, params_len, 0);
        const name = try self.allocator.dupeZ(u8, proc.name);
        defer self.allocator.free(name);
        const main_func: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, name.ptr, func_type);
        if (main_func != null) {
            // log.debug("add proc {s} to module\n", .{name});
        }

        // set function arg names
        for (proc.params.items, 0..) |p, idx| {
            const arg = llvm.LLVMGetParam(main_func, @intCast(idx));
            llvm.LLVMSetValueName2(arg, @ptrCast(p.name), p.name.len);
        }

        self.entry = llvm.LLVMAppendBasicBlockInContext(self.ctx, main_func, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, self.entry);

        // store params on stack
        self.stack_map.clearRetainingCapacity();
        for (proc.params.items, 0..) |p, idx| {
            // allocate the space on stack
            const alloca = try self.codegen_alloca(p);
            const arg = llvm.LLVMGetParam(main_func, @intCast(idx));
            // store value on stack space
            _ = llvm.LLVMBuildStore(self.builder, arg, alloca);
            try self.stack_map.put(p.name, alloca);
        }

        const bok_init_fn = llvm.LLVMGetNamedFunction(self.mod, "bok_init");
        const bok_init_type = llvm.LLVMGlobalGetValueType(bok_init_fn);
        _ = llvm.LLVMBuildCall2(
            self.builder,
            bok_init_type,
            bok_init_fn,
            null,
            0,
            "",
        );

        _ = try self.codegen_statements(proc.body);

        // end proc with void return
        const cur_bb = llvm.LLVMGetInsertBlock(self.builder);
        if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
            _ = llvm.LLVMBuildRetVoid(self.builder);
        }
    }

    pub fn codegen_extern(self: *Codegen, e_def: *ast.ExternDef) !void {
        switch (e_def.kind) {
            .func => try self.codegen_extern_func(e_def),
            .proc => try self.codegen_extern_proc(e_def),
        }
    }

    pub fn codegen_extern_func(self: *Codegen, e: *ast.ExternDef) !void {
        const ret_type = try self.get_type(e.kind.func.result);
        const params = try self.codegen_params(e.kind.func.params);
        defer self.allocator.free(params);
        const params_len: c_uint = @intCast(e.kind.func.params.items.len);
        const is_vararg: c_int = if (e.kind.func.is_variadic) 1 else 0;
        const func_type: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_type, params.ptr, params_len, is_vararg);
        const name = try self.allocator.dupeZ(u8, e.kind.func.name);
        defer self.allocator.free(name);
        const func: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, name.ptr, func_type);
        llvm.LLVMSetLinkage(func, llvm.LLVMExternalLinkage);
        if (func != null) {
            // log.debug("add extern {s} to module\n", .{name});
        }

        // set function arg names
        for (e.kind.func.params.items, 0..) |p, idx| {
            const arg = llvm.LLVMGetParam(func, @intCast(idx));
            llvm.LLVMSetValueName2(arg, @ptrCast(p.name), p.name.len);
        }
    }

    pub fn codegen_extern_proc(self: *Codegen, e: *ast.ExternDef) !void {
        const ret_type = llvm.LLVMVoidTypeInContext(self.ctx);
        const params = try self.codegen_params(e.kind.proc.params);
        defer self.allocator.free(params);
        const params_len: c_uint = @intCast(e.kind.proc.params.items.len);
        const is_vararg: c_int = if (e.kind.proc.is_variadic) 1 else 0;
        const func_type: llvm.LLVMTypeRef = llvm.LLVMFunctionType(ret_type, params.ptr, params_len, is_vararg);
        const name = try self.allocator.dupeZ(u8, e.kind.proc.name);
        defer self.allocator.free(name);
        const func: llvm.LLVMValueRef = llvm.LLVMAddFunction(self.mod, name.ptr, func_type);
        llvm.LLVMSetLinkage(func, llvm.LLVMExternalLinkage);
        if (func != null) {
            // log.debug("add extern {s} to module\n", .{name});
        }

        // set function arg names
        for (e.kind.proc.params.items, 0..) |p, idx| {
            const arg = llvm.LLVMGetParam(func, @intCast(idx));
            llvm.LLVMSetValueName2(arg, @ptrCast(p.name), p.name.len);
        }
    }

    pub fn codegen_typedef(self: *Codegen, t_def: *ast.TypeDef) !void {
        switch (t_def.*.variant) {
            .struct_def => |*s| try self.codegen_struct_def(s),
            .enum_def => unreachable,
            .alias => {},
        }
    }

    pub fn codegen_struct_def(self: *Codegen, s_def: *ast.StructDef) !void {
        const fields = try self.allocator.alloc(llvm.LLVMTypeRef, s_def.fields.items.len);
        defer self.allocator.free(fields);
        for (s_def.fields.items, 0..) |f, idx| {
            const t = try self.get_type(f.type);
            fields[idx] = t;
        }

        const name = try self.allocator.dupeZ(u8, s_def.name);
        defer self.allocator.free(name);
        const s_ty = llvm.LLVMStructTypeInContext(
            self.ctx,
            fields.ptr,
            @intCast(s_def.fields.items.len),
            0,
        );
        try self.struct_types.put(s_def.name, s_ty);
        _ = llvm.LLVMStructCreateNamed(self.ctx, name);
    }

    pub fn codegen_statements(self: *Codegen, stmts: std.ArrayList(ast.Stmt)) !llvm.LLVMValueRef {
        var last_value: llvm.LLVMValueRef = undefined;
        for (stmts.items) |*stmt| {
            last_value = switch (stmt.*) {
                .return_stmt => |*r| try self.codegen_return(r),
                .expr_stmt => |*e| try self.codegen_expression_statement(e),
                .var_stmt => |*v| try self.codegen_var(v),
                .const_stmt => |*c| try self.codegen_const(c),
                .assign_stmt => |*a| try self.codegen_assign(a),
                .control_flow_stmt => |*c| try self.codegen_control_flow(c),
                .break_stmt => try self.codegen_break_stmt(),
                .continue_stmt => try self.codegen_continue_stmt(),
                else => {
                    // TODO:
                    unreachable;
                },
            };
        }

        return last_value;
    }

    fn codegen_continue_stmt(self: *Codegen) !llvm.LLVMValueRef {
        const target = self.continue_targets.getLast();
        return llvm.LLVMBuildBr(self.builder, target);
    }

    pub fn codegen_break_stmt(self: *Codegen) !llvm.LLVMValueRef {
        const target = self.break_targets.getLast();
        return llvm.LLVMBuildBr(self.builder, target);
    }

    pub fn codegen_array(self: *Codegen, a: *ast.ArrayLiteralExpr, e: *ast.Expr) anyerror!llvm.LLVMValueRef {
        const array_ty = try self.get_llvm_type_of(self.expr_type(e));
        const arr = llvm.LLVMBuildAlloca(self.builder, array_ty, "");
        var indices = [2]llvm.LLVMValueRef{
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
        };

        for (a.elements.items, 0..) |ele, idx| {
            indices[1] = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), idx, 0);
            const value = try self.codegen_expression(ele);
            const gep = llvm.LLVMBuildGEPWithNoWrapFlags(
                self.builder,
                array_ty,
                arr,
                &indices,
                2,
                "",
                0,
            );

            _ = llvm.LLVMBuildStore(self.builder, value, gep);
        }
        return arr;
    }

    pub fn codegen_control_flow(self: *Codegen, cf: *ast.ControlFlowStmt) anyerror!llvm.LLVMValueRef {
        switch (cf.*) {
            .if_expr => |*i| return try self.codegen_if(i),
            .while_expr => |*w| return try self.codegen_while(w),
            .for_expr => |*f| return try self.codegen_for(f),
            else => {
                // TODO:
                unreachable;
            },
        }
    }

    pub fn codegen_while(self: *Codegen, w: *ast.WhileExpr) !llvm.LLVMValueRef {
        // jmp to while condition block
        const func = llvm.LLVMGetBasicBlockParent(self.entry);

        const cond_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");
        const while_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");
        const merge_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");

        _ = llvm.LLVMBuildBr(self.builder, cond_bb);
        llvm.LLVMPositionBuilderAtEnd(self.builder, cond_bb);

        const cond = try self.codegen_expression(w.cond);
        _ = llvm.LLVMBuildCondBr(self.builder, cond, while_bb, merge_bb);

        // reset the insert pos
        llvm.LLVMPositionBuilderAtEnd(self.builder, while_bb);
        try self.break_targets.append(self.allocator, merge_bb);
        try self.continue_targets.append(self.allocator, cond_bb);
        const while_val = try self.codegen_statements(w.body);
        _ = self.break_targets.pop();
        _ = self.continue_targets.pop();
        _ = llvm.LLVMBuildBr(self.builder, cond_bb);

        // reset the insert pos
        llvm.LLVMPositionBuilderAtEnd(self.builder, merge_bb);

        return while_val;
    }

    pub fn codegen_if(self: *Codegen, i: *ast.IfExpr) !llvm.LLVMValueRef {
        // get the parent function for block insertion
        const func = llvm.LLVMGetBasicBlockParent(self.entry);
        const then_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");

        const elif_bbs = try self.allocator.alloc(llvm.LLVMBasicBlockRef, i.elifs.items.len);
        defer self.allocator.free(elif_bbs);
        const elif_then_bbs = try self.allocator.alloc(llvm.LLVMBasicBlockRef, i.elifs.items.len);
        defer self.allocator.free(elif_then_bbs);
        for (elif_bbs, 0..) |*bb, idx| {
            bb.* = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");
            elif_then_bbs[idx] = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");
        }

        const else_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");
        const merge_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "");

        const first_false_bb = if (elif_bbs.len > 0) elif_bbs[0] else else_bb;
        const cond = try self.codegen_expression(i.cond);
        _ = llvm.LLVMBuildCondBr(self.builder, cond, then_bb, first_false_bb);

        // set new insert point for then_bb codegen
        llvm.LLVMPositionBuilderAtEnd(self.builder, then_bb);
        _ = try self.codegen_statements(i.then_body);
        if (llvm.LLVMGetBasicBlockTerminator(then_bb) == null) {
            _ = llvm.LLVMBuildBr(self.builder, merge_bb);
        }

        for (i.elifs.items, 0..) |*elif, idx| {
            llvm.LLVMPositionBuilderAtEnd(self.builder, elif_bbs[idx]);
            const elif_cond = try self.codegen_expression(elif.cond);
            const nxt = if (idx + 1 < elif_bbs.len) elif_bbs[idx + 1] else else_bb;
            _ = llvm.LLVMBuildCondBr(self.builder, elif_cond, elif_then_bbs[idx], nxt);

            llvm.LLVMPositionBuilderAtEnd(self.builder, elif_then_bbs[idx]);
            _ = try self.codegen_statements(elif.body);
            if (llvm.LLVMGetBasicBlockTerminator(elif_then_bbs[idx]) == null) {
                _ = llvm.LLVMBuildBr(self.builder, merge_bb);
            }
        }

        // set new insert point for else_bb codegen
        llvm.LLVMPositionBuilderAtEnd(self.builder, else_bb);
        if (i.else_body) |*body| {
            _ = try self.codegen_statements(body.*);
        }

        if (llvm.LLVMGetBasicBlockTerminator(else_bb) == null) {
            _ = llvm.LLVMBuildBr(self.builder, merge_bb);
        }

        // codegen merge block
        llvm.LLVMPositionBuilderAtEnd(self.builder, merge_bb);

        return null;
    }

    pub fn codegen_array_iter(self: *Codegen, f: *ast.ForExpr, ty: types.TypeId, len: u64) !llvm.LLVMValueRef {
        const llvm_ty = try self.get_llvm_type_of(ty);
        const array_ptr = switch (f.iterable.*) {
            .ident => |ident| self.stack_map.get(ident.name) orelse {
                return error.UnknownVariable;
            },
            else => return error.UnsupportedArrayTarget,
        };

        const l = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), len, 0);

        const func = llvm.LLVMGetBasicBlockParent(self.entry);
        const cond_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "for_cond");
        const body_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "for_body");
        const merge_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "for_merge");

        // index variable.
        const index_alloca = llvm.LLVMBuildAlloca(self.builder, llvm.LLVMInt64TypeInContext(self.ctx), "for_index");
        _ = llvm.LLVMBuildStore(
            self.builder,
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
            index_alloca,
        );

        const name = try self.allocator.dupeZ(u8, f.binding);
        defer self.allocator.free(name);
        const i_alloca = llvm.LLVMBuildAlloca(self.builder, llvm_ty, name);
        const e_alloca = try self.enumerate_setup(f);
        try self.stack_map.put(f.binding, i_alloca);

        _ = llvm.LLVMBuildBr(self.builder, cond_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, cond_bb);

        const index = llvm.LLVMBuildLoad2(self.builder, llvm.LLVMInt64TypeInContext(self.ctx), index_alloca, "index");
        const cond = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULT, index, l, "for_cmp");
        _ = llvm.LLVMBuildCondBr(self.builder, cond, body_bb, merge_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, body_bb);

        var indices = [2]llvm.LLVMValueRef{
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
            index,
        };

        const gep = llvm.LLVMBuildGEPWithNoWrapFlags(
            self.builder,
            llvm.LLVMArrayType2(llvm_ty, len),
            array_ptr,
            &indices,
            2,
            "",
            0,
        );

        const ele = llvm.LLVMBuildLoad2(self.builder, llvm_ty, gep, "ele");
        _ = llvm.LLVMBuildStore(self.builder, ele, i_alloca);

        try self.break_targets.append(self.allocator, merge_bb);
        try self.continue_targets.append(self.allocator, cond_bb);
        _ = try self.codegen_statements(f.body);
        _ = self.break_targets.pop();
        _ = self.continue_targets.pop();

        // i = i + 1
        const curr = llvm.LLVMBuildLoad2(self.builder, llvm.LLVMInt64TypeInContext(self.ctx), index_alloca, "index");
        const next = llvm.LLVMBuildAdd(
            self.builder,
            curr,
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 1, 0),
            "for_inc",
        );
        _ = llvm.LLVMBuildStore(self.builder, next, index_alloca);
        self.enumerate_increment(e_alloca);
        _ = llvm.LLVMBuildBr(self.builder, cond_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, merge_bb);

        return i_alloca;
    }

    pub fn codegen_for_range(self: *Codegen, f: *ast.ForExpr, ty: types.TypeId) !llvm.LLVMValueRef {
        const llvm_ty = try self.get_llvm_type_of(ty);

        const b = &f.iterable.binary;
        var lo = try self.codegen_expression(b.lhs);
        var hi = try self.codegen_expression(b.rhs);

        lo = try self.coerce_numeric(lo, self.expr_type(b.lhs), ty);
        hi = try self.coerce_numeric(hi, self.expr_type(b.rhs), ty);

        const func = llvm.LLVMGetBasicBlockParent(self.entry);
        const cond_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "for_cond");
        const body_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "for_body");
        const merge_bb = llvm.LLVMAppendBasicBlockInContext(self.ctx, func, "for_merge");

        const name = try self.allocator.dupeZ(u8, f.binding);
        defer self.allocator.free(name);
        const i_alloca = llvm.LLVMBuildAlloca(self.builder, llvm_ty, name);
        const e_alloca = try self.enumerate_setup(f);
        _ = llvm.LLVMBuildStore(self.builder, lo, i_alloca);
        try self.stack_map.put(f.binding, i_alloca);

        _ = llvm.LLVMBuildBr(self.builder, cond_bb);
        llvm.LLVMPositionBuilderAtEnd(self.builder, cond_bb);

        const is_float = self.is_float_type(ty);
        const is_signed = switch (self.compiler.sema.types.get(ty).*) {
            .primitive => |p| switch (p) {
                .i8, .i16, .i32, .i64, .isize => true,
                else => false,
            },
            else => false,
        };
        const isincl = b.op == .range_incl; // the range is inclusize (..=)
        const i_val = llvm.LLVMBuildLoad2(self.builder, llvm_ty, i_alloca, "");
        const cond = if (is_float)
            llvm.LLVMBuildFCmp(self.builder, if (isincl) llvm.LLVMRealOLE else llvm.LLVMRealOLT, i_val, hi, "for_cmp")
        else
            llvm.LLVMBuildICmp(self.builder, if (is_signed)
                (if (isincl) llvm.LLVMIntSLE else llvm.LLVMIntSLT)
            else
                (if (isincl) llvm.LLVMIntULE else llvm.LLVMIntULT), i_val, hi, "for_cmp");

        _ = llvm.LLVMBuildCondBr(self.builder, cond, body_bb, merge_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        try self.break_targets.append(self.allocator, merge_bb);
        try self.continue_targets.append(self.allocator, cond_bb);
        _ = try self.codegen_statements(f.body);
        _ = self.break_targets.pop();
        _ = self.continue_targets.pop();

        // do the i = i + 1
        const cur = llvm.LLVMBuildLoad2(self.builder, llvm_ty, i_alloca, "");
        const one = if (is_float) llvm.LLVMConstReal(llvm_ty, 1.0) else llvm.LLVMConstInt(llvm_ty, 1, 0);
        const next = if (is_float) llvm.LLVMBuildFAdd(self.builder, cur, one, "for_inc") else llvm.LLVMBuildAdd(self.builder, cur, one, "for_inc");
        _ = llvm.LLVMBuildStore(self.builder, next, i_alloca);
        self.enumerate_increment(e_alloca);
        _ = llvm.LLVMBuildBr(self.builder, cond_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        return i_alloca;
    }

    pub fn codegen_for(self: *Codegen, f: *ast.ForExpr) !llvm.LLVMValueRef {
        // todo: slices based iterations
        const iter_ty = self.expr_type(f.iterable);
        return switch (self.compiler.sema.types.get(iter_ty).*) {
            .range => |r| try self.codegen_for_range(f, r.elem),
            .array => |a| try self.codegen_array_iter(f, a.child, a.len),
            else => unreachable, // sema sambhal lega
        };
    }

    fn is_signed_type(self: *Codegen, ty: types.TypeId) bool {
        return switch (self.compiler.sema.types.get(ty).*) {
            .primitive => |p| switch (p) {
                .i8, .i16, .i32, .i64, .isize => true,
                .u8, .u16, .u32, .u64, .usize => false,
                else => false,
            },
            else => false,
        };
    }

    fn is_float_type(self: *Codegen, ty: types.TypeId) bool {
        return switch (self.compiler.sema.types.get(ty).*) {
            .primitive => |p| p == .f32 or p == .f64,
            else => false,
        };
    }

    fn coerce_numeric(self: *Codegen, val: llvm.LLVMValueRef, from: types.TypeId, to: types.TypeId) !llvm.LLVMValueRef {
        if (from == .invalid or to == .invalid or from == to) return val;
        const llvm_ty = try self.get_llvm_type_of(to);
        if (llvm.LLVMTypeOf(val) == llvm_ty) return val; // for like isize and i64 or usize and u64

        const from_is_float = self.is_float_type(from);
        const to_is_float = self.is_float_type(to);

        if (from_is_float and to_is_float) return llvm.LLVMBuildFPExt(self.builder, val, llvm_ty, "fpext");
        if (!from_is_float and to_is_float) {
            return if (self.is_signed_type(from)) llvm.LLVMBuildSIToFP(self.builder, val, llvm_ty, "sitofp") else llvm.LLVMBuildUIToFP(self.builder, val, llvm_ty, "uitofp");
        }
        if (!from_is_float and !to_is_float) {
            return if (self.is_signed_type(from)) llvm.LLVMBuildSExt(self.builder, val, llvm_ty, "sext") else llvm.LLVMBuildZExt(self.builder, val, llvm_ty, "zext");
        }
        return val;
    }

    // for allocating the binding
    fn enumerate_setup(self: *Codegen, f: *ast.ForExpr) !?llvm.LLVMValueRef {
        const ib = f.index_binding orelse return null;
        const start_ty = try self.get_llvm_type_of(self.expr_type(f.index_start.?));
        const start_val = try self.codegen_expression(f.index_start.?);
        const alloca = llvm.LLVMBuildAlloca(self.builder, start_ty, "");
        _ = llvm.LLVMBuildStore(self.builder, start_val, alloca);
        try self.stack_map.put(ib, alloca);
        return alloca;
    }

    // for incrementing through range
    fn enumerate_increment(self: *Codegen, enum_alloca: ?llvm.LLVMValueRef) void {
        const alloca = enum_alloca orelse return;
        const ty = llvm.LLVMGetAllocatedType(alloca);
        const cur = llvm.LLVMBuildLoad2(self.builder, ty, alloca, "");
        const next = llvm.LLVMBuildAdd(self.builder, cur, llvm.LLVMConstInt(ty, 1, 0), "enum_inc");
        _ = llvm.LLVMBuildStore(self.builder, next, alloca);
    }

    pub fn codegen_assign(self: *Codegen, a: *ast.AssignStmt) !llvm.LLVMValueRef {
        // NOTE: currently only for var assign
        switch (a.target.*) {
            .ident => |*i| {
                const ty = self.expr_type(a.target);
                const llvm_ty = try self.get_llvm_type_of(ty);
                var e = try self.codegen_expression_with_type(a.value, llvm_ty);
                if (std.mem.eql(u8, i.name, "_")) {
                    return e; // return if assigning in '_' (it is discard mf)
                }
                // lookup for var on stack
                var ptr = self.stack_map.get(i.name) orelse self.global_map.get(i.name) orelse return error.VariableNotFound;
                if (a.op == null) {
                    // check for undefined array updation
                    if (self.compiler.sema.types.get(ty).* == .array) {
                        try self.stack_map.put(i.name, e);
                        ptr = self.stack_map.get(i.name) orelse self.global_map.get(i.name) orelse return error.VariableNotFound;
                        return ptr;
                    }
                    e = try self.coerce_numeric(e, self.expr_type(a.value), ty);
                    _ = llvm.LLVMBuildStore(self.builder, e, ptr);
                    return ptr;
                } else {
                    const target_ty = self.expr_type(a.target);
                    const llvm_target_ty = try self.get_llvm_type_of(target_ty);
                    const old = llvm.LLVMBuildLoad2(self.builder, llvm_target_ty, ptr, "");
                    const is_signed = self.is_signed_type(target_ty);
                    e = try self.coerce_numeric(e, self.expr_type(a.value), ty);
                    const result = try self.codegen_compound_op(a.op.?, old, e, is_signed);
                    _ = llvm.LLVMBuildStore(self.builder, result, ptr);
                    return ptr;
                }
            },
            .index => |*i| {
                var e = try self.codegen_expression_with_type(a.value, null);
                const e_ptr = try self.codegen_array_element_ptr(i);
                const elem_ty = self.expr_type(a.target);
                e = try self.coerce_numeric(e, self.expr_type(a.value), elem_ty);
                if (a.op == null) {
                    _ = llvm.LLVMBuildStore(self.builder, e, e_ptr);
                    return e_ptr;
                } else {
                    const llvm_elem_ty = try self.get_llvm_type_of(elem_ty);
                    const old = llvm.LLVMBuildLoad2(self.builder, llvm_elem_ty, e_ptr, "");
                    const is_signed = self.is_signed_type(elem_ty);
                    const result = try self.codegen_compound_op(a.op.?, old, e, is_signed);
                    _ = llvm.LLVMBuildStore(self.builder, result, e_ptr);
                    return e_ptr;
                }
            },
            .field_access => |*f| {
                var e = try self.codegen_expression_with_type(a.value, null);
                const f_ptr = try self.codegen_field_access(f, true);
                const elem_ty = self.expr_type(a.target);
                e = try self.coerce_numeric(e, self.expr_type(a.value), elem_ty);
                if (a.op == null) {
                    _ = llvm.LLVMBuildStore(self.builder, e, f_ptr);
                    return f_ptr;
                } else {
                    const llvm_elem_ty = try self.get_llvm_type_of(elem_ty);
                    const old = llvm.LLVMBuildLoad2(self.builder, llvm_elem_ty, f_ptr, "");
                    const is_signed = self.is_signed_type(elem_ty);
                    const result = try self.codegen_compound_op(a.op.?, old, e, is_signed);
                    _ = llvm.LLVMBuildStore(self.builder, result, f_ptr);
                    return f_ptr;
                }
            },
            else => {
                // TODO:
                return null;
                // unreachable;
            },
        }
    }

    pub fn codegen_var(self: *Codegen, v: *ast.VarStmt) !llvm.LLVMValueRef {
        switch (v.value.*) {
            .array_literal => {
                const arr = try self.codegen_expression(v.value);
                try self.stack_map.put(v.name, arr);
                return arr;
            },
            .struct_literal => {
                const alloca = try self.codegen_alloca_var(v);
                if (v.value.* == .undefined) {
                    try self.stack_map.put(v.name, alloca);
                    return alloca;
                }
                const expected_ty = if (v.type_ann) |ty| try self.get_type(ty) else null;
                const s = try self.codegen_expression_with_type(v.value, expected_ty);
                _ = llvm.LLVMBuildStore(self.builder, s, alloca);
                try self.stack_map.put(v.name, alloca);
                return s;
            },
            else => {
                const alloca = try self.codegen_alloca_var(v);
                if (v.value.* == .undefined) {
                    try self.stack_map.put(v.name, alloca);
                    return alloca;
                }
                var e = try self.codegen_expression(v.value);
                if (v.type_ann) |ann| {
                    if (ann.base == .primitive) {
                        const target_ty = try self.compiler.sema.types.from_ast_primitive(ann.base.primitive);
                        e = try self.coerce_numeric(e, self.expr_type(v.value), target_ty);
                    }
                }
                // store value on stack space
                _ = llvm.LLVMBuildStore(self.builder, e, alloca);
                try self.stack_map.put(v.name, alloca);
                return e;
            },
        }
    }

    pub fn codegen_const(self: *Codegen, v: *ast.ConstStmt) !llvm.LLVMValueRef {
        switch (v.value.*) {
            .array_literal => {
                const arr = try self.codegen_expression(v.value);
                try self.stack_map.put(v.name, arr);
                return arr;
            },
            .struct_literal => {
                const alloca = try self.codegen_alloca_const(v);
                if (v.value.* == .undefined) {
                    try self.stack_map.put(v.name, alloca);
                    return alloca;
                }
                const expected_ty = if (v.type_ann) |ty| try self.get_type(ty) else null;
                const s = try self.codegen_expression_with_type(v.value, expected_ty);
                _ = llvm.LLVMBuildStore(self.builder, s, alloca);
                try self.stack_map.put(v.name, alloca);
                return s;
            },
            else => {
                const alloca = try self.codegen_alloca_const(v);
                if (v.value.* == .undefined) {
                    try self.stack_map.put(v.name, alloca);
                    return alloca;
                }
                var e = try self.codegen_expression(v.value);
                if (v.type_ann) |ann| {
                    if (ann.base == .primitive) {
                        const target_ty = try self.compiler.sema.types.from_ast_primitive(ann.base.primitive);
                        e = try self.coerce_numeric(e, self.expr_type(v.value), target_ty);
                    }
                }
                // store value on stack space
                _ = llvm.LLVMBuildStore(self.builder, e, alloca);
                try self.stack_map.put(v.name, alloca);
                return e;
            },
        }
    }

    pub fn codegen_alloca_var(self: *Codegen, v: *ast.VarStmt) !llvm.LLVMValueRef {
        const t = if (v.type_ann) |ann| try self.get_type(ann) else try self.get_llvm_type_of(self.expr_type(v.value));
        const name = try self.allocator.dupeZ(u8, v.name);
        defer self.allocator.free(name);
        return llvm.LLVMBuildAlloca(self.builder, t, name);
    }

    pub fn codegen_alloca_const(self: *Codegen, v: *ast.ConstStmt) !llvm.LLVMValueRef {
        const t = if (v.type_ann) |ann| try self.get_type(ann) else try self.get_llvm_type_of(self.expr_type(v.value));
        const name = try self.allocator.dupeZ(u8, v.name);
        defer self.allocator.free(name);
        return llvm.LLVMBuildAlloca(self.builder, t, name);
    }

    pub fn codegen_params(self: *Codegen, params: std.ArrayList(ast.Param)) ![]llvm.LLVMTypeRef {
        const p_types = try self.allocator.alloc(llvm.LLVMTypeRef, params.items.len);
        for (params.items, 0..) |param, idx| {
            const t = try self.get_type(param.type);
            p_types[idx] = t;
        }

        return p_types;
    }

    pub fn codegen_alloca(self: *Codegen, p: ast.Param) !llvm.LLVMValueRef {
        const t = try self.get_type(p.type);
        const name = try self.allocator.dupeZ(u8, p.name);
        defer self.allocator.free(name);
        return llvm.LLVMBuildAlloca(self.builder, t, name);
    }

    pub fn codegen_return(self: *Codegen, r: *ast.ReturnStmt) !llvm.LLVMValueRef {
        if (r.value) |e| {
            const val = try self.codegen_expression(e);
            return llvm.LLVMBuildRet(self.builder, val);
        }
        return llvm.LLVMBuildRetVoid(self.builder);
    }

    pub fn codegen_expression_statement(self: *Codegen, e_stmt: *ast.ExprStmt) !llvm.LLVMValueRef {
        if (e_stmt.value) |e| {
            return try self.codegen_expression(e);
        }
        unreachable;
    }

    pub fn codegen_expression(self: *Codegen, e: *ast.Expr) !llvm.LLVMValueRef {
        return self.codegen_expression_with_type(e, null);
    }

    pub fn codegen_expression_with_type(self: *Codegen, e: *ast.Expr, expected_ty: ?llvm.LLVMTypeRef) !llvm.LLVMValueRef {
        return switch (e.*) {
            .literal => |*l| self.codegen_literal(l, e),
            .binary => |*b| self.codegen_binary(b),
            .unary => |*u| self.codegen_unary(u),
            .call => |*c| self.codegen_call(c),
            .ident => |*i| self.codegen_ident(i),
            .array_literal => |*a| try self.codegen_array(a, e),
            .index => |*i| try self.codegen_index(i),
            .struct_literal => |*s| try self.codegen_struct_literal(s, expected_ty),
            .field_access => |*f| try self.codegen_field_access(f, false),
            else => unreachable,
        };
    }

    pub fn codegen_field_access(self: *Codegen, f_access: *ast.FieldAccessExpr, assign: bool) anyerror!llvm.LLVMValueRef {
        // NOTE: currently only for structs field access
        const ident = switch (f_access.target.*) {
            .ident => |i| i,
            else => return error.InvalidFieldAccess,
        };

        const target_ty = self.expr_type(f_access.target);
        if (target_ty == .invalid)
            return error.InvalidType;
        const target_type = self.compiler.sema.types.get(target_ty);
        //   Point   -> load Point from stack
        //   *Point  -> load pointer to Point from stack
        var struct_ty_id: types.TypeId = .invalid;
        var struct_ptr: llvm.LLVMValueRef = undefined;
        switch (target_type.*) {
            .struct_ty => {
                struct_ty_id = target_ty;
                const struct_slot = self.stack_map.get(ident.name) orelse return error.VariableNotFound;
                const llvm_struct_ty = try self.get_llvm_type_of(struct_ty_id);
                struct_ptr = struct_slot;
                _ = llvm_struct_ty;
            },
            .pointer => |p| {
                struct_ty_id = p.child;
                const struct_slot = self.stack_map.get(ident.name) orelse return error.VariableNotFound;
                const ptr_ty = try self.get_llvm_type_of(target_ty);
                struct_ptr = llvm.LLVMBuildLoad2(
                    self.builder,
                    ptr_ty,
                    struct_slot,
                    "",
                );
            },

            else => return error.InvalidFieldAccess,
        }

        const struct_type = self.compiler.sema.types.get(struct_ty_id);
        const struct_info = switch (struct_type.*) {
            .struct_ty => |*s| s,
            else => return error.InvalidFieldAccess,
        };

        const llvm_struct_ty = try self.get_llvm_type_of(struct_ty_id);

        var field_index: usize = 0;
        var field_type: types.TypeId = .invalid;
        var found = false;
        for (struct_info.fields.items, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, f_access.field)) {
                field_index = i;
                field_type = field.ty;
                found = true;
                break;
            }
        }

        if (!found) return error.UnknownField;

        const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(self.ctx), 0, 0);
        const field_idx = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(self.ctx), field_index, 0);
        var indices = [_]llvm.LLVMValueRef{ zero, field_idx };
        const field_ptr = llvm.LLVMBuildGEP2(
            self.builder,
            llvm_struct_ty,
            struct_ptr,
            &indices,
            indices.len,
            "",
        );

        if (assign) return field_ptr;

        const llvm_field_ty = try self.get_llvm_type_of(field_type);
        return llvm.LLVMBuildLoad2(self.builder, llvm_field_ty, field_ptr, "");
    }

    pub fn codegen_struct_literal(self: *Codegen, s_lit: *ast.StructLiteral, expected_ty: ?llvm.LLVMTypeRef) anyerror!llvm.LLVMValueRef {
        const s_ty = if (s_lit.name.len != 0 and !std.mem.eql(u8, s_lit.name, "_"))
            self.struct_types.get(s_lit.name) orelse return error.NoStructTypeAvailable
        else
            expected_ty orelse return error.NoStructTypeAvailable;

        var struct_value = llvm.LLVMGetUndef(s_ty);
        for (s_lit.field_inits.items, 0..) |*f, idx| {
            const value = try self.codegen_expression(f.value);
            struct_value = llvm.LLVMBuildInsertValue(
                self.builder,
                struct_value,
                value,
                @intCast(idx),
                "",
            );
        }

        return struct_value;
    }

    fn codegen_slice_index(self: *Codegen, i: *ast.IndexExpr, slice_ty: types.TypeId) anyerror!llvm.LLVMValueRef {
        const slice_llvm_ty = try self.get_llvm_type_of(slice_ty);
        const slice_ptr = switch (i.target.*) {
            .ident => |ident| self.stack_map.get(ident.name) orelse return error.UnknownVariable,
            else => unreachable,
        };

        const slice = llvm.LLVMBuildLoad2(self.builder, slice_llvm_ty, slice_ptr, "");
        const data_ptr = llvm.LLVMBuildExtractValue(self.builder, slice, 0, "");

        // Generate index.
        const index = try self.codegen_expression(i.args.items[0]);
        const slice_info = switch (self.compiler.sema.types.get(slice_ty).*) {
            .slice => |s| s,
            else => unreachable,
        };

        var indices = [1]llvm.LLVMValueRef{index};
        const elem_ty = try self.get_llvm_type_of(slice_info.child);
        const element_ptr = llvm.LLVMBuildGEP2(
            self.builder,
            elem_ty,
            data_ptr,
            &indices,
            1,
            "",
        );

        return llvm.LLVMBuildLoad2(self.builder, elem_ty, element_ptr, "");
    }

    pub fn codegen_array_index(self: *Codegen, i: *ast.IndexExpr, array_ty: types.TypeId) anyerror!llvm.LLVMValueRef {
        const arr = switch (i.target.*) {
            .ident => |ident| self.stack_map.get(ident.name) orelse return error.UnknownVariable,

            else => try self.codegen_expression(i.target),
        };
        const llvm_array_ty = try self.get_llvm_type_of(array_ty);
        const index = try self.codegen_expression(i.args.items[0]);
        var indices = [2]llvm.LLVMValueRef{
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
            index,
        };

        const element_ptr = llvm.LLVMBuildGEPWithNoWrapFlags(
            self.builder,
            llvm_array_ty,
            arr,
            &indices,
            2,
            "",
            0,
        );

        const element_ty = llvm.LLVMGetElementType(llvm_array_ty);
        const ld = llvm.LLVMBuildLoad2(self.builder, element_ty, element_ptr, "");

        return ld;
    }

    pub fn codegen_index(self: *Codegen, i: *ast.IndexExpr) anyerror!llvm.LLVMValueRef {
        // Currently only support one-dimensional arrays.
        if (i.args.items.len != 1) {
            return error.InvalidIndex;
        }

        // Generate the index expression.
        const target_ty = self.expr_type(i.target);
        const target_type = self.compiler.sema.types.get(target_ty);
        switch (target_type.*) {
            .array => return self.codegen_array_index(i, target_ty),
            .slice => return self.codegen_slice_index(i, target_ty),
            else => return error.InvalidIndex,
        }
    }

    pub fn codegen_array_element_ptr(self: *Codegen, i: *ast.IndexExpr) !llvm.LLVMValueRef {
        if (i.args.items.len != 1) {
            return error.InvalidArrayIndex;
        }

        // For now, array target must be an identifier.
        const arr = switch (i.target.*) {
            .ident => |ident| self.stack_map.get(ident.name) orelse {
                return error.UnknownVariable;
            },
            else => return error.UnsupportedArrayTarget,
        };

        const array_ty = llvm.LLVMGetAllocatedType(arr);
        const index = try self.codegen_expression(i.args.items[0]);
        var indices = [2]llvm.LLVMValueRef{
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
            index,
        };

        return llvm.LLVMBuildGEPWithNoWrapFlags(
            self.builder,
            array_ty,
            arr,
            &indices,
            2,
            "",
            0,
        );
    }

    pub fn codegen_ident(self: *Codegen, i: *ast.IdentExpr) !llvm.LLVMValueRef {
        // load var from stack
        if (self.stack_map.get(i.name)) |v| {
            return llvm.LLVMBuildLoad2(self.builder, llvm.LLVMGetAllocatedType(v), v, "");
        }

        if (self.global_map.get(i.name)) |g| {
            const val_type = llvm.LLVMGlobalGetValueType(g);
            return llvm.LLVMBuildLoad2(self.builder, val_type, g, "");
        }
        return error.VariableNotFound;
    }

    pub fn codegen_call(self: *Codegen, c: *ast.CallExpr) !llvm.LLVMValueRef {
        // NOTE: assume callee is an ident
        const name = switch (c.callee.*) {
            .ident => |*i| i.name,
            else => {
                // TODO:
                unreachable;
            },
        };

        const name_call = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_call);
        const func_ref = llvm.LLVMGetNamedFunction(self.mod, name_call.ptr);
        if (func_ref == null) {
            log.err("no function named {s}\n", .{name});
        }

        const callee_ty = self.expr_type(c.callee);
        const callee_type = self.compiler.sema.types.get(callee_ty);
        const param_types = switch (callee_type.*) {
            .function => |f| f.params.items,
            .procedure => |p| p.params.items,
            else => unreachable,
        };

        // see why called value type failed here
        const func_type = llvm.LLVMGlobalGetValueType(func_ref);
        if (func_type == null) {
            log.err("no function type for {s}\n", .{name});
        }

        const args = try self.codegen_args(c.args, param_types);
        defer self.allocator.free(args);
        const n_args = c.args.items.len;

        // note: commenting this out, as these checks should be
        // handled in sema, not in codegen, right?

        // const expected = llvm.LLVMCountParamTypes(func_type);
        // if (expected != n_args) {
        //     log.err("expected args = {}, actual args = {}\n", .{ expected, n_args });
        // }

        const call = llvm.LLVMBuildCall2(
            self.builder,
            func_type,
            func_ref,
            args.ptr,
            @intCast(n_args),
            @ptrCast(""),
            // name_call,
        );

        return call;
    }

    fn is_array_slice_conversion(self: *Codegen, arg_ty: types.TypeId, param_ty: types.TypeId) bool {
        const arg = self.compiler.sema.types.get(arg_ty);
        const param = self.compiler.sema.types.get(param_ty);

        return switch (arg.*) {
            .array => switch (param.*) {
                .slice => true,
                else => false,
            },
            else => false,
        };
    }

    fn codegen_array_as_slice(self: *Codegen, operand: *ast.Expr, array_ty: types.TypeId) !llvm.LLVMValueRef {
        const array_info = switch (self.compiler.sema.types.get(array_ty).*) {
            .array => |a| a,
            else => unreachable,
        };

        const array_ptr = switch (operand.*) {
            .ident => |ident| self.stack_map.get(ident.name).?,
            else => unreachable,
        };

        const llvm_array_ty = try self.get_llvm_type_of(array_ty);
        var indices = [_]llvm.LLVMValueRef{
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 0, 0),
        };

        const elem_ptr = llvm.LLVMBuildGEP2(
            self.builder,
            llvm_array_ty,
            array_ptr,
            &indices,
            indices.len,
            "slice_ptr",
        );

        const elem_ty = try self.get_llvm_type_of(array_info.child);
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerType(elem_ty, 0),
            llvm.LLVMInt64TypeInContext(self.ctx),
        };
        const slice_ty = llvm.LLVMStructTypeInContext(self.ctx, &fields, fields.len, 0);

        var slice = llvm.LLVMGetUndef(slice_ty);

        slice = llvm.LLVMBuildInsertValue(
            self.builder,
            slice,
            elem_ptr,
            0,
            "slice_ptr",
        );

        slice = llvm.LLVMBuildInsertValue(
            self.builder,
            slice,
            llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), array_info.len, 0),
            1,
            "slice_len",
        );

        return slice;
    }

    pub fn codegen_args(self: *Codegen, args: std.ArrayList(ast.CallArg), param_types: []const types.TypeId) ![]llvm.LLVMValueRef {
        const a = try self.allocator.alloc(llvm.LLVMValueRef, args.items.len);
        for (args.items, 0..) |arg, idx| {
            const arg_ty = self.expr_type(arg.value);
            if (param_types.len > 0 and self.is_array_slice_conversion(arg_ty, param_types[idx])) {
                a[idx] = try self.codegen_array_as_slice(arg.value, arg_ty);
            } else {
                const v = try self.codegen_expression(arg.value);
                a[idx] = if (idx < param_types.len) try self.coerce_numeric(v, arg_ty, param_types[idx]) else v;
            }
        }

        return a;
    }

    // pub fn codegen_ident(self: *codegen, i: *ast.IdentExpr) !llvm.LLVMValueRef {}

    pub fn codegen_literal(self: *Codegen, l: *ast.LiteralExpr, e: *ast.Expr) !llvm.LLVMValueRef {
        const ty = self.expr_type(e);

        switch (l.kind) {
            .integer => {
                if (self.is_float_type(ty)) {
                    const f = try std.fmt.parseFloat(f64, l.raw);
                    return llvm.LLVMConstReal(try self.get_llvm_type_of(ty), f);
                }
                return llvm.LLVMConstInt(try self.get_llvm_type_of(ty), l.ivalue, 1);
            },
            .float => {
                return llvm.LLVMConstReal(try self.get_llvm_type_of(ty), l.fvalue);
            },
            .bool_true => return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(self.ctx), 1, 0),
            .bool_false => return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(self.ctx), 0, 0),
            .char => return llvm.LLVMConstInt(llvm.LLVMInt8TypeInContext(self.ctx), l.raw[0], 0),
            .string => {
                const name = try self.allocator.dupeZ(u8, l.raw);
                defer self.allocator.free(name);
                return llvm.LLVMBuildGlobalString(self.builder, name, "");
            },
        }
    }

    fn llvm_int_type_of(self: *Codegen, ty: types.TypeId) !llvm.LLVMTypeRef {
        if (ty == .invalid) return llvm.LLVMInt32TypeInContext(self.ctx);

        return switch (self.compiler.sema.types.get(ty).*) {
            .primitive => |p| switch (p) {
                .i8, .u8 => llvm.LLVMInt8TypeInContext(self.ctx),
                .i16, .u16 => llvm.LLVMInt16TypeInContext(self.ctx),
                .i32, .u32 => llvm.LLVMInt32TypeInContext(self.ctx),
                .i64, .u64, .usize, .isize => llvm.LLVMInt64TypeInContext(self.ctx),
                else => llvm.LLVMInt32TypeInContext(self.ctx),
            },
            else => llvm.LLVMInt32TypeInContext(self.ctx),
        };
    }

    fn llvm_float_type_of(self: *Codegen, ty: types.TypeId) !llvm.LLVMTypeRef {
        if (ty == .invalid) return llvm.LLVMInt32TypeInContext(self.ctx);

        return switch (self.compiler.sema.types.get(ty).*) {
            .primitive => |p| switch (p) {
                .f32 => llvm.LLVMFloatTypeInContext(self.ctx),
                .f64 => llvm.LLVMDoubleTypeInContext(self.ctx),
                else => llvm.LLVMDoubleTypeInContext(self.ctx),
            },
            else => llvm.LLVMDoubleTypeInContext(self.ctx),
        };
    }

    fn codegen_compound_op(self: *Codegen, op: ast.CompoundOp, l: llvm.LLVMValueRef, r: llvm.LLVMValueRef, is_signed: bool) !llvm.LLVMValueRef {
        const l_ty = llvm.LLVMTypeOf(l);
        const type_kind = llvm.LLVMGetTypeKind(l_ty);
        const is_float =
            type_kind == llvm.LLVMFloatTypeKind or
            type_kind == llvm.LLVMDoubleTypeKind;

        return switch (op) {
            .add => if (is_float) llvm.LLVMBuildFAdd(self.builder, l, r, "add_compound") else llvm.LLVMBuildAdd(self.builder, l, r, "add_compound"),
            .sub => if (is_float) llvm.LLVMBuildFSub(self.builder, l, r, "sub_compound") else llvm.LLVMBuildSub(self.builder, l, r, "sub_compound"),
            .mul => if (is_float) llvm.LLVMBuildFMul(self.builder, l, r, "mul_compound") else llvm.LLVMBuildMul(self.builder, l, r, "mul_compound"),
            .div => if (is_float) llvm.LLVMBuildFDiv(self.builder, l, r, "div_compound") else if (is_signed) llvm.LLVMBuildSDiv(self.builder, l, r, "div_compound") else llvm.LLVMBuildUDiv(self.builder, l, r, "div_compound"),
            .mod => if (is_float) llvm.LLVMBuildFRem(self.builder, l, r, "mod_compound") else if (is_signed) llvm.LLVMBuildSRem(self.builder, l, r, "mod_compound") else llvm.LLVMBuildURem(self.builder, l, r, "mod_compound"),
            .bit_or => llvm.LLVMBuildOr(self.builder, l, r, "log_compound"),
            .bit_xor => llvm.LLVMBuildXor(self.builder, l, r, "log_compound"),
            .bit_and => llvm.LLVMBuildAnd(self.builder, l, r, "log_compound"),
            .shl => llvm.LLVMBuildShl(self.builder, l, r, "shift_compound"),
            .shr => llvm.LLVMBuildLShr(self.builder, l, r, "shift_compound"),
        };
    }

    pub fn codegen_binary(self: *Codegen, b: *ast.BinaryExpr) anyerror!llvm.LLVMValueRef {
        var l = try self.codegen_expression(b.lhs);
        var r = try self.codegen_expression(b.rhs);
        const lty = self.expr_type(b.lhs);
        const rty = self.expr_type(b.rhs);
        const opty = self.compiler.sema.types.unify(lty, rty) orelse lty;
        l = try self.coerce_numeric(l, lty, opty);
        r = try self.coerce_numeric(r, rty, opty);
        const is_float = self.is_float_type(opty);
        const is_signed = self.is_signed_type(opty);
        // TODO: handle overflow and underflow
        return switch (b.op) {
            .add => if (is_float) llvm.LLVMBuildFAdd(self.builder, l, r, "add_bin") else llvm.LLVMBuildAdd(self.builder, l, r, "add_bin"),
            .sub => if (is_float) llvm.LLVMBuildFSub(self.builder, l, r, "sub_bin") else llvm.LLVMBuildSub(self.builder, l, r, "sub_bin"),
            .mul => if (is_float) llvm.LLVMBuildFMul(self.builder, l, r, "mul_bin") else llvm.LLVMBuildMul(self.builder, l, r, "mul_bin"),
            .div => if (is_float) llvm.LLVMBuildFDiv(self.builder, l, r, "div_bin") else if (is_signed) llvm.LLVMBuildSDiv(self.builder, l, r, "div_bin") else llvm.LLVMBuildUDiv(self.builder, l, r, "div_bin"),
            .mod => if (is_float) llvm.LLVMBuildFRem(self.builder, l, r, "mod_bin") else if (is_signed) llvm.LLVMBuildSRem(self.builder, l, r, "mod_bin") else llvm.LLVMBuildURem(self.builder, l, r, "mod_bin"),
            .eq => if (is_float) llvm.LLVMBuildFCmp(self.builder, llvm.LLVMRealOEQ, l, r, "cmp_bin") else llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, l, r, "cmp_bin"),
            .ne => if (is_float) llvm.LLVMBuildFCmp(self.builder, llvm.LLVMRealONE, l, r, "cmp_bin") else llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntNE, l, r, "cmp_bin"),
            .lt => if (is_float) llvm.LLVMBuildFCmp(self.builder, llvm.LLVMRealOLT, l, r, "cmp_bin") else llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULT, l, r, "cmp_bin"),
            .gt => if (is_float) llvm.LLVMBuildFCmp(self.builder, llvm.LLVMRealOGT, l, r, "cmp_bin") else llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntUGT, l, r, "cmp_bin"),
            .le => if (is_float) llvm.LLVMBuildFCmp(self.builder, llvm.LLVMRealOLE, l, r, "cmp_bin") else llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULE, l, r, "cmp_bin"),
            .ge => if (is_float) llvm.LLVMBuildFCmp(self.builder, llvm.LLVMRealOGE, l, r, "cmp_bin") else llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntUGE, l, r, "cmp_bin"),
            .bit_or => llvm.LLVMBuildOr(self.builder, l, r, "log_bin"),
            .bit_xor => llvm.LLVMBuildXor(self.builder, l, r, "log_bin"),
            .bit_and => llvm.LLVMBuildAnd(self.builder, l, r, "log_bin"),
            .logical_or => llvm.LLVMBuildOr(self.builder, l, r, "or_bin"),
            .logical_and => llvm.LLVMBuildAnd(self.builder, l, r, "and_bin"),
            .shl => llvm.LLVMBuildShl(self.builder, l, r, "shift_bin"),
            .shr => llvm.LLVMBuildLShr(self.builder, l, r, "shift_bin"),
            else => {
                // TODO:
                unreachable;
            },
        };
    }

    pub fn codegen_unary(self: *Codegen, u: *ast.UnaryExpr) anyerror!llvm.LLVMValueRef {
        if (u.op == .new) return self.codegen_new(u.operand);

        const e = try self.codegen_expression(u.operand);
        const oty = self.expr_type(u.operand);
        const is_float = self.is_float_type(oty);

        return switch (u.op) {
            .neg => if (is_float) llvm.LLVMBuildFNeg(self.builder, e, "neg_un") else llvm.LLVMBuildNeg(self.builder, e, "neg_un"),
            .bit_not => llvm.LLVMBuildNot(self.builder, e, "bit_not_un"),
            .addr_of => switch (u.operand.*) {
                .ident => |*i| self.stack_map.get(i.name).?,
                else => unreachable,
            },
            .not => llvm.LLVMBuildNot(self.builder, e, "not_un"),
            else => {
                // TODO:
                unreachable;
            },
        };
    }

    pub fn codegen_new(self: *Codegen, expr: *ast.Expr) !llvm.LLVMValueRef {
        const type_id = self.expr_type(expr);
        const llvm_type = try self.get_llvm_type_of(type_id);
        const size_val = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.ctx), 8, 0);
        var args = [_]llvm.LLVMValueRef{size_val};

        const bok_alloc_fn = llvm.LLVMGetNamedFunction(self.mod, "bok_alloc");
        const bok_alloc_type = llvm.LLVMGlobalGetValueType(bok_alloc_fn);

        const ptr = llvm.LLVMBuildCall2(
            self.builder,
            bok_alloc_type,
            bok_alloc_fn,
            &args,
            args.len,
            "",
        );

        switch (expr.*) {
            .struct_literal => |*s| {
                for (s.field_inits.items, 0..) |field_init, idx| {
                    const name = try self.allocator.dupeZ(u8, field_init.name);
                    defer self.allocator.free(name);
                    const field_ptr = llvm.LLVMBuildStructGEP2(
                        self.builder,
                        llvm_type,
                        ptr,
                        @intCast(idx),
                        name,
                    );
                    const value = try self.codegen_expression(field_init.value);
                    _ = llvm.LLVMBuildStore(self.builder, value, field_ptr);
                }
            },
            else => unreachable,
        }

        return ptr;
    }

    pub fn get_type(self: *Codegen, ret_type: *ast.Type) anyerror!llvm.LLVMTypeRef {
        // TODO: handle optionals and errors
        switch (ret_type.base) {
            .primitive => |*p| return self.get_primitive_type(p),
            .pointer => |p| return llvm.LLVMPointerType(try self.get_type(p), 0),
            .array => |*a| {
                const ele_ty = try self.get_type(a.elem);
                const sz = switch (a.size) {
                    .fixed => |s| try std.fmt.parseInt(c_uint, s, 10),
                    else => {
                        unreachable;
                    },
                };
                return llvm.LLVMArrayType2(ele_ty, sz);
            },
            .named => |*n| {
                if (std.mem.eql(u8, n.name, "ptr")) {
                    return llvm.LLVMPointerTypeInContext(self.ctx, 64);
                }
                if (self.struct_types.get(n.name)) |st| return st;
                const resolved = self.compiler.sema.types.resolve(n.name) orelse unreachable;
                return try self.get_llvm_type_of(resolved);
            },
            .slice => |*s| {
                const ele_ty = try self.get_type(s.elem);
                var fields = [_]llvm.LLVMTypeRef{ llvm.LLVMPointerType(ele_ty, 0), llvm.LLVMInt64TypeInContext(self.ctx) };
                return llvm.LLVMStructTypeInContext(self.ctx, &fields, fields.len, 0);
            },
            else => {
                // TODO:
                unreachable;
            },
        }
    }

    pub fn get_primitive_type(self: *Codegen, p: *ast.PrimitiveType) !llvm.LLVMTypeRef {
        switch (p.*) {
            .i8, .u8 => return llvm.LLVMInt8TypeInContext(self.ctx),
            .i16, .u16 => return llvm.LLVMInt16TypeInContext(self.ctx),
            .i32, .u32 => return llvm.LLVMInt32TypeInContext(self.ctx),
            .i64, .u64, .usize, .isize => return llvm.LLVMInt64TypeInContext(self.ctx),
            .f32 => return llvm.LLVMFloatTypeInContext(self.ctx),
            .f64 => return llvm.LLVMDoubleTypeInContext(self.ctx),
            .bool => return llvm.LLVMInt1TypeInContext(self.ctx),
            .char => return llvm.LLVMInt8TypeInContext(self.ctx),
            .str => return llvm.LLVMPointerType(llvm.LLVMInt8TypeInContext(self.ctx), 64),
            .ptr => return llvm.LLVMPointerTypeInContext(self.ctx, 64),
        }
    }

    pub fn get_llvm_type_of(self: *Codegen, ty: types.TypeId) anyerror!llvm.LLVMTypeRef {
        if (ty == .invalid) return llvm.LLVMInt32TypeInContext(self.ctx); // note: for temp if some types are not managed in sema for now

        return switch (self.compiler.sema.types.get(ty).*) {
            .primitive => |p| switch (p) {
                .i8, .u8 => return llvm.LLVMInt8TypeInContext(self.ctx),
                .i16, .u16 => return llvm.LLVMInt16TypeInContext(self.ctx),
                .i32, .u32 => return llvm.LLVMInt32TypeInContext(self.ctx),
                .i64, .u64, .usize, .isize => return llvm.LLVMInt64TypeInContext(self.ctx),
                .f32 => return llvm.LLVMFloatTypeInContext(self.ctx),
                .f64 => return llvm.LLVMDoubleTypeInContext(self.ctx),
                .bool => return llvm.LLVMInt1TypeInContext(self.ctx),
                .char => return llvm.LLVMInt8TypeInContext(self.ctx),
                .str => return llvm.LLVMPointerType(llvm.LLVMInt8TypeInContext(self.ctx), 64),
                .ptr => return llvm.LLVMPointerTypeInContext(self.ctx, 64),
            },
            .pointer => |p| llvm.LLVMPointerType(try self.get_llvm_type_of(p.child), 0),
            .array => |a| {
                const ele_ty = try self.get_llvm_type_of(a.child);
                const sz: c_uint = @intCast(a.len);
                return llvm.LLVMArrayType2(ele_ty, sz);
            },
            .struct_ty => |*s| self.struct_types.get(s.name) orelse return error.NoStructTypeAvailable,
            .slice => |*s| {
                const ele_ty = try self.get_llvm_type_of(s.child);
                var fields = [_]llvm.LLVMTypeRef{ llvm.LLVMPointerType(ele_ty, 0), llvm.LLVMInt64TypeInContext(self.ctx) };
                return llvm.LLVMStructTypeInContext(self.ctx, &fields, fields.len, 0);
            },
            else => {
                //todo: other typse
                unreachable;
            },
        };
    }

    fn expr_type(self: *Codegen, e: *ast.Expr) types.TypeId {
        return self.compiler.sema.expr_types.get(e) orelse .invalid;
    }
};
