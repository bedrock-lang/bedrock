const std = @import("std");
const llvm = @import("llvm");
const lexer = @import("lexer.zig");
const compiler = @import("compiler.zig");
const err = @import("error.zig");
const token = @import("token.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.Args.iterate(init.minimal.args);
    defer args.deinit();

    const options = try cli.parse(allocator, &args);

    // build dir for compiler artifacts
    try std.Io.Dir.cwd().deleteTree(init.io, "./build");
    try std.Io.Dir.cwd().createDir(init.io, "./build", @enumFromInt(0o777));

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, options.file, allocator, .limited(1 << 22));
    defer allocator.free(source);

    var c = compiler.Compiler.init(allocator, init.io, source, options);
    defer c.deinit();
    _ = try c.run();
}
