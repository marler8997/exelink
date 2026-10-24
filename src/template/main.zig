//! template: the exe link template, a tiny exe link. Runs the target with this process's command line,
//! std handles and console, waits for it, and exits with its exit code.
//! ntdll, plus kernel32 for CreateProcessW; no std, no CRT: the entry point
//! is `start` (see build.zig for the link flags).
//!
//! The spawn is CreateProcessW, so the target runs as if started directly.
//! Not ntdll's RtlCreateUserProcessEx, though it's ~1 ms faster per launch
//! (measured, a link to a do-nothing exe: 7.2-7.7 ms median against 8.2-8.7):
//! it skips the CSR/SxS step where CreateProcessW builds the target's
//! activation context from its manifest, so the target's manifest was
//! ignored. Measured: a target whose manifest sets the UTF-8 code page got
//! the legacy one; the same goes for long-path and DPI awareness, common
//! controls v6, supportedOS, and requireAdministrator (it ran unelevated
//! instead of failing). CreateProcessW is also smaller here (-160 bytes):
//! it builds the process parameters and the console reference we built.
//!
//! This file builds the link template. `exelink` copies it, appends the
//! target's NT path ("\??\C:\...", UTF-16) to the end of its last section
//! (growing the section, so the path is mapped with the image), and writes
//! its RVA and length into the DOS header's reserved bytes (`DosHeader`): a
//! fixed offset, so no magic value to search for and no record in the image
//! (measured against a magic-tagged record found by searching: -32 bytes).
//! Reading it costs nothing at runtime and only the path's bytes are added.
//! Not a resource, though resource tools could then retarget a link: measured,
//! that cost +304 bytes (its own .rsrc section, which lld won't merge) and
//! ~0.15 ms per launch for the LdrFindResource_U lookup. A link runs far more
//! often than it's created or inspected, so that work is the CLI's. Not a
//! fixed buffer: that costs its whole size on disk (520 bytes for MAX_PATH)
//! and caps the path length.
//! argv[0] is replaced with the target's path; the rest of the command line
//! is passed through untouched.

const std = @import("std");
const windows = std.os.windows;

const UNICODE_STRING = windows.UNICODE_STRING;
/// CreateProcessW's limit, in UTF-16 units including the terminating 0
const max_command_line_len = 32767;

/// The DOS header (IMAGE_DOS_HEADER), mapped at the image base. `exelink
/// create` writes the target's location into e_res2, which Windows ignores
/// (offset 0x28, same in src/exelink/main.zig).
const DosHeader = extern struct {
    _: [0x28]u8,
    /// RVA of the target's path (UTF-16LE)
    target_rva: u32,
    /// in UTF-16 code units; 0 in an unpatched template
    target_len: u32,
};

/// JOBOBJECT_EXTENDED_LIMIT_INFORMATION
const JobLimits = extern struct {
    basic: extern struct {
        user_time_limits: [2]i64,
        flags: u32,
        working_set: [2]usize,
        process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    },
    io: [6]u64,
    memory: [4]usize,
};

/// PROCESS_INFORMATION
const ProcessInfo = extern struct {
    process: ?*anyopaque,
    thread: ?*anyopaque,
    ids: [2]u32,
};

/// Copies src to dst and returns the end of what it wrote. Not @memcpy: with
/// a runtime length it calls memcpy, which we don't have. Zig gets it from
/// compiler_rt, which we don't link (bundled, it needs more ntdll imports),
/// and importing ntdll's memcpy costs 96 bytes. On x86 and x86_64 `rep movsw`
/// (a loop is 32 bytes larger); elsewhere a loop through a volatile pointer,
/// so LLVM can't turn it back into a memcpy call.
fn copy(dst: [*]u16, src: []const u16) [*]u16 {
    switch (@import("builtin").cpu.arch) {
        .x86_64 => return asm volatile ("rep movsw"
            : [d] "={rdi}" (-> [*]u16),
            : [d_in] "{rdi}" (dst),
              [s_in] "{rsi}" (src.ptr),
              [n_in] "{rcx}" (src.len),
            : .{ .memory = true, .rsi = true, .rcx = true }),
        .x86 => return asm volatile ("rep movsw"
            : [d] "={edi}" (-> [*]u16),
            : [d_in] "{edi}" (dst),
              [s_in] "{esi}" (src.ptr),
              [n_in] "{ecx}" (src.len),
            : .{ .memory = true, .esi = true, .ecx = true }),
        else => {
            const d: [*]volatile u16 = dst;
            for (src, 0..) |c, i| d[i] = c;
            return dst + src.len;
        },
    }
}

