//! exelink: creates, inspects and edits exe links (see src/template/main.zig, and `usage`).
const std = @import("std");

const usage =
    \\usage:
    \\  exelink create [--unchecked] LINK TARGET   make LINK an exe that runs TARGET
    \\  exelink print-target LINK                  print the target LINK runs
    \\
    \\TARGET must exist unless --unchecked. An absolute TARGET is stored resolved
    \\(symlinks followed). A relative one is stored as given and resolved against
    \\LINK's directory each time LINK runs, so the two can move together.
    \\
    \\create replaces any existing LINK unless it's already this exact link,
    \\and says which it did on stderr.
    \\
;

/// The link template, template.exe, unpatched.
const template = @embedFile("template_exe");

/// Where the target's RVA and length (UTF-16 units) go, both u32: the DOS
/// header's reserved e_res2. Same value in src/template/main.zig.
const target_info = 0x28;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fatal("{s}", .{usage});
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "create")) {
        var unchecked = false;
        var positional: [2][]const u8 = undefined;
        var n: usize = 0;
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--unchecked")) {
                unchecked = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                fatal("unknown option '{s}'\n{s}", .{ arg, usage });
            } else {
                if (n == positional.len) fatal("{s}", .{usage});
                positional[n] = arg;
                n += 1;
            }
        }
        if (n != positional.len) fatal("{s}", .{usage});
        const link_path, const target_arg = positional;
        const relative = switch (std.fs.path.getWin32PathType(u8, target_arg)) {
            .drive_absolute => false,
            .relative => true,
            else => fatal("target '{s}': only drive-letter (C:\\...) or relative paths are supported", .{target_arg}),
        };
        const target = if (relative) blk: {
            const rel = try arena.dupe(u8, target_arg);
            std.mem.replaceScalar(u8, rel, '/', '\\');
            if (!unchecked) {
                const link_dir = std.fs.path.dirname(try std.fs.path.resolveAlloc(arena, &.{
                    try std.process.currentPathAlloc(io, arena), link_path,
                })).?;
                const full = try std.fs.path.join(arena, &.{ link_dir, rel });
                std.Io.Dir.cwd().access(io, full, .{}) catch |e|
                    fatal("target '{s}' ({s}): {s}", .{ target_arg, full, @errorName(e) });
            }
            break :blk rel;
        } else if (unchecked)
            // no syscalls on the target: it may not exist yet
            try std.fs.path.resolveAlloc(arena, &.{target_arg})
        else
            std.Io.Dir.cwd().realPathFileAlloc(io, target_arg, arena) catch |e|
                fatal("target '{s}': {s}", .{ target_arg, @errorName(e) });
        const link = try create(arena, target, relative);
        // A link is the template plus its target, so changing a link's target
        // is creating it anew; no separate `set`.
        // What LINK was, for the message; null if it didn't exist.
        const not_link = "a file that isn't an exelink";
        var was: ?[]const u8 = null;
        if (std.Io.Dir.cwd().readFileAlloc(io, link_path, arena, .limited(64 * 1024 * 1024))) |old| {
            // already this link: not rewritten, so it works while the link is
            // running (Windows locks a running exe) and keeps its timestamps
            if (std.mem.eql(u8, old, link)) {
                std.debug.print("exelink: link is already created: {s} -> {s}\n", .{ link_path, target });
                return;
            }
            was = if (readTarget(old)) |t| try std.fmt.allocPrint(arena, "{f}", .{fmtWtf16(t)}) else not_link;
        } else |e| switch (e) {
            error.FileNotFound => {},
            // bigger than any link
            error.StreamTooLong => was = not_link,
            else => fatal("read '{s}': {s}", .{ link_path, @errorName(e) }),
        }
        // fails if the link is running
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = link_path, .data = link }) catch |e|
            fatal("write '{s}': {s}", .{ link_path, @errorName(e) });
        if (was) |old|
            std.debug.print("exelink: link was updated: {s} -> {s} (was {s})\n", .{ link_path, target, old })
        else
            std.debug.print("exelink: link was created: {s} -> {s}\n", .{ link_path, target });
    } else if (std.mem.eql(u8, cmd, "print-target")) {
        if (args.len != 3) fatal("{s}", .{usage});
        const link = std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(64 * 1024 * 1024)) catch |e|
            fatal("read '{s}': {s}", .{ args[2], @errorName(e) });
        const target = readTarget(link) orelse fatal("'{s}' is not an exelink", .{args[2]});
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
        const err: ?error{WriteFailed} = blk: {
            stdout.interface.print("{f}\n", .{fmtWtf16(target)}) catch |e| break :blk e;
            stdout.interface.flush() catch |e| break :blk e;
            break :blk null;
        };
        if (err) |_| fatal("write stdout: {s}", .{@errorName(stdout.err.?)});
    } else fatal("unknown command '{s}'\n{s}", .{ cmd, usage });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("exelink: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn read32(img: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, img[off..][0..4], .little);
}
fn write32(img: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, img[off..][0..4], v, .little);
}

