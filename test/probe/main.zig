//! Test helper for how a link behaves around the console. It drives a link
//! and is also the link's target:
//!
//!   probe ctrlc LINK      runs `LINK ctrlc-target EVENT`, waits until the target
//!                         handles Ctrl+C, sends Ctrl+C to the console and exits
//!                         with the link's exit code. Run it in its own console.
//!   probe ctrlc-target E  handles Ctrl+C, signals event E, and exits 7 once
//!                         Ctrl+C arrives
//!   probe detached LINK   runs `LINK console` with DETACHED_PROCESS and exits
//!                         with the link's exit code
//!   probe console         exits 10 if it has no console window, 11 if it has one
//!   probe self            prints its own path, as GetModuleFileNameW gives it
//!
//! Any timeout or failed call exits 99 after saying what failed.
const std = @import("std");
const w = std.os.windows;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) die("usage: probe ctrlc LINK | ctrlc-target EVENT | detached LINK | console", .{});
    const mode = args[1];
    if (std.mem.eql(u8, mode, "self")) {
        var buf: [32768]u16 = undefined;
        const n = GetModuleFileNameW(null, &buf, buf.len);
        if (n == 0) die("GetModuleFileNameW failed: {d}", .{GetLastError()});
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]));
    } else if (std.mem.eql(u8, mode, "console")) {
        std.process.exit(if (GetConsoleWindow() == null) 10 else 11);
    } else if (std.mem.eql(u8, mode, "ctrlc-target")) {
        if (args.len != 3) die("usage: probe ctrlc-target EVENT", .{});
        if (SetConsoleCtrlHandler(&gotCtrlC, 1) == 0) die("SetConsoleCtrlHandler failed: {d}", .{GetLastError()});
        const ready = OpenEventW(0x0002, 0, try std.unicode.wtf8ToWtf16LeAllocZ(a, args[2])) orelse // EVENT_MODIFY_STATE
            die("OpenEventW failed: {d}", .{GetLastError()});
        if (SetEvent(ready) == 0) die("SetEvent failed: {d}", .{GetLastError()});
        var i: usize = 0;
        while (!ctrl_c.load(.acquire)) : (i += 1) {
            if (i == 1000) die("no Ctrl+C after 10 s", .{});
            Sleep(10);
        }
        std.process.exit(7);
    } else if (std.mem.eql(u8, mode, "ctrlc")) {
        if (args.len != 3) die("usage: probe ctrlc LINK", .{});
        // survive the Ctrl+C we send to our own console
        if (SetConsoleCtrlHandler(&gotCtrlC, 1) == 0) die("SetConsoleCtrlHandler failed: {d}", .{GetLastError()});
        const name = try std.fmt.allocPrint(a, "exelink-probe-{d}", .{GetCurrentProcessId()});
        const ready = CreateEventW(null, 1, 0, try std.unicode.wtf8ToWtf16LeAllocZ(a, name)) orelse
            die("CreateEventW failed: {d}", .{GetLastError()});
        const link = spawn(a, try std.fmt.allocPrint(a, "\"{s}\" ctrlc-target {s}", .{ args[2], name }), 0);
        if (WaitForSingleObject(ready, 10_000) != 0) die("the target never got ready", .{});
        if (GenerateConsoleCtrlEvent(0, 0) == 0) die("GenerateConsoleCtrlEvent failed: {d}", .{GetLastError()}); // CTRL_C_EVENT
        std.process.exit(wait(link));
    } else if (std.mem.eql(u8, mode, "detached")) {
        if (args.len < 3) die("usage: probe detached LINK [ARGS...]", .{});
        const rest = if (args.len > 3) try std.mem.join(a, " ", args[3..]) else "console";
        std.process.exit(wait(spawn(a, try std.fmt.allocPrint(a, "\"{s}\" {s}", .{ args[2], rest }), 0x8))); // DETACHED_PROCESS
    } else die("unknown mode '{s}'", .{mode});
}

const ProcessInformation = extern struct { hProcess: w.HANDLE, hThread: w.HANDLE, dwProcessId: u32, dwThreadId: u32 };

var ctrl_c: std.atomic.Value(bool) = .init(false);

fn gotCtrlC(event: u32) callconv(.winapi) i32 {
    if (event != 0) return 0; // CTRL_C_EVENT only
    ctrl_c.store(true, .release);
    return 1;
}

fn spawn(a: std.mem.Allocator, cmd: []const u8, flags: u32) w.HANDLE {
    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi: ProcessInformation = undefined;
    const cmd16 = std.unicode.wtf8ToWtf16LeAllocZ(a, cmd) catch die("out of memory", .{});
    if (CreateProcessW(null, cmd16, null, null, 0, flags, null, null, &si, &pi) == 0)
        die("CreateProcessW '{s}' failed: {d}", .{ cmd, GetLastError() });
    return pi.hProcess;
}

/// The process's exit code, low byte (what std reports to the test).
fn wait(process: w.HANDLE) u8 {
    if (WaitForSingleObject(process, 10_000) != 0) die("the link didn't exit within 10 s", .{});
    var code: u32 = undefined;
    if (GetExitCodeProcess(process, &code) == 0) die("GetExitCodeProcess failed: {d}", .{GetLastError()});
    // the full code, which a test can show when the low byte is unexpected
    std.debug.print("link exited 0x{X}\n", .{code});
    return @truncate(code);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("probe: " ++ fmt ++ "\n", args);
    std.process.exit(99);
}

extern "kernel32" fn GetModuleFileNameW(?*anyopaque, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?w.HWND;
extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
extern "kernel32" fn GenerateConsoleCtrlEvent(u32, u32) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(?*anyopaque, i32, i32, [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn OpenEventW(u32, i32, [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetEvent(w.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(w.HANDLE, *u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(?[*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*anyopaque, ?[*:0]const u16, *w.STARTUPINFOW, *ProcessInformation) callconv(.winapi) i32;