/// Zeroes `p.*`. Not std.mem.zeroes: for a large struct it calls memset,
/// which we don't have; through a volatile pointer, LLVM can't make it one.
fn zero(p: anytype) void {
    const words: [*]volatile usize = @ptrCast(p);
    for (0..@sizeOf(@TypeOf(p.*)) / @sizeOf(usize)) |i| words[i] = 0;
}

/// Our command line with argv[0] replaced by "TARGET", the rest untouched.
///
/// Why: a program can find its own path from argv[0] or from Windows
/// (GetModuleFileNameW), which always returns the real exe. Passed through,
/// argv[0] would name this link while GetModuleFileNameW names the target,
/// and programs that trust argv[0] break: python sets sys.executable to the
/// link, and venvs record the link's directory as python's home. Rewritten,
/// both agree, as when the target is run directly. argv[0] was never reliable
/// as the invoked name anyway (cmd passes what was typed, e.g. "python").
/// What's lost: a target can't see the link's name, which only matters to
/// multi-call programs that dispatch on it (busybox-style).
/// Measured: +240 bytes, no measurable launch time (within 0.08 ms of 10 ms).
fn commandLine(cmd_us: UNICODE_STRING, target: []const u16) [*:0]u16 {
    const cmd = cmd_us.Buffer.?[0 .. cmd_us.Length / 2];
    // argv[0] has no escapes: quotes toggle, and unquoted whitespace ends it
    var i: usize = 0;
    var quoted = false;
    while (i < cmd.len) : (i += 1) {
        quoted = quoted != (cmd[i] == '"');
        if (!quoted and (cmd[i] == ' ' or cmd[i] == '\t')) break;
    }
    const dos = target[4..]; // without "\??\"
    const len = dos.len + 2 + cmd.len - i;
    if (len + 1 > max_command_line_len) fail(lenPrefixed("command line too long for"), dos, 0xC0000106); // STATUS_NAME_TOO_LONG
    const buf = alloc(len + 1);
    buf[0] = '"';
    const o = copy(buf + 1, dos);
    o[0] = '"';
    copy(o + 1, cmd[i..])[0] = 0;
    return buf[0..len :0];
}

/// How a link reports its own failures: a link exits with its target's exit
/// code, so when the link itself fails, the exit code alone can't say so (a
/// crashing target also exits with an NTSTATUS). The caller gets both: one
/// line on stderr, "LINK: WHAT 'PATH': 0xSTATUS", naming the link (the shell
/// ran it, so nothing else can), what it was doing and on what; and STATUS
/// as the exit code, for callers without stderr: the failing call's NTSTATUS,
/// or for CreateProcessW its Win32 error as an HRESULT (0x8007xxxx), so it
/// can't pass for a target's small exit code (ERROR_FILE_NOT_FOUND is 2).
/// Writing can fail too (no stderr, e.g. detached), and is best effort:
/// nothing else is left to report it to. Allocates nothing, so it can report
/// running out of memory. Written in pieces: building the line in one buffer
/// to write once measured larger (+48 bytes x86_64). what is length-prefixed (see lenPrefixed).
fn fail(what: [*]const u8, path: []const u16, status: u32) noreturn {
    @branchHint(.cold);
    writeWide(linkPath());
    write(": ");
    write(what[1..][0..what[0]]);
    if (path.len > 0) {
        write(" '");
        writeWide(path);
        write("'");
    }
    var hex = ": 0x00000000\n".*;
    for (hex[4..12], 0..) |*c, i| c.* = "0123456789ABCDEF"[status >> @intCast(28 - 4 * i) & 0xf];
    write(&hex);
    RtlExitUserProcess.get()(status);
}

