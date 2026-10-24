//! `zig build test`: the template's size, and a link and the exelink CLI run
//! end to end on this machine. Paths come from build.zig.
const std = @import("std");
const paths = @import("paths");
const testing = std.testing;
const io = testing.io;

test "x86_64 template size" {
    try verifyTemplateSize(.x86_64);
}
test "aarch64 template size" {
    try verifyTemplateSize(.aarch64);
}
test "x86 template size" {
    try verifyTemplateSize(.x86);
}

/// Exact, so a size change shows up, and as README's table says, so README
/// can't fall behind.
fn verifyTemplateSize(comptime arch: std.Target.Cpu.Arch) !void {
    const path = @field(paths, "template_" ++ @tagName(arch));
    const actual = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
    const expected = try readmeSize(@tagName(arch));
    if (actual != expected) {
        std.debug.print("{s} template is {d} bytes, README.md says {d}\n", .{ @tagName(arch), actual, expected });
        return error.TestUnexpectedResult;
    }
}

/// From README's size table, a row like "| x86_64  | 2,656 bytes |".
fn readmeSize(arch: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, @embedFile("readme"), '\n');
    while (lines.next()) |line| {
        var cells = std.mem.tokenizeAny(u8, line, "| \r");
        if (!std.mem.eql(u8, cells.next() orelse continue, arch)) continue;
        const size = cells.next() orelse break;
        if (!std.mem.eql(u8, cells.next() orelse break, "bytes")) break;
        var n: u64 = 0;
        for (size) |c| switch (c) {
            '0'...'9' => n = n * 10 + (c - '0'),
            ',' => {},
            else => break,
        } else return n;
        break;
    }
    std.debug.print("README.md has no '| {s} | N bytes |' row\n", .{arch});
    return error.TestUnexpectedResult;
}

fn run(a: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(a, io, .{ .argv = argv, .create_no_window = false });
}

test "a link runs its target with our args, stdin and exit code" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // a space in the link's path, so argv[0] arrives quoted
    try tmp.dir.createDirPath(io, "my links");
    const dir = try tmp.dir.realPathFileAlloc(io, "my links", a);
    const link = try std.fs.path.join(a, &.{ dir, "echo.exe" });
    // a non-ASCII target, including a surrogate pair
    try tmp.dir.createDirPath(io, "tärget 😀");
    try std.Io.Dir.cwd().copyFile(paths.echo, tmp.dir, "tärget 😀\\echo.exe", io, .{});
    const echo = try tmp.dir.realPathFileAlloc(io, "tärget 😀\\echo.exe", a);
    try testing.expect((try run(a, &.{ paths.exelink, link, "to", echo })).term.success());

    // args std must quote and escape, including empty and trailing-backslash ones
    const args = [_][]const u8{ "a b", "tab\there", "quo\"te", "", "trail\\", "\\\\x\\\"", "ü😀" };

    // what the target gets run directly, with argv[0] "X": the rest of the
    // command line is how std encoded `args`
    var direct_argv: std.ArrayList([]const u8) = .empty;
    try direct_argv.append(a, "X");
    try direct_argv.appendSlice(a, &args);
    const direct = try std.process.run(a, io, .{
        .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = echo } },
        .argv = direct_argv.items,
        .create_no_window = false,
    });
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, direct.term);
    const rest = direct.stdout[1..std.mem.indexOfScalar(u8, direct.stdout, '\n').?];

    var link_argv: std.ArrayList([]const u8) = .empty;
    try link_argv.append(a, link);
    try link_argv.appendSlice(a, &args);
    var child = try std.process.spawn(io, .{
        .argv = link_argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .create_no_window = false,
    });
    defer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, "from stdin");
    child.stdin.?.close(io);
    child.stdin = null;
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &buf);
    const out = try r.interface.allocRemaining(a, .unlimited);
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, try child.wait(io));

    // argv[0] rewritten to the quoted target, the rest byte for byte
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "\"", echo, "\"", rest, "\nfrom stdin" }), out);
}