const Pe = struct {
    file_align: u32,
    sect_align: u32,
    size_of_image: usize, // offsets of these fields in the file
    last: usize, // the last section's header

    fn parse(img: []const u8) ?Pe {
        if (img.len < 0x40 or !std.mem.eql(u8, img[0..2], "MZ")) return null;
        const pe = read32(img, 0x3c);
        if (pe + 24 > img.len or !std.mem.eql(u8, img[pe..][0..4], "PE\x00\x00")) return null;
        const nsections = std.mem.readInt(u16, img[pe + 6 ..][0..2], .little);
        const opt_size = std.mem.readInt(u16, img[pe + 20 ..][0..2], .little);
        const opt = pe + 24;
        const sections = opt + opt_size;
        if (nsections == 0 or sections + 40 * nsections > img.len) return null;
        return .{
            .sect_align = read32(img, opt + 32),
            .file_align = read32(img, opt + 36),
            .size_of_image = opt + 56,
            .last = sections + 40 * (nsections - 1),
        };
    }
};

const template_pe = Pe.parse(template) orelse unreachable;

/// A copy of the template with `target` appended to its last section: an
/// absolute one as an NT path, a relative one as given (the template tells
/// them apart by the "\??\" prefix).
fn create(arena: std.mem.Allocator, target: []const u8, relative: bool) ![]u8 {
    const nt = try std.unicode.wtf8ToWtf16LeAlloc(arena, if (relative) target else try std.mem.concat(arena, u8, &.{ "\\??\\", target }));
    for (nt) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    // UNICODE_STRING lengths are u16 bytes, and the command line adds 2 quotes
    if (nt.len * 2 > 0xfffe - 8) fatal("target path is too long", .{});

    const p = template_pe;
    const va = read32(template, p.last + 12);
    const vsize = read32(template, p.last + 8);
    const raw_ptr = read32(template, p.last + 20);
    // the path goes at the end of the last section, which must end the file
    std.debug.assert(raw_ptr + read32(template, p.last + 16) == template.len);
    const off = std.mem.alignForward(u32, vsize, 2);
    const new_vsize: u32 = off + @as(u32, @intCast(nt.len * 2));
    const new_raw = std.mem.alignForward(u32, new_vsize, p.file_align);

    const out = try arena.alloc(u8, raw_ptr + new_raw);
    @memset(out, 0);
    @memcpy(out[0..template.len], template);
    @memcpy(out[raw_ptr + off ..][0 .. nt.len * 2], std.mem.sliceAsBytes(nt));
    write32(out, p.last + 8, new_vsize);
    write32(out, p.last + 16, new_raw);
    write32(out, p.size_of_image, std.mem.alignForward(u32, va + new_vsize, p.sect_align));
    write32(out, target_info, va + off);
    write32(out, target_info + 4, @intCast(nt.len));
    return out;
}

/// The target as given to create (an absolute one without the "\??\"
/// prefix, a relative one as stored), or null if `img` isn't a link. Checks
/// only what finding the target relies on, not the template's code, so links
/// from any version of exelink work.
fn readTarget(img: []const u8) ?[]align(1) const u16 {
    const p = Pe.parse(img) orelse return null;
    // u64: no overflow in the 32-bit exelink
    const va: u64 = read32(img, p.last + 12);
    const vsize: u64 = read32(img, p.last + 8);
    const raw: u64 = read32(img, p.last + 16);
    const raw_ptr: u64 = read32(img, p.last + 20);
    const rva: u64 = read32(img, target_info);
    const size = @as(u64, read32(img, target_info + 4)) * 2;
    // the target ends the last section's data, where create puts it
    if (size == 0 or rva < va or rva + size != va + vsize or vsize > raw or raw_ptr + raw > img.len) return null;
    const off: usize = @intCast(raw_ptr + rva - va);
    const t: []align(1) const u16 = std.mem.bytesAsSlice(u16, img[off..][0..@intCast(size)]);
    return if (t.len > 4 and t[0] == '\\' and t[1] == '?') t[4..] else t;
}

fn fmtWtf16(wtf16: []align(1) const u16) std.fmt.Alt([]align(1) const u16, writeWtf8) {
    return .{ .data = wtf16 };
}

/// WTF-16 as WTF-8: a valid path round-trips, even with unpaired surrogates.
fn writeWtf8(wtf16: []align(1) const u16, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < wtf16.len) : (i += 1) {
        var c: u21 = wtf16[i];
        if (std.unicode.utf16IsHighSurrogate(wtf16[i]) and i + 1 < wtf16.len and std.unicode.utf16IsLowSurrogate(wtf16[i + 1])) {
            c = std.unicode.utf16DecodeSurrogatePair(&.{ wtf16[i], wtf16[i + 1] }) catch unreachable;
            i += 1;
        }
        var b: [4]u8 = undefined;
        try w.writeAll(b[0 .. std.unicode.wtf8Encode(c, &b) catch unreachable]);
    }
}