/// s with its length in the first byte, for fail(): one pointer instead of
/// a slice's two words keeps fail()'s arguments in registers on x86_64, where
/// a fifth goes on the stack at each call (measured: -128 bytes). Not
/// 0-terminated: LLVM turns finding the end into a strlen call, which we lack.
fn lenPrefixed(comptime s: []const u8) [*]const u8 {
    return &([1]u8{s.len} ++ s[0..s.len].*);
}

fn write(bytes: []const u8) void {
    var iosb: [2]usize = undefined;
    _ = NtWriteFile.get()(windows.peb().ProcessParameters.hStdError, null, null, null, &iosb, bytes.ptr, @intCast(bytes.len), null, null);
}

/// Writes UTF-16 to stderr as UTF-8, in pieces through a stack buffer.
fn writeWide(w: []const u16) void {
    var utf8: [255]u8 = undefined;
    var rest = w;
    while (rest.len > 0) {
        // UTF-8 is at most 3 bytes per UTF-16 unit. Not between the halves of
        // a surrogate pair, which would each convert to U+FFFD.
        var n: usize = @min(rest.len, utf8.len / 3);
        if (n < rest.len and rest[n - 1] & 0xFC00 == 0xD800) n -= 1;
        var len: u32 = 0;
        _ = RtlUnicodeToUTF8N.get()(&utf8, utf8.len, &len, rest.ptr, @intCast(n * 2));
        write(utf8[0..len]);
        rest = rest[n..];
    }
}

/// This link's path, as a DOS path.
fn linkPath() []const u16 {
    const image = windows.peb().ProcessParameters.ImagePathName;
    const link_path = image.Buffer.?[0 .. image.Length / 2];
    // Started by another link with a long path: "\\?\C:\...". No length
    // check: it's at least "C:\x".
    return if (link_path[2] == '?') link_path[4..] else link_path;
}

/// Never freed: the process only lives until the target exits.
fn alloc(n: usize) [*]u16 {
    return @ptrCast(@alignCast(RtlAllocateHeap.get()(windows.peb().ProcessHeap, 0, n * 2) orelse fail(lenPrefixed("out of memory"), &.{}, 0xC0000017))); // STATUS_NO_MEMORY
}

/// A relative target's NT path: resolved against this link's directory each
/// run, so a link and its target can move together.
fn resolveRelative(rel: []const u16) []const u16 {
    const link_path = linkPath();
    var dir = link_path.len;
    while (dir > 0 and link_path[dir - 1] != '\\') dir -= 1;
    const len = dir + rel.len;
    const buf = alloc(len + 1);
    copy(copy(buf, link_path[0..dir]), rel)[0] = 0;
    var nt: UNICODE_STRING = undefined;
    // also collapses the ".." that the NT path wouldn't
    const status = RtlDosPathNameToNtPathName_U_WithStatus.get()(buf, &nt, null, null);
    if (status < 0) fail(lenPrefixed("can't resolve"), buf[0..len], @bitCast(status));
    return nt.Buffer.?[0 .. nt.Length / 2];
}