test "exelink --print, and making a link again retargets it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const link = try std.fs.path.join(a, &.{ dir, "l.exe" });
    const echo = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.echo, a);
    const exelink = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.exelink, a);
    try testing.expect((try run(a, &.{ exelink, link, "to", echo })).term.success());

    const t1 = try run(a, &.{ exelink, "--print", link });
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ echo, "\n" }), t1.stdout);

    // making a link over a link retargets it
    try testing.expect((try run(a, &.{ exelink, link, "to", exelink })).term.success());
    const t2 = try run(a, &.{ exelink, "--print", link });
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ exelink, "\n" }), t2.stdout);
    // and it runs the new target: exelink with no args prints usage, exits 1
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{link})).term);

    // a link from another template, as another version of exelink makes:
    // its first byte of code differs
    const img = try tmp.dir.readFileAlloc(io, "l.exe", a, .unlimited);
    const pe = std.mem.readInt(u32, img[0x3c..][0..4], .little);
    const nsections = std.mem.readInt(u16, img[pe + 6 ..][0..2], .little);
    const last = pe + 24 + std.mem.readInt(u16, img[pe + 20 ..][0..2], .little) + 40 * (nsections - 1);
    img[std.mem.readInt(u32, img[last + 20 ..][0..4], .little)] ^= 0xff;
    try tmp.dir.writeFile(io, .{ .sub_path = "l.exe", .data = img });
    const t3 = try run(a, &.{ exelink, "--print", link });
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ exelink, "\n" }), t3.stdout);
    const retargeted = try run(a, &.{ exelink, link, "to", echo });
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "updated ", link, " to ", echo, " (was ", exelink, ")\n" }), retargeted.stderr);

    // --print refuses what isn't a link
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--print", echo })).term);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--print", paths.template })).term);
}

test "exelink leaves a link that already runs TARGET untouched, even while it runs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const link = try std.fs.path.join(a, &.{ dir, "l.exe" });
    const echo = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.echo, a);
    const exelink = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.exelink, a);
    try testing.expect((try run(a, &.{ exelink, link, "to", echo })).term.success());

    // running, blocked reading stdin, so Windows locks l.exe
    var child = try std.process.spawn(io, .{ .argv = &.{link}, .stdin = .pipe, .stdout = .ignore, .create_no_window = false });
    defer child.kill(io);
    try testing.expect((try run(a, &.{ exelink, link, "to", echo })).term.success());
    // a different target has to rewrite it, which the lock refuses
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, link, "to", exelink })).term);
    child.stdin.?.close(io);
    child.stdin = null;
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, try child.wait(io));
}

test "exelink says on stderr whether it created, updated or left the link" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const link = try std.fs.path.join(a, &.{ dir, "l.exe" });
    const echo = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.echo, a);
    const exelink = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.exelink, a);

    const created = try run(a, &.{ exelink, link, "to", echo });
    try testing.expect(created.term.success());
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "created ", link, " to ", echo, "\n" }), created.stderr);

    const same = try run(a, &.{ exelink, link, "to", echo });
    try testing.expect(same.term.success());
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ link, " is already a link to ", echo, "\n" }), same.stderr);

    const updated = try run(a, &.{ exelink, link, "to", exelink });
    try testing.expect(updated.term.success());
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "updated ", link, " to ", exelink, " (was ", echo, ")\n" }), updated.stderr);

    // a file that isn't a link is refused and left alone, a wrong path most
    // likely, unless --force (-f)
    try tmp.dir.writeFile(io, .{ .sub_path = "other.exe", .data = "not a link" });
    const other = try std.fs.path.join(a, &.{ dir, "other.exe" });
    const refused = try run(a, &.{ exelink, other, "to", echo });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, refused.term);
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "exelink: '", other, "' exists and isn't an exelink, so it's left alone (--force replaces it)\n" }), refused.stderr);
    try testing.expectEqualStrings("not a link", try tmp.dir.readFileAlloc(io, "other.exe", a, .unlimited));
    const replaced = try run(a, &.{ exelink, "-f", other, "to", echo });
    try testing.expect(replaced.term.success());
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "created ", other, " to ", echo, " (replaced a file that isn't a link)\n" }), replaced.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, (try run(a, &.{other})).term);
    // --force is the long form
    try tmp.dir.writeFile(io, .{ .sub_path = "other.exe", .data = "not a link" });
    try testing.expect((try run(a, &.{ exelink, "--force", other, "to", echo })).term.success());
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, (try run(a, &.{other})).term);
}

