//! exelink: creates, inspects and edits exe links (see src/template/main.zig, and `usage`).
const std = @import("std");

const usage = "exelink " ++ @embedFile("version") ++ "\n\n" ++
    \\usage:
    \\  exelink [options] LINK to TARGET   make LINK, a small exe that runs TARGET
    \\  exelink --print LINK               print the TARGET that LINK runs
    \\
    \\options:
    \\  --unchecked   don't require TARGET to exist
    \\  -f, --force   replace a file at LINK that isn't a link
    \\
    \\Supports relative paths to the LINK.
    \\
    \\example:
    \\  exelink C:\bin\python.exe to C:\Python313\python.exe
    \\
;

/// The link template, template.exe, unpatched.
const template = @embedFile("template_exe");

/// Where the target's RVA and length (bytes of WTF-8) go, both u32: the DOS
/// header's reserved e_res2. Same value in src/template/main.zig.
const target_info = 0x28;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 1) {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
    var unchecked = false;
    var print = false;
    var force = false;
    var positional: [3][]const u8 = undefined;
    var n: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStdout(io, "{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "--unchecked")) {
            unchecked = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--print")) {
            print = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fatal("unknown option '{s}'", .{arg});
        } else {
            if (n == positional.len) fatal("expected LINK to TARGET, got more: '{s}'", .{arg});
            positional[n] = arg;
            n += 1;
        }
    }
    if (print) {
        if (unchecked) fatal("--unchecked is for making a link, not for --print", .{});
        if (force) fatal("--force is for making a link, not for --print", .{});
        if (n != 1) fatal("--print takes one path, LINK, got {d}", .{n});
        const link = std.Io.Dir.cwd().readFileAlloc(io, positional[0], arena, .limited(64 * 1024 * 1024)) catch |e|
            fatal("read '{s}': {s}", .{ positional[0], @errorName(e) });
        const target = readTarget(link) orelse fatal("'{s}' is not an exelink", .{positional[0]});
        writeStdout(io, "{f}\n", .{target});
    } else {
        // "to" says which path is which, so they can't be swapped by mistake
        // "to" says which path is the link: say what's missing with the
        // user's own paths, since two paths alone could mean either order
        switch (n) {
            0 => fatal("expected LINK to TARGET", .{}),
            1 => fatal("expected LINK to TARGET, got only '{s}'", .{positional[0]}),
            2 => if (std.mem.eql(u8, positional[1], "to"))
                fatal("expected TARGET after '{s} to'", .{positional[0]})
            else
                fatal("missing \"to\": `exelink {s} to {s}` makes {s} a link to {s}", .{ positional[0], positional[1], positional[0], positional[1] }),
            else => if (!std.mem.eql(u8, positional[1], "to"))
                fatal("expected \"to\" between LINK and TARGET, got '{s}'", .{positional[1]}),
        }
        const link_path, _, const target_arg = positional;
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
        // What LINK was, for the message.
        const Was = union(enum) { nothing, link: Target, file };
        var was: Was = .nothing;
        if (std.Io.Dir.cwd().readFileAlloc(io, link_path, arena, .limited(64 * 1024 * 1024))) |old| {
            // already this link: not rewritten, so it works while the link is
            // running (Windows locks a running exe) and keeps its timestamps
            if (std.mem.eql(u8, old, link)) {
                std.debug.print("{s} is already a link to {s}\n", .{ link_path, target });
                return;
            }
            was = if (readTarget(old)) |t| .{ .link = t } else if (force) .file else notLink(link_path);
        } else |e| switch (e) {
            error.FileNotFound => {},
            // bigger than any link
            error.StreamTooLong => was = if (force) .file else notLink(link_path),
            else => fatal("read '{s}': {s}", .{ link_path, @errorName(e) }),
        }
        // fails if the link is running
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = link_path, .data = link }) catch |e|
            fatal("write '{s}': {s}", .{ link_path, @errorName(e) });
        switch (was) {
            .nothing => std.debug.print("created {s} to {s}\n", .{ link_path, target }),
            .link => |old| std.debug.print("updated {s} to {s} (was {f})\n", .{ link_path, target, old }),
            .file => std.debug.print("created {s} to {s} (replaced a file that isn't a link)\n", .{ link_path, target }),
        }
    }
}

fn writeStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const err: ?error{WriteFailed} = blk: {
        stdout.interface.print(fmt, args) catch |e| break :blk e;
        stdout.interface.flush() catch |e| break :blk e;
        break :blk null;
    };
    if (err) |_| fatal("write stdout: {s}", .{@errorName(stdout.err.?)});
}