/// preserve_none on x86_64: it never returns, so saving the caller's registers
/// is wasted (measured: -16 bytes). Not aarch64: same file size there (page
/// padding), and untested. x86 has no such convention.
export fn start() callconv(switch (@import("builtin").cpu.arch) {
    .x86_64 => .{ .x86_64_preserve_none = .{} },
    else => .c,
}) noreturn {
    const peb = windows.peb();
    const link_params = peb.ProcessParameters;

    const dos: *const DosHeader = @ptrCast(@alignCast(peb.ImageBaseAddress));
    // Only `exelink`'s copies are links, so this is the template run
    // directly: a mistake, not an input to handle.
    if (dos.target_len == 0) @trap();
    var target: []const u16 = @as([*]const u16, @ptrCast(@alignCast(@as([*]const u8, @ptrCast(dos)) + dos.target_rva)))[0..dos.target_len];
    // an absolute target is stored as an NT path, a relative one as given
    if (target[0] != '\\') target = resolveRelative(target);
    const target_dos = target[4..]; // for messages: without "\??\"

    // A DOS path, 0-terminated. The target sees it as its own path
    // (GetModuleFileNameW), so "\\?\" only past MAX_PATH, where we need it.
    const app = if (target_dos.len < 260) target_dos else target;
    const image = alloc(app.len + 1);
    copy(image, app)[0] = 0;
    if (app.len != target_dos.len) image[1] = '\\'; // "\??\" -> "\\?\"
    const cmdline = commandLine(link_params.CommandLine, target);

    // The target is killed if we are (a timeout, a stop button, taskkill): in
    // a job closed when we exit, however we exit. Silent breakaway: only the
    // target is in it, not what the target starts. Made before the target, so
    // failing leaves nothing behind. Not
    // inheritable (no attributes): the target holding it would keep it open.
    var job: ?*anyopaque = undefined;
    const job_status = NtCreateJobObject.get()(&job, 0x1F003F, null); // JOB_OBJECT_ALL_ACCESS
    if (job_status < 0) fail(lenPrefixed("can't make a job for"), target_dos, @bitCast(job_status));
    var limits: JobLimits = undefined;
    zero(&limits);
    limits.basic.flags = 0x2000 | 0x1000; // KILL_ON_JOB_CLOSE, SILENT_BREAKAWAY_OK
    const limits_status = NtSetInformationJobObject.get()(job, 9, &limits, @sizeOf(JobLimits)); // JobObjectExtendedLimitInformation
    if (limits_status < 0) fail(lenPrefixed("can't make a job for"), target_dos, @bitCast(limits_status));

    // CreateProcessW, not RtlCreateUserProcessEx: see the top of this file
    var si: windows.STARTUPINFOW = undefined;
    zero(&si);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var child: ProcessInfo = undefined;
    // Suspended, so the Ctrl+C below is set only after the child copied our
    // console flags. No console: we were started detached, since a console exe
    // otherwise gets one, so the child is too, instead of opening a console
    // window. Inherits handles and gets our std handles, as from cmd.
    const flags: u32 = 0x4 | @as(u32, if (@intFromPtr(link_params.ConsoleHandle) == 0) 0x8 else 0); // CREATE_SUSPENDED, DETACHED_PROCESS
    if (CreateProcessW.get()(image[0..app.len :0], cmdline, null, null, 1, flags, null, null, &si, &child) == 0) {
        const err: u32 = @backingInt(windows.teb().LastErrorValue);
        fail(switch (err) {
            // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: the most common
            // failure, in words
            2, 3 => lenPrefixed("can't find"),
            740 => lenPrefixed("can't elevate to start"), // ERROR_ELEVATION_REQUIRED
            else => lenPrefixed("can't start"),
        }, target_dos, 0x80070000 | err); // HRESULT_FROM_WIN32
    }
    const process = child.process;

    // From here the child exists, so a failure must not leave it behind,
    // running or suspended, for a caller who was told we failed.

    // while it's suspended, so it can't start anything outside the job first
    const assign_status = NtAssignProcessToJobObject.get()(job, process);
    if (assign_status < 0) failChild(process, lenPrefixed("can't make a job for"), target_dos, @bitCast(assign_status));

    // Ctrl+C goes to every process on the console. The child decides what it
    // means; we keep waiting, so we exit with its exit code, not when it's
    // still running. Set after the child copied our ConsoleFlags, which it
    // inherits (bit 0, what SetConsoleCtrlHandler(NULL, TRUE) sets). Ctrl+Break
    // still ends us, and so the target (its job): ignoring it takes a handler
    // routine.
    link_params.ConsoleFlags |= 1;

    const resume_status = NtResumeThread.get()(child.thread, null);
    if (resume_status < 0) failChild(process, lenPrefixed("can't resume"), target_dos, @bitCast(resume_status));
    // STATUS_WAIT_0, or a failure (it has no timeout and isn't alertable)
    const wait_status = NtWaitForSingleObject.get()(process, 0, null);
    if (wait_status != 0) failChild(process, lenPrefixed("can't wait for"), target_dos, @bitCast(wait_status));
    // PROCESS_BASIC_INFORMATION, ExitStatus first
    var basic: [6]usize = undefined;
    const query_status = NtQueryInformationProcess.get()(process, 0, &basic, @sizeOf(@TypeOf(basic)), null);
    if (query_status < 0) fail(lenPrefixed("can't get the exit code of"), target_dos, @bitCast(query_status));
    RtlExitUserProcess.get()(@truncate(basic[0]));
}

