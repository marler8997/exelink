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
//!   probe kill LINK       runs `LINK tree NAME`, kills the link once the target
//!                         and its child are running, and exits 0 if the target
//!                         died with it and the target's child didn't
//!   probe tree NAME       runs `probe hang NAME-child`, then does what hang does
//!   probe hang NAME       holds mutex NAME-alive, signals event NAME-ready, and
//!                         exits once event NAME-done is set (or after 20 s)
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
    } else if (std.mem.eql(u8, mode, "hang") or std.mem.eql(u8, mode, "tree")) {
        if (args.len != 3) die("usage: probe {s} NAME", .{mode});
        const name = args[2];
        if (std.mem.eql(u8, mode, "tree")) {
            var buf: [32768]u16 = undefined;
            const n = GetModuleFileNameW(null, &buf, buf.len);
            if (n == 0) die("GetModuleFileNameW failed: {d}", .{GetLastError()});
            const self = try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]);
            const child = try std.fmt.allocPrint(a, "{s}-child", .{name});
            _ = spawn(a, try std.fmt.allocPrint(a, "\"{s}\" hang {s}", .{ self, child }), 0);
            if (WaitForSingleObject(openEvent(a, child, "ready"), 10_000) != 0) die("the child never got ready", .{});
        }
        // owned until we exit, when it's abandoned: how the driver sees we died
        _ = CreateMutexW(null, 1, try std.unicode.wtf8ToWtf16LeAllocZ(a, try std.fmt.allocPrint(a, "{s}-alive", .{name}))) orelse
            die("CreateMutexW failed: {d}", .{GetLastError()});
        if (SetEvent(openEvent(a, name, "ready")) == 0) die("SetEvent failed: {d}", .{GetLastError()});
        _ = WaitForSingleObject(openEvent(a, name, "done"), 20_000);
    } else if (std.mem.eql(u8, mode, "kill")) {
        if (args.len != 3) die("usage: probe kill LINK", .{});
        const name = try std.fmt.allocPrint(a, "exelink-probe-{d}", .{GetCurrentProcessId()});
        const child = try std.fmt.allocPrint(a, "{s}-child", .{name});
        const ready = createEvent(a, name, "ready");
        const done = createEvent(a, name, "done");
        _ = createEvent(a, child, "ready");
        const child_done = createEvent(a, child, "done");
        const link = spawn(a, try std.fmt.allocPrint(a, "\"{s}\" tree {s}", .{ args[2], name }), 0);
        if (WaitForSingleObject(ready, 10_000) != 0) die("the target never got ready", .{});
        const target_alive = openMutex(a, name);
        const child_alive = openMutex(a, child);
        // as a timeout or a stop button does
        if (TerminateProcess(link, 1) == 0) die("TerminateProcess failed: {d}", .{GetLastError()});
        _ = WaitForSingleObject(link, 10_000);
        // abandoned once the target is gone; still owned while the child runs
        const target_died = WaitForSingleObject(target_alive, 5_000) == 0x80; // WAIT_ABANDONED
        const child_lives = WaitForSingleObject(child_alive, 0) == 0x102; // WAIT_TIMEOUT
        _ = SetEvent(done);
        _ = SetEvent(child_done);
        if (!target_died) std.debug.print("probe: the target outlived the killed link\n", .{});
        if (!child_lives) std.debug.print("probe: the target's child died with the link\n", .{});
        std.process.exit(if (target_died and child_lives) 0 else 1);
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
        // Ignoring Ctrl+C is inherited, and some callers (Git Bash) start us
        // with it set: the link and target would ignore it too, as they
        // should, so clear it for them
        if (SetConsoleCtrlHandler(null, 0) == 0) die("SetConsoleCtrlHandler failed: {d}", .{GetLastError()});
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

fn eventName(a: std.mem.Allocator, name: []const u8, what: []const u8) [:0]const u16 {
    const s = std.fmt.allocPrint(a, "{s}-{s}", .{ name, what }) catch die("out of memory", .{});
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s) catch die("out of memory", .{});
}

/// manual reset, initially unset
fn createEvent(a: std.mem.Allocator, name: []const u8, what: []const u8) w.HANDLE {
    return CreateEventW(null, 1, 0, eventName(a, name, what)) orelse die("CreateEventW failed: {d}", .{GetLastError()});
}

fn openEvent(a: std.mem.Allocator, name: []const u8, what: []const u8) w.HANDLE {
    // SYNCHRONIZE | EVENT_MODIFY_STATE
    return OpenEventW(0x100002, 0, eventName(a, name, what)) orelse die("OpenEventW failed: {d}", .{GetLastError()});
}

fn openMutex(a: std.mem.Allocator, name: []const u8) w.HANDLE {
    return OpenMutexW(0x100000, 0, eventName(a, name, "alive")) orelse die("OpenMutexW failed: {d}", .{GetLastError()}); // SYNCHRONIZE
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
extern "kernel32" fn CreateMutexW(?*anyopaque, i32, [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn OpenMutexW(u32, i32, [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn TerminateProcess(w.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(w.HANDLE, *u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(?[*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*anyopaque, ?[*:0]const u16, *w.STARTUPINFOW, *ProcessInformation) callconv(.winapi) i32;
