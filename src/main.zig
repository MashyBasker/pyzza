const std = @import("std");
const pyzza = @import("pyzza");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--test")) {
        const dir_path = if (args.len >= 3) args[2] else "tests/fixtures";
        const failed = try runFixtureTests(init, allocator, dir_path);
        if (failed) return error.TestsFailed;
        return;
    }

    if (args.len < 2) {
        std.debug.print("usage: pyzza <file.py>\n       pyzza --test [dir]\n", .{});
        return error.MissingArgument;
    }

    try runFile(init, allocator, args[1]);
}

fn runFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !void {
    const io = init.io;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));

    const toks = try pyzza.tokenizer.Tokenizer.tokenize(allocator, source);

    var p = pyzza.parser.Parser.init(allocator, toks);
    defer p.deinit();
    const program = try p.parseProgram();

    var c = pyzza.compiler.Compiler.init(allocator);
    defer c.deinit();
    const code = try c.compile(program);

    var machine = pyzza.vm.VM.init(allocator);
    defer machine.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    try machine.run(code, w);
    try w.flush();
}

/// Tokenizes, parses, compiles, and runs every `.py` file under `dir_path`
/// and reports OK/FAIL per file per stage. A file "fails" a stage only if
/// that stage returns an error (e.g. bad indentation, unterminated string,
/// unexpected token, undefined name) -- there is no expected-output
/// comparison, just "does it run without erroring". Returns true if any
/// file failed any stage.
fn runFixtureTests(init: std.process.Init, allocator: std.mem.Allocator, dir_path: []const u8) !bool {
    const io = init.io;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("cannot open fixtures dir '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var total: usize = 0;
    var failed: usize = 0;

    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".py")) continue;
        total += 1;

        const source = try dir.readFileAlloc(io, entry.name, allocator, .limited(1 << 20));

        const toks = pyzza.tokenizer.Tokenizer.tokenize(allocator, source) catch |err| {
            failed += 1;
            std.debug.print("FAIL {s}: tokenize error: {s}\n", .{ entry.name, @errorName(err) });
            continue;
        };

        var p = pyzza.parser.Parser.init(allocator, toks);
        defer p.deinit();
        const program = p.parseProgram() catch |err| {
            failed += 1;
            std.debug.print("FAIL {s}: parse error: {s}\n", .{ entry.name, @errorName(err) });
            continue;
        };

        var c = pyzza.compiler.Compiler.init(allocator);
        defer c.deinit();
        const code = c.compile(program) catch |err| {
            failed += 1;
            std.debug.print("FAIL {s}: compile error: {s}\n", .{ entry.name, @errorName(err) });
            continue;
        };

        var machine = pyzza.vm.VM.init(allocator);
        defer machine.deinit();

        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
        const w = &stdout_writer.interface;

        std.debug.print("-- {s} --\n", .{entry.name});
        if (machine.run(code, w)) {
            try w.flush();
            std.debug.print("OK   {s} ({d} tokens, {d} statements)\n", .{ entry.name, toks.len, program.body.len });
        } else |err| {
            try w.flush();
            failed += 1;
            std.debug.print("FAIL {s}: runtime error: {s}\n", .{ entry.name, @errorName(err) });
        }
    }

    std.debug.print("\n{d}/{d} fixtures passed\n", .{ total - failed, total });
    return failed > 0;
}