/// LINK exists and isn't a link: a wrong path, most likely, so it's kept.
fn notLink(link_path: []const u8) noreturn {
    fatal("'{s}' exists and isn't an exelink, so it's left alone (--force replaces it)", .{link_path});
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

/// the control characters
const ctl = blk: {
    var c: [32]u8 = undefined;
    for (&c, 0..) |*x, i| x.* = i;
    break :blk c;
};

const template_pe = Pe.parse(template) orelse unreachable;

/// A copy of the template with `target` appended to its last section, as
/// WTF-8: an absolute one as an NT path, a relative one as given (the template
/// tells them apart by the "\??\" prefix).
fn create(arena: std.mem.Allocator, target: []const u8, relative: bool) ![]u8 {
    const nt = try std.mem.concat(arena, u8, &.{ if (relative) "" else "\\??\\", target });
    std.mem.replaceScalar(u8, nt, '/', '\\');
    // the template decodes it unchecked
    const len16 = std.unicode.calcWtf16LeLen(nt) catch fatal("target '{s}' isn't valid WTF-8", .{target});
    // UNICODE_STRING lengths are u16 bytes, and the command line adds 2 quotes
    if (len16 * 2 > 0xfffe - 8) fatal("target path is too long", .{});

    // +2: the line ends before and after it
    if (nt.len + 2 > target_room) fatal("target path is too long", .{});

    const p = template_pe;
    const va = read32(template, p.last + 12);
    const off = read32(template, p.last + 16);
    const raw_ptr = read32(template, p.last + 20);
    // the path goes after the last section's data, which must end the file
    if (raw_ptr + off != template.len) @panic("the template's last section doesn't end the file");
    // The file ends with the path, on a line of its own, so it shows as the
    // last line in a text editor and can be edited there. The section is
    // declared `target_room` larger than the file holds, for a longer path:
    // Windows maps what the file has, and zeroes after it.
    const size = std.mem.alignForward(u32, off + target_room, p.file_align);
    // That's with sections aligned below a page (x86, x86_64). Aligned to
    // pages (aarch64), Windows refuses a file shorter than the section's raw
    // size, so that ends where the path starts: Windows still maps the file
    // up to the next multiple of the file alignment, so the line can grow to
    // there (511 bytes), and is cut off past it. Measured on x86_64 linked
    // like aarch64; not run on arm64.
    const raw_size = if (p.sect_align < 4096) size else off + 1;
    const out = try std.mem.concat(arena, u8, &.{ template, "\n", nt, "\n" });
    write32(out, p.last + 8, size);
    write32(out, p.last + 16, raw_size);
    write32(out, p.size_of_image, std.mem.alignForward(u32, va + size, p.sect_align));
    write32(out, target_info, va + off + 1);
    return out;
}

/// The most bytes a link's last line can grow to, line ends included.
const target_room = 0x10000;

/// A link's target as stored: WTF-8, or WTF-16 in links made by an exelink
/// from before it stored WTF-8.
const Target = union(enum) {
    wtf8: []const u8,
    wtf16: []align(1) const u16,

    pub fn format(t: Target, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (t) {
            .wtf8 => |s| try w.writeAll(s),
            .wtf16 => |s| try writeWtf8(s, w),
        }
    }
};

/// The target as given to create (an absolute one without the "\??\"
/// prefix, a relative one as stored), or null if `img` isn't a link. Checks
/// only what finding the target relies on, not the template's code, so links
/// from any version of exelink work.
fn readTarget(img: []const u8) ?Target {
    const p = Pe.parse(img) orelse return null;
    // u64: no overflow in the 32-bit exelink
    const va: u64 = read32(img, p.last + 12);
    const vsize: u64 = read32(img, p.last + 8);
    const raw: u64 = read32(img, p.last + 16);
    const raw_ptr: u64 = read32(img, p.last + 20);
    const rva: u64 = read32(img, target_info);
    const len: u64 = read32(img, target_info + 4);
    if (rva < va or rva >= va + vsize) return null;
    const off: usize = @intCast(raw_ptr + rva - va);
    if (len == 0) {
        // the file's last line, as the template reads it: up to a control
        // character or the end of the file
        if (rva == 0 or off >= img.len) return null;
        const rest = img[off..];
        const t = rest[0 .. std.mem.indexOfAny(u8, rest, &ctl) orelse rest.len];
        return .{ .wtf8 = if (std.mem.startsWith(u8, t, "\\??\\")) t[4..] else t };
    }
    // before that, UTF-16 ending the last section's data, with its length
    if (vsize > raw or raw_ptr + raw > img.len) return null;
    if (rva + len * 2 == va + vsize) {
        const t: []align(1) const u16 = std.mem.bytesAsSlice(u16, img[off..][0..@intCast(len * 2)]);
        return .{ .wtf16 = if (t.len > 4 and t[0] == '\\' and t[1] == '?') t[4..] else t };
    }
    return null;
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