/// A link to the probe (see test/probe/main.zig), in a temp dir.
fn probeLink(a: std.mem.Allocator, tmp: *testing.TmpDir) ![]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const link = try std.fs.path.join(a, &.{ dir, "probe-link.exe" });
    const probe = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.probe, a);
    try testing.expect((try run(a, &.{ paths.exelink, link, "to", probe })).term.success());
    return link;
}

test "the target sees its own path as when run directly, past MAX_PATH too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // two components: one can't exceed 255
    const deep = &@as([150]u8, @splat('d')) ++ "\\" ++ &@as([150]u8, @splat('d'));
    try tmp.dir.createDirPath(io, deep);
    try std.Io.Dir.cwd().copyFile(paths.probe, tmp.dir, "probe.exe", io, .{});
    try std.Io.Dir.cwd().copyFile(paths.probe, tmp.dir, deep ++ "\\probe.exe", io, .{});
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    for ([_][]const u8{ "", deep }) |sub| {
        const target = try std.fs.path.join(a, &.{ dir, sub, "probe.exe" });
        const link = try std.fs.path.join(a, &.{ dir, "l.exe" });
        try testing.expect((try run(a, &.{ paths.exelink, link, "to", target })).term.success());
        const r = try run(a, &.{ link, "self" });
        try testing.expect(r.term.success());
        // a path past MAX_PATH only runs as "\\?\"
        try testing.expectEqualStrings(if (target.len < 260) target else try std.mem.concat(a, u8, &.{ "\\\\?\\", target }), r.stdout);
    }
}

test "Ctrl+C reaches the target, and the link still exits with its exit code" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const link = try probeLink(a, &tmp);
    // a console of its own (create_no_window), so the Ctrl+C reaches only it,
    // the link and the target
    const r = try std.process.run(a, io, .{ .argv = &.{ paths.probe, "ctrlc", link }, .create_no_window = true });
    try testing.expectEqualStrings("link exited 0x7\n", r.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 7 }, r.term);
}

test "the target's manifest applies, as when run directly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // its manifest asks for the UTF-8 code page: first that Windows applies it
    // run directly, then through a link
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, (try run(a, &.{ paths.probe, "acp" })).term);
    const link = try probeLink(a, &tmp);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, (try run(a, &.{ link, "acp" })).term);
}

test "killing the link kills its target, and only it: not a process the target started" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const link = try probeLink(a, &tmp);
    const r = try run(a, &.{ paths.probe, "kill", link });
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

test "a detached link runs its target detached, without a console window" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const link = try probeLink(a, &tmp);
    const r = try run(a, &.{ paths.probe, "detached", link });
    try testing.expectEqualStrings("link exited 0xA\n", r.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 10 }, r.term);
}

test "the unpatched template crashes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const term = (try run(arena.allocator(), &.{paths.template})).term;
    switch (@import("builtin").cpu.arch) {
        // ud2: STATUS_ILLEGAL_INSTRUCTION, of which std keeps the low byte
        .x86_64, .x86 => try testing.expectEqual(std.process.Child.Term{ .exited = 0x1D }, term),
        // brk: the exact status is unverified, but it's no exit code of ours
        else => try testing.expect(!term.success()),
    }
}

