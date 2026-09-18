const std = @import("std");
const llvm = @import("llvm");
const lexer = @import("lexer.zig");
const err = @import("error.zig");
const token = @import("token.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const sema = @import("sema/semantics.zig");
const Options = @import("cli.zig").Options;

const log = std.log.scoped(.compiler);
const Error = error{ CompilerFail, JitError, MainFuncNotFound };

pub const JitRetType = union(enum) {
    i32: i32,
    f32: f32,
    f64: f64,
    void: void,
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    errors: std.ArrayList(err.SourceError),
    source: []const u8,
    ast: ast.AST,
    sema: sema.Sema,
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    opt: Options,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, source: []const u8, opt: Options) Compiler {
        return Compiler{
            .allocator = allocator,
            .io = io,
            .errors = .empty,
            .source = source,
            .ast = undefined,
            .sema = undefined,
            .mod = undefined,
            .ctx = undefined,
            .opt = opt,
        };
    }

    // runtime!! //
    // using system linker "cc" for now
    pub fn link(self: *Compiler, obj_path: []const u8) !void {
        var rt_lib: []const u8 = "";
        var rt_dir: []const u8 = "";
        if (std.mem.eql(u8, self.opt.target, "aarch64")) {
            rt_lib = "zig-out/lib/libmemory.dylib";
            rt_dir = "zig-out/lib";
        } else if (std.mem.eql(u8, self.opt.target, "x86")) {
            rt_lib = "zig-out/lib/libmemory.so";
            rt_dir = "zig-out/lib";
        } else {
            log.err("linking not supported for this target\n", .{});
            return Error.CompilerFail;
        }

        // note: hardcoding -rpath so that it can find the libmemory.so
        const rpath_flag = try std.fmt.allocPrint(self.allocator, "-Wl,-rpath,{s}", .{rt_dir});
        defer self.allocator.free(rpath_flag);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.appendSlice(self.allocator, &.{
            "cc",
            obj_path,
            rt_lib,
            rpath_flag,
            "-o",
            self.opt.output,
        });

        try argv.appendSlice(self.allocator, self.opt.link_flags.items);

        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv.items });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            log.err("linker failed:\n{s}\n", .{result.stderr});
            return Error.CompilerFail;
        }

        log.debug("executable formed {s}\n", .{self.opt.output});
    }

    pub fn jit(self: *Compiler) !JitRetType {
        const jit_builder = llvm.LLVMOrcCreateLLJITBuilder();
        if (jit_builder == null) {
            log.err("failed to create LLJIT builder\n", .{});
            return Error.JitError;
        }

        var j: llvm.LLVMOrcLLJITRef = null;
        const e = llvm.LLVMOrcCreateLLJIT(&j, jit_builder);
        if (e != null) {
            const err_ref = llvm.LLVMGetErrorMessage(e);
            log.err("{s}\n", .{err_ref});
            llvm.LLVMDisposeErrorMessage(err_ref);
            return Error.JitError;
        }

        const jd = llvm.LLVMOrcLLJITGetMainJITDylib(j);
        // add runtime mem
        var dyn_mem: []const u8 = "";
        if (std.mem.eql(u8, self.opt.target, "aarch64")) {
            dyn_mem = "zig-out/lib/libmemory.dylib";
        } else if (std.mem.eql(u8, self.opt.target, "x86")) {
            dyn_mem = "zig-out/lib/libmemory.so";
        } else {
            log.err("Linking to memory runtime not supported for this aarch\n", .{});
            return Error.JitError;
        }

        var gen: llvm.LLVMOrcDefinitionGeneratorRef = undefined;
        const gen_err = llvm.LLVMOrcCreateDynamicLibrarySearchGeneratorForPath(
            &gen,
            dyn_mem.ptr,
            0,
            null,
            null,
        );

        if (gen_err != null) {
            const err_ref = llvm.LLVMGetErrorMessage(gen_err);
            log.err("{s}\n", .{err_ref});
            llvm.LLVMDisposeErrorMessage(err_ref);
            return Error.JitError;
        }

        llvm.LLVMOrcJITDylibAddGenerator(jd, gen);

        const func = llvm.LLVMGetNamedFunction(self.mod, "main");
        if (func == null) {
            log.err("main func not found in the program\n", .{});
            return Error.MainFuncNotFound;
        }
        const func_type = llvm.LLVMGlobalGetValueType(func);
        const return_type = llvm.LLVMGetReturnType(func_type);

        // get thread safe context for jit
        const tsctx = llvm.LLVMOrcCreateNewThreadSafeContextFromLLVMContext(self.ctx);
        const tsm = llvm.LLVMOrcCreateNewThreadSafeModule(self.mod, tsctx);
        _ = llvm.LLVMOrcLLJITAddLLVMIRModule(j, jd, tsm);

        var addr: llvm.LLVMOrcExecutorAddress = undefined;
        _ = llvm.LLVMOrcLLJITLookup(j, &addr, @ptrCast("main"));

        switch (llvm.LLVMGetTypeKind(return_type)) {
            llvm.LLVMIntegerTypeKind => {
                const Main = @as(*const fn () callconv(.c) i32, @ptrFromInt(addr));
                const res = Main();
                log.debug("jit result: {}\n", .{res});
                return .{ .i32 = res };
            },
            llvm.LLVMFloatTypeKind => {
                const Main = @as(*const fn () callconv(.c) f32, @ptrFromInt(addr));
                const res = Main();
                log.debug("jit result: {}\n", .{res});
                return .{ .f32 = res };
            },
            llvm.LLVMDoubleTypeKind => {
                const Main = @as(*const fn () callconv(.c) f64, @ptrFromInt(addr));
                const res = Main();
                log.debug("jit result: {}\n", .{res});
                return .{ .f64 = res };
            },
            llvm.LLVMVoidTypeKind => {
                const Main = @as(*const fn () callconv(.c) void, @ptrFromInt(addr));
                Main();
                return .{ .void = {} };
            },
            else => {
                log.err("ret type is not supported\n", .{});
                return Error.JitError;
            },
        }
    }

    pub fn run(self: *Compiler) !JitRetType {
        if (self.opt.emit_tokens) {
            var tokens = try lexer.tokenize(self.allocator, self.source);
            defer tokens.deinit(self.allocator);

            log.debug("\nTokens:\n", .{});
            for (tokens.items) |tok| {
                log.debug("{d}:{d:<3} {s:<12} '{s}'\n", .{ tok.line, tok.col, @tagName(tok.type), tok.val });
            }
        }

        var p = parser.Parser.init(self.allocator, self.source, self);
        self.ast = try p.parse();
        if (self.errors.items.len > 0) {
            self.ast.deinit(self.allocator);
            return Error.CompilerFail;
        }

        if (self.opt.emit_ast) try self.ast.print();

        var s_run = false;
        if (self.opt.sema) {
            self.sema = sema.Sema.init(self);
            try self.sema.analyze();
            s_run = true;
            if (self.errors.items.len > 0) {
                self.ast.deinit(self.allocator);
                self.sema.deinit();
                return Error.CompilerFail;
            }
        }

        var r: JitRetType = .{ .i32 = 0 };
        if (self.opt.run_jit or self.opt.emit_ir or self.opt.emit_obj) {
            var c = try codegen.Codegen.init(self.allocator, self);
            self.mod = try c.codegen();
            self.ctx = c.ctx;

            var err_msg: [*c]u8 = null;
            if (self.opt.emit_ir) {
                _ = llvm.LLVMPrintModuleToFile(self.mod, "./build/dump.ll", &err_msg);
                if (err_msg) |msg| {
                    log.err("{s}\n", .{std.mem.span(msg)});
                    llvm.LLVMDisposeMessage(msg);
                    return Error.CompilerFail;
                }
                const mod_str = llvm.LLVMPrintModuleToString(self.mod);
                log.debug("{s}\n", .{mod_str});
            }

            if (self.opt.emit_obj) {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const obj_path = try std.fmt.bufPrintZ(&buf, "{s}.o", .{self.opt.output});
                _ = llvm.LLVMTargetMachineEmitToFile(c.tm, c.mod, obj_path.ptr, llvm.LLVMObjectFile, &err_msg);
                if (err_msg) |msg| {
                    log.err("{s}\n", .{std.mem.span(msg)});
                    llvm.LLVMDisposeMessage(msg);
                    return Error.CompilerFail;
                }

                if (self.opt.link) {
                    try self.link(obj_path);
                }
            }

            if (self.errors.items.len > 0) {
                self.ast.deinit(self.allocator);
                c.deinit();
                return Error.CompilerFail;
            }

            if (self.opt.run_jit) {
                r = try self.jit();
                s_run = false;
                self.sema.deinit();
            }

            c.deinit();
        }

        if (s_run) self.sema.deinit();

        try self.emitErrors();
        self.ast.deinit(self.allocator);

        return r;
    }

    pub fn addError(self: *Compiler, msg: []const u8, severity: err.Severity, tok: token.Token) !void {
        const err_msg = try std.fmt.allocPrint(self.allocator, "{s} here but found {s}\n", .{ msg, tok.val });
        try self.errors.append(self.allocator, err.SourceError{
            .msg = err_msg,
            .severity = severity,
            .token = tok,
        });
    }

    pub fn add_sem_error(self: *Compiler, comptime fmt: []const u8, args: anytype, severity: err.Severity, tok: token.Token) !void {
        const err_msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(self.allocator, err.SourceError{ .msg = err_msg, .severity = severity, .token = tok });
    }

    pub fn emitErrors(self: *Compiler) !void {
        for (self.errors.items) |e| {
            var l_count: usize = 1;
            var lines = std.mem.splitScalar(u8, self.source, '\n');
            while (lines.next()) |l| {
                if (l_count + 3 <= e.token.line) {
                    l_count += 1;
                    continue;
                } else if (l_count >= e.token.line + 3) {
                    break;
                } else if (l_count == e.token.line) {
                    log.debug("{d} | {s}", .{ l_count, l[0 .. e.token.col - 1] });
                    log.debug("{s}", .{l[e.token.col - 1 .. e.token.col + e.token.val.len - 1]});
                    log.debug("{s}\n", .{l[e.token.col + e.token.val.len - 1 ..]});
                    log.debug("    ", .{});
                    for (l[0 .. e.token.col - 1]) |_| {
                        log.debug(" ", .{});
                    }
                    for (l[e.token.col - 1 .. e.token.col + e.token.val.len - 1]) |_| {
                        log.debug("^", .{});
                    }
                    switch (e.severity) {
                        err.Severity.Error => {
                            log.debug(" \x1b[31m{s}\x1b[0m\n\n", .{e.msg});
                        },
                        err.Severity.Warn => {
                            log.debug(" \x1b[33m{s}\x1b[0m\n\n", .{e.msg});
                        },
                        err.Severity.Info => {
                            log.debug(" \x1b[36m{s}\x1b[0m\n\n", .{e.msg});
                        },
                    }
                } else {
                    log.debug("{d} | {s}\n", .{ l_count, l });
                }
                l_count += 1;
            }
        }
    }

    pub fn deinit(self: *Compiler) void {
        try self.emitErrors();
        for (self.errors.items) |e| {
            self.allocator.free(e.msg);
        }
        self.errors.deinit(self.allocator);
        self.opt.link_flags.deinit(self.allocator);
    }
};