/// fail() with the child still there: it's terminated first, with the same
/// status.
fn failChild(process: ?*anyopaque, what: [*]const u8, target: []const u16, status: u32) noreturn {
    @branchHint(.cold);
    _ = NtTerminateProcess.get()(process, status);
    fail(what, target, status);
}

/// Called as `X.get()(...)`: dllimport, so each call goes through the import
/// table (`call [__imp_X]`) instead of to a `jmp [__imp_X]` thunk lld adds
/// for each import, padded to 16 bytes. `is_dll_import` makes @extern a
/// runtime value, so it's made at each call, in an inline fn.
fn import(comptime dll: []const u8, comptime name: []const u8, comptime T: type) type {
    return struct {
        inline fn get() *const T {
            return @extern(*const T, .{ .name = name, .library_name = dll, .is_dll_import = true });
        }
    };
}
fn ntdll(comptime name: []const u8, comptime T: type) type {
    return import("ntdll", name, T);
}
const CreateProcessW = import("kernel32", "CreateProcessW", fn ([*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*anyopaque, ?[*:0]const u16, *windows.STARTUPINFOW, *ProcessInfo) callconv(.winapi) i32);
const NtCreateJobObject = ntdll("NtCreateJobObject", fn (*?*anyopaque, u32, ?*anyopaque) callconv(.winapi) i32);
const NtSetInformationJobObject = ntdll("NtSetInformationJobObject", fn (?*anyopaque, u32, *const anyopaque, u32) callconv(.winapi) i32);
const NtAssignProcessToJobObject = ntdll("NtAssignProcessToJobObject", fn (?*anyopaque, ?*anyopaque) callconv(.winapi) i32);
const NtTerminateProcess = ntdll("NtTerminateProcess", fn (?*anyopaque, u32) callconv(.winapi) i32);
const NtResumeThread = ntdll("NtResumeThread", fn (?*anyopaque, ?*u32) callconv(.winapi) i32);
const NtWaitForSingleObject = ntdll("NtWaitForSingleObject", fn (?*anyopaque, u8, ?*anyopaque) callconv(.winapi) i32);
const NtQueryInformationProcess = ntdll("NtQueryInformationProcess", fn (?*anyopaque, u32, *anyopaque, u32, ?*u32) callconv(.winapi) i32);
const RtlAllocateHeap = ntdll("RtlAllocateHeap", fn (?*anyopaque, u32, usize) callconv(.winapi) ?*anyopaque);
const RtlDosPathNameToNtPathName_U_WithStatus = ntdll("RtlDosPathNameToNtPathName_U_WithStatus", fn ([*]const u16, *UNICODE_STRING, ?*anyopaque, ?*anyopaque) callconv(.winapi) i32);
const NtWriteFile = ntdll("NtWriteFile", fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, *[2]usize, *const anyopaque, u32, ?*i64, ?*u32) callconv(.winapi) i32);
const RtlUnicodeToUTF8N = ntdll("RtlUnicodeToUTF8N", fn ([*]u8, u32, *u32, [*]const u16, u32) callconv(.winapi) i32);
const RtlExitUserProcess = ntdll("RtlExitUserProcess", fn (u32) callconv(.winapi) noreturn);