test "exelink --unchecked links to a target that doesn't exist yet" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exelink = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.exelink, a);
    const ran = struct {
        fn f(al: std.mem.Allocator, argv: []const []const u8, in: []const u8) !std.process.RunResult {
            return std.process.run(al, io, .{ .argv = argv, .cwd = .{ .path = in }, .create_no_window = false });
        }
    }.f;

    // exelink refuses it, and writes nothing
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try ran(a, &.{ exelink, "l.exe", "to", "later\\t.exe" }, dir)).term);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "l.exe", .{}));

    // --unchecked stores a relative target as given, without looking at it.
    // Run from sub, so resolving against the cwd instead of LINK's directory
    // would look in sub\\later.
    try tmp.dir.createDirPath(io, "sub");
    const sub = try std.fs.path.join(a, &.{ dir, "sub" });
    try testing.expect((try ran(a, &.{ exelink, "--unchecked", "..\\l.exe", "to", "later\\.\\t.exe" }, sub)).term.success());
    const link = try std.fs.path.join(a, &.{ dir, "l.exe" });
    try testing.expectEqualStrings("later\\.\\t.exe\n", (try run(a, &.{ exelink, "--print", link })).stdout);

    // until the target exists, the link says so on stderr and exits with the
    // NTSTATUS (std keeps its low byte): first a missing directory, then a
    // missing file. The path is printed resolved, "." collapsed.
    const missing = try std.mem.concat(a, u8, &.{ link, ": can't find '", dir, "\\later\\t.exe': 0x800700" });
    const no_dir = try run(a, &.{link});
    try testing.expectEqual(std.process.Child.Term{ .exited = 0x03 }, no_dir.term); // ERROR_PATH_NOT_FOUND
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ missing, "03\n" }), no_dir.stderr);
    try tmp.dir.createDirPath(io, "later");
    const no_file = try run(a, &.{link});
    try testing.expectEqual(std.process.Child.Term{ .exited = 0x02 }, no_file.term); // ERROR_FILE_NOT_FOUND
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ missing, "02\n" }), no_file.stderr);
    try std.Io.Dir.cwd().copyFile(paths.echo, tmp.dir, "later\\t.exe", io, .{});
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, (try run(a, &.{link})).term);

    // retargeting: --unchecked accepts another missing path, plain exelink refuses one
    try testing.expect((try run(a, &.{ exelink, "--unchecked", link, "to", "Z:\\nope.exe" })).term.success());
    try testing.expectEqualStrings("Z:\\nope.exe\n", (try run(a, &.{ exelink, "--print", link })).stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, link, "to", "Z:\\nope.exe" })).term);

    // the flag can come anywhere; unknown ones are refused
    try testing.expect((try run(a, &.{ exelink, link, "to", "Z:\\other.exe", "--unchecked" })).term.success());
    try testing.expectEqualStrings("Z:\\other.exe\n", (try run(a, &.{ exelink, "--print", link })).stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--nope", link, "to", paths.echo })).term);
    // and so are --print with --unchecked or --force, a missing or other word for "to", and the wrong number of paths
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--print", "--unchecked", link })).term);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--print", "-f", link })).term);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--unchecked", link, "Z:\\other.exe" })).term);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--unchecked", link, "from", "Z:\\other.exe" })).term);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--print", link, link })).term);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, link })).term);
    // two paths without "to" could mean either order: the error spells out what the fix means
    const no_to = try run(a, &.{ exelink, link, "Z:\\other.exe" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, no_to.term);
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "exelink: missing \"to\": `exelink ", link, " to Z:\\other.exe` makes ", link, " a link to Z:\\other.exe\n" }), no_to.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{exelink})).term);
    // asked for, the usage goes to stdout and isn't an error
    const help = try run(a, &.{ exelink, "--help" });
    try testing.expect(help.term.success());
    try testing.expect(std.mem.startsWith(u8, help.stdout, "usage:"));
    // the link is untouched by all of these
    try testing.expectEqualStrings("Z:\\other.exe\n", (try run(a, &.{ exelink, "--print", link })).stdout);

    // rooted and drive-relative targets are ambiguous: refused
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--unchecked", link, "to", "\\t.exe" })).term);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, (try run(a, &.{ exelink, "--unchecked", link, "to", "C:t.exe" })).term);
}

