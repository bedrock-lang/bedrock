const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    file: []const u8,
    target: []const u8,
    emit_tokens: bool = false,
    emit_ast: bool = false,
    emit_ir: bool = false,
    sema: bool = true,
    run_jit: bool = false,
    emit_obj: bool = false,
    link: bool = false,
    output: []const u8 = "a.out",
    testing: bool = false,
    link_flags: std.ArrayList([]const u8) = .empty,
};

pub fn parse(allocator: std.mem.Allocator, args: anytype) !Options {
    var t: []const u8 = "";
    switch (builtin.os.tag) {
        .linux => t = "x86",
        .macos => t = "aarch64",
        else => {
            return error.targetNotSupported;
        },
    }

    var options = Options{
        .file = "",
        .target = t,
    };

    _ = args.next();

    const file = args.next() orelse {
        std.debug.print("error: no input file\n", .{});
        printUsage();
        return error.MissingInput;
    };

    // check for help
    if (std.mem.eql(u8, file, "--help")) {
        printUsage();
        std.process.exit(0);
    }

    if (!std.mem.endsWith(u8, file, ".bok")) {
        std.debug.print("error: input file must have '.bok' ext\n", .{});
        return error.InvalidInput;
    }

    options.file = file;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--emit-ast")) {
            options.emit_ast = true;
        } else if (std.mem.eql(u8, arg, "--emit-tokens")) {
            options.emit_tokens = true;
        } else if (std.mem.eql(u8, arg, "--emit-ir")) {
            options.emit_ir = true;
            options.sema = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            options.emit_obj = true;
            options.link = true;
            options.sema = true;
            options.output = args.next() orelse {
                std.debug.print("error: '-o' requires an output path\n", .{});
                return error.MissingInput;
            };
        } else if (std.mem.eql(u8, arg, "--sema")) {
            options.sema = true;
        } else if (std.mem.eql(u8, arg, "--jit")) {
            options.run_jit = true;
            options.sema = true;
        } else if (std.mem.startsWith(u8, arg, "-l") or std.mem.startsWith(u8, arg, "-L")) {
            try options.link_flags.append(allocator, arg);
        } else {
            std.debug.print("error: unknown argument '{s}'\n", .{arg});
            return error.UnknownArgument;
        }
    }

    return options;
}

pub fn printBanner() void {
    std.debug.print(
        \\
        \\██████╗  ██████╗ ██╗  ██╗
        \\██╔══██╗██╔═══██╗██║ ██╔╝
        \\██████╔╝██║   ██║█████╔╝
        \\██╔══██╗██║   ██║██╔═██╗
        \\██████╔╝╚██████╔╝██║  ██╗
        \\╚═════╝  ╚═════╝ ╚═╝  ╚═╝
        \\
        \\   The Bedrock Compiler
        \\
    , .{});
}

pub fn printUsage() void {
    printBanner();
    std.debug.print(
        \\Usage:
        \\  bok <file.bok> [options]
        \\
        \\Options:
        \\  --emit-ast              emit AST
        \\  --emit-ir               emit LLVM IR
        \\  -o <path>               compile and link to an executable at <path>
        \\  --sema                  run semantic analysis
        \\  --jit                   compilation target
        \\  -l<name>                link against a library
        \\  -L<path>                add a library search path
        \\  --help                  show this help
        \\
    , .{});
}
