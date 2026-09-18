const std = @import("std");
const builtin = @import("builtin");
const bedrock = @import("bedrock");
const ast = bedrock.ast;
const compiler = bedrock.compiler;
const parser = bedrock.parser;
const scope = bedrock.scope;
const sema = bedrock.sema;
const typesystem = bedrock.typesystem;
const codegen = bedrock.codegen;
const cli = bedrock.cli;
const llvm = bedrock.llvm;

const log = std.log.scoped(.codegen_tests);

fn parse_expected_output(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');

    const first_line = lines.next() orelse return null;
    const line = std.mem.trim(u8, first_line, " \t\r");

    const prefix = "// output:";
    if (!std.mem.startsWith(u8, line, prefix))
        return null;

    return std.mem.trim(u8, line[prefix.len..], " \t\r");
}

fn collect_files(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, files: *std.ArrayList([]const u8), path: []const u8) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path);
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".bok")) {
                    try files.append(allocator, try allocator.dupe(u8, entry_path));
                }
            },
            .directory => {
                var subdir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer subdir.close(io);
                try collect_files(allocator, io, subdir, files, entry_path);
            },
            else => {},
        }
    }
}

test "codegen-test" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const codegen_dir = try std.Io.Dir.cwd().openDir(io, "corpus/codegen/", .{ .iterate = true });
    defer codegen_dir.close(io);

    var target: []const u8 = "";
    switch (builtin.os.tag) {
        .linux => target = "x86",
        .macos => target = "aarch64",
        else => {
            return error.targetNotSupported;
        },
    }

    var codegen_files: std.ArrayList([]const u8) = .empty;
    defer codegen_files.deinit(allocator);
    try collect_files(allocator, io, codegen_dir, &codegen_files, "corpus/codegen/");

    var options = cli.Options{
        .file = "",
        .target = target,
        .emit_tokens = false,
        .emit_ast = false,
        .emit_ir = false,
        .sema = true,
        .run_jit = true,
        .emit_obj = false,
        .testing = true,
    };
    for (codegen_files.items) |f| {
        const s = try std.fmt.allocPrint(allocator, "Testing file {s}:", .{f});
        defer allocator.free(s);

        options.file = f;
        const source = try std.Io.Dir.cwd().readFileAlloc(io, options.file, allocator, .limited(1 << 22));
        defer allocator.free(source);

        const expected = parse_expected_output(source);
        if (expected != null) {
            var c = compiler.Compiler.init(allocator, io, source, options);
            const res: compiler.JitRetType = c.run() catch {
                log.info("{s} failed\n", .{s});
                return;
            };
            const res_dup = switch (res) {
                .i32 => try std.fmt.allocPrint(allocator, "{}", .{res.i32}),
                .f32 => try std.fmt.allocPrint(allocator, "{}", .{res.f32}),
                .f64 => try std.fmt.allocPrint(allocator, "{}", .{res.f64}),
                .void => "",
            };

            std.testing.expectEqual(c.errors.items.len, 0) catch {
                // skip traces
            };
            std.testing.expectEqualStrings(expected.?, res_dup) catch {
                // skip traces
            };

            log.info("{s} passsed\n", .{s});
            defer allocator.free(res_dup);
            defer c.deinit();
        }
    }

    for (codegen_files.items) |f| {
        allocator.free(f);
    }
}
