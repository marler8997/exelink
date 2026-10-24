//! bench N COMMAND_LINE...
//! Runs each COMMAND_LINE N times with CreateProcessW (std handles to NUL),
//! round-robin so background noise hits every command equally, after 5 warmup
//! rounds, and prints min/median/mean in ms for each.
//! Command lines are passed as-is, so "python.bat" style commands need "cmd /c".
const std = @import("std");
const w = std.os.windows;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) {
        std.debug.print("usage: bench N COMMAND_LINE...\n", .{});
        std.process.exit(1);
    }
    const n = try std.fmt.parseInt(usize, args[1], 10);
    const cmds = args[2..];

    var sa: SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
    const nul = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), 0x40000000, 3, &sa, 3, 0, null); // GENERIC_WRITE, OPEN_EXISTING

    var freq: i64 = undefined;
    _ = QueryPerformanceFrequency(&freq);

    const times = try a.alloc([]f64, cmds.len);
    const cmds16 = try a.alloc([:0]u16, cmds.len);
    for (cmds, 0..) |cmd, c| {
        times[c] = try a.alloc(f64, n);
        cmds16[c] = try std.unicode.wtf8ToWtf16LeAllocZ(a, cmd);
    }
    const buf = try a.alloc(u16, 32768);
    var i: usize = 0;
    while (i < n + 5) : (i += 1) {
        for (cmds16, 0..) |cmd, c| {
            var si = std.mem.zeroes(w.STARTUPINFOW);
            si.cb = @sizeOf(w.STARTUPINFOW);
            si.dwFlags = w.STARTF_USESTDHANDLES;
            si.hStdInput = nul;
            si.hStdOutput = nul;
            si.hStdError = nul;
            var pi: PROCESS_INFORMATION = undefined;
            // CreateProcessW may write to the command line buffer
            @memcpy(buf[0 .. cmd.len + 1], cmd[0 .. cmd.len + 1]);
            var start: i64 = undefined;
            var end: i64 = undefined;
            _ = QueryPerformanceCounter(&start);
            if (0 == CreateProcessW(null, @ptrCast(buf.ptr), null, null, 1, 0, null, null, &si, &pi)) {
                std.debug.print("CreateProcess failed for '{s}': {}\n", .{ cmds[c], GetLastError() });
                std.process.exit(1);
            }
            _ = WaitForSingleObject(pi.hProcess, 0xffffffff);
            _ = QueryPerformanceCounter(&end);
            var code: u32 = undefined;
            _ = GetExitCodeProcess(pi.hProcess, &code);
            if (code != 0) {
                std.debug.print("'{s}' exited with {}\n", .{ cmds[c], code });
                std.process.exit(1);
            }
            _ = CloseHandle(pi.hProcess);
            _ = CloseHandle(pi.hThread);
            if (i >= 5) times[c][i - 5] = @as(f64, @floatFromInt(end - start)) * 1000.0 / @as(f64, @floatFromInt(freq));
        }
    }
    for (cmds, times) |cmd, t| {
        std.mem.sort(f64, t, {}, std.sort.asc(f64));
        var sum: f64 = 0;
        for (t) |x| sum += x;
        std.debug.print("min {d:6.2}  median {d:6.2}  mean {d:6.2} ms  {s}\n", .{ t[0], t[n / 2], sum / @as(f64, @floatFromInt(n)), cmd });
    }
}

const SECURITY_ATTRIBUTES = extern struct { nLength: u32, lpSecurityDescriptor: ?*anyopaque, bInheritHandle: i32 };
const PROCESS_INFORMATION = extern struct { hProcess: w.HANDLE, hThread: w.HANDLE, dwProcessId: u32, dwThreadId: u32 };
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*SECURITY_ATTRIBUTES, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn CreateProcessW(?[*:0]const u16, ?[*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*anyopaque, ?[*:0]const u16, *w.STARTUPINFOW, *PROCESS_INFORMATION) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(w.HANDLE, *u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;
