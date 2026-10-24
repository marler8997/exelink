//! Test target: prints its raw command line, a newline, then all of stdin,
//! and exits with 42, so a test can see exactly what a link passed through.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const cmd = std.os.windows.peb().ProcessParameters.CommandLine;
    const cmd8 = try std.unicode.wtf16LeToWtf8Alloc(a, cmd.Buffer.?[0 .. cmd.Length / 2]);
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(init.io, &buf);
    const in = try r.interface.allocRemaining(a, .unlimited);
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.mem.concat(a, u8, &.{ cmd8, "\n", in }));
    std.process.exit(42);
}