test "a relative target resolves against the link's directory, and moves with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exelink = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.exelink, a);
    try tmp.dir.createDirPath(io, "a\\bin");
    try tmp.dir.createDirPath(io, "a\\tools");
    try std.Io.Dir.cwd().copyFile(paths.echo, tmp.dir, "a\\tools\\echo.exe", io, .{});

    // from tmp, where ..\\tools doesn't exist: checked against LINK's directory
    const created = try std.process.run(a, io, .{
        .argv = &.{ exelink, "a\\bin\\l.exe", "to", "..\\tools\\echo.exe" },
        .cwd = .{ .path = dir },
        .create_no_window = false,
    });
    try testing.expect(created.term.success());
    const l = try std.fs.path.join(a, &.{ dir, "a", "bin", "l.exe" });
    try testing.expectEqualStrings("..\\tools\\echo.exe\n", (try run(a, &.{ exelink, "--print", l })).stdout);
    // a relative link to it, started by it with an NT image path
    try testing.expect((try run(a, &.{ exelink, try std.fs.path.join(a, &.{ dir, "a", "bin", "l2.exe" }), "to", "l.exe" })).term.success());

    try tmp.dir.rename("a", tmp.dir, "moved", io);
    const echo = try std.fs.path.join(a, &.{ dir, "moved", "tools", "echo.exe" });
    for ([_][]const u8{ "l.exe", "l2.exe" }) |name| {
        const r = try run(a, &.{ try std.fs.path.join(a, &.{ dir, "moved", "bin", name }), "x" });
        try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, r.term);
        // argv[0] is the resolved target, ".." collapsed
        try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "\"", echo, "\" x\n" }), r.stdout);
    }
}

test "a target that isn't an exe: the link says it can't start it, and exits with the error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "t.exe", .data = "not an exe" });
    const target = try std.fs.path.join(a, &.{ dir, "t.exe" });
    const link = try std.fs.path.join(a, &.{ dir, "l.exe" });
    try testing.expect((try run(a, &.{ paths.exelink, link, "to", target })).term.success());
    const r = try run(a, &.{link});
    // ERROR_EXE_MACHINE_TYPE_MISMATCH (what Windows says for a text file), as an HRESULT
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ link, ": can't start '", target, "': 0x800700D8\n" }), r.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0xD8 }, r.term);
}

test "a command line too long for the target: the link says so, and exits with the NTSTATUS" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // a target path longer than the link's, so the link's longest command
    // line becomes too long once argv[0] is the target
    const deep: [200]u8 = @splat('d');
    try tmp.dir.createDirPath(io, &deep);
    try std.Io.Dir.cwd().copyFile(paths.echo, tmp.dir, deep ++ "\\echo.exe", io, .{});
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const target = try std.fs.path.join(a, &.{ dir, &deep, "echo.exe" });
    const link = try std.fs.path.join(a, &.{ dir, "l.exe" });
    try testing.expect((try run(a, &.{ paths.exelink, link, "to", target })).term.success());

    // "LINK" ARG: just under Windows' 32767, so CreateProcessW takes it
    const arg = try a.alloc(u8, 32760 - (link.len + 3));
    @memset(arg, 'x');
    const r = try run(a, &.{ link, arg });
    // STATUS_NAME_TOO_LONG
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ link, ": command line too long for '", target, "': 0xC0000106\n" }), r.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0x06 }, r.term);
}
