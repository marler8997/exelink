const std = @import("std");

/// The architectures we ship. Never native: the exes are the same whichever
/// machine builds them.
const arches = [_]std.Target.Cpu.Arch{ .x86_64, .aarch64, .x86 };

pub fn build(b: *std.Build) void {
    const host = b.graph.host.result;
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "exelink.exe's optimization mode",
    ) orelse .small;
    const all = b.step("all", "Install exelink and template.exe for every arch, and the test tools");
    const test_step = b.step("test", "Run the tests, once for each arch this machine can run");

    var templates: [arches.len]std.Build.LazyPath = undefined;
    var exelinks: [arches.len]*std.Build.Step.Compile = undefined;
    for (arches, &templates, &exelinks) |arch, *template, *exelink_exe| {
        const target = windowsTarget(b, arch);
        template.* = addTemplate(b, target);
        all.dependOn(&b.addInstallBinFile(template.*, b.fmt("{t}/template.exe", .{arch})).step);

        // each exelink embeds its own arch's template, so it makes links
        // for the machine it runs on
        const exelink = b.createModule(.{
            .root_source_file = b.path("src/exelink/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exelink.addAnonymousImport("template_exe", .{ .root_source_file = template.* });
        exelink_exe.* = b.addExecutable(.{ .name = "exelink", .root_module = exelink });
        all.dependOn(&b.addInstallArtifact(
            exelink_exe.*,
            .{ .dest_dir = .{ .override = .{ .custom = b.fmt("bin/{t}", .{arch}) } } },
        ).step);
        if (host.os.tag == .windows and arch == host.cpu.arch) b.installArtifact(exelink_exe.*);
    }

    for (arches, templates, exelinks) |arch, template, exelink_exe| {
        // x64 Windows runs x86 (WOW64); arm64 Windows runs x64 and x86 (emulated)
        const runnable = host.os.tag == .windows and (arch == host.cpu.arch or arch == .x86 or
            (arch == .x86_64 and host.cpu.arch == .aarch64));
        if (!runnable) continue;
        const target = windowsTarget(b, arch);
        // what the tests run, see test/main.zig
        const paths = b.addOptions();
        for (arches, templates) |a, t| paths.addOptionPath(b.fmt("template_{t}", .{a}), t);
        paths.addOptionPath("template", template);
        paths.addOptionPath("exelink", exelink_exe.getEmittedBin());
        paths.addOptionPath("echo", b.addExecutable(.{
            .name = "echo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/echo/main.zig"),
                .target = target,
                .optimize = .ReleaseSmall,
            }),
        }).getEmittedBin());
        paths.addOptionPath("probe", b.addExecutable(.{
            .name = "probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/probe/main.zig"),
                .target = target,
                .optimize = .ReleaseSmall,
            }),
        }).getEmittedBin());
        const tests = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
        });
        tests.addOptions("paths", paths);
        // the template sizes the tests expect are README's
        tests.addAnonymousImport("readme", .{ .root_source_file = b.path("README.md") });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = b.fmt("test-{t}", .{arch}), .root_module = tests })).step);
    }

    // test tools, run on the machine that builds them
    all.dependOn(&b.addInstallArtifact(b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    }), .{}).step);
    all.dependOn(&b.addInstallArtifact(b.addExecutable(.{
        .name = "noop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/noop/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
        }),
    }), .{}).step);
}

fn windowsTarget(b: *std.Build, arch: std.Target.Cpu.Arch) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .windows, .abi = .gnu });
}

/// template.exe, the link template exelink patches: built as a bare object and
/// linked by hand with `zig lld-link`, because std.Build.Step.Compile can't
/// express three of the flags below:
///   /merge:.rdata=.text /merge:.pdata=.text /merge:.data=.text
///   /filealign:16 /align:16
/// Compile has no field for them and no raw linker-argument passthrough. Its
/// only free-form inputs, `linker_script` (--script) and the `link_z_*` fields
/// (-z), are ELF-only, and zig's lld COFF path adds -MERGE only for UEFI.
/// Everything else here has a Compile equivalent (entry, subsystem,
/// linker_dynamicbase, build_id with use_lld, no unwind tables). With only
/// those, the template was 3,072 bytes instead of 1,664 (x86_64, measured
/// then): a 512-byte-aligned .text and .rdata where this build has one
/// 16-byte-aligned section.
/// Linking ourselves also means making ntdll's import library, here from
/// a .def generated from `ntdll_imports`. Zig's mingw ntdll.def.in gives a
/// byte-identical exe, but only after a C-preprocessor step.
fn addTemplate(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const arch = target.result.cpu.arch;
    const obj = b.addObject(.{
        .name = "template",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/main.zig"),
            .target = target,
            // whatever -Doptimize says: its size is what a link costs, and
            // ReleaseFast is +256 bytes x86_64 and no faster (process creation
            // dominates a launch)
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .strip = true,
            .unwind_tables = .none,
            .stack_check = false,
            .stack_protector = false,
            .omit_frame_pointer = true,
        }),
        .use_llvm = true,
    });

    const link = b.addSystemCommand(&.{ b.graph.zig_exe, "lld-link" });
    link.addFileArg(obj.getEmittedBin());
    for (dlls) |dll| {
        var def: std.ArrayList(u8) = .empty;
        def.appendSlice(b.allocator, b.fmt("LIBRARY {s}.dll\nEXPORTS\n", .{dll})) catch @panic("OOM");
        for (imports) |imp| if (std.mem.eql(u8, imp[0], dll)) def.appendSlice(b.allocator, if (arch == .x86)
            b.fmt("{s}@{d}\n", .{ imp[1], imp[2] * 4 })
        else
            b.fmt("{s}\n", .{imp[1]})) catch @panic("OOM");
        const dlltool = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", switch (arch) {
            .x86_64 => "i386:x86-64",
            .aarch64 => "arm64",
            .x86 => "i386",
            else => unreachable,
        } });
        // -k: on x86 the import is named NtResumeThread, the symbol NtResumeThread@8
        if (arch == .x86) dlltool.addArg("-k");
        dlltool.addArg("-d");
        dlltool.addFileArg(b.addWriteFiles().add(b.fmt("{s}.def", .{dll}), def.items));
        dlltool.addArg("-l");
        link.addFileArg(dlltool.addOutputFileArg(b.fmt("{s}.lib", .{dll})));
    }
    // A bare 64-byte DOS header instead of lld's "can't run in DOS mode"
    // stub (-48 bytes): Windows only reads "MZ" and e_lfanew, which lld sets.
    // e_res2, where exelink writes the target's location, stays zero.
    var stub: [64]u8 = @splat(0);
    stub[0] = 'M';
    stub[1] = 'Z';
    link.addPrefixedFileArg("/stub:", b.addWriteFiles().add("stub.bin", &stub));
    const exe = link.addPrefixedOutputFileArg("/out:", "template.exe");
    link.addArgs(&.{
        "/entry:start",
        // even for a GUI target: links are for console programs (README's Scope)
        "/subsystem:console",
        "/nodefaultlib",
        "/build-id:no",
        "/debug:none",
        "/opt:ref",
        // a fixed TimeDateStamp, not the clock, so a rebuild gives the same
        // template and exelink still recognizes (and leaves alone) links made
        // before it. Not /Brepro: same effect, but its debug directory costs
        // 16-32 bytes. Nothing reads the timestamp (no bound imports).
        "/timestamp:0",
        // One section; exelink appends the target's path to it. Keep the
        // template free of writable globals: a .bss alongside these merges
        // crashes lld-link (zig 0.17.0, access violation).
        "/merge:.rdata=.text",
        "/merge:.pdata=.text",
        "/merge:.data=.text",
    });
    // Not on arm64, where Windows rejects sub-page section alignment (bad exe
    // format, even 512/512), so it keeps lld's 4096/512, the smallest that
    // loads, and requires ASLR (lld: "/dynamicbase:no is not compatible with
    // arm64").
    if (arch != .aarch64) link.addArgs(&.{
        // aligned to 16 for size. Page alignment is as fast.
        "/filealign:16",
        "/align:16",
        // only silences lld's "/align specified without /driver; image may
        // not run" (Windows runs it): the template is byte-identical
        "/driver",
        // no relocations: the image loads at its preferred base
        "/dynamicbase:no",
        "/fixed",
    });
    return exe;
}

const dlls = [_][]const u8{ "ntdll", "kernel32" };

/// What the template imports, with each function's number of arguments: x86's
/// stdcall decorates the symbol with their size (NtResumeThread@8). A wrong
/// count fails the x86 link (undefined symbol), so these can't drift from the
/// declarations in src/template/main.zig.
const imports = [_]struct { []const u8, []const u8, u32 }{
    .{ "kernel32", "CreateProcessW", 10 },
    .{ "ntdll", "NtTerminateProcess", 2 },
    .{ "ntdll", "NtResumeThread", 2 },
    .{ "ntdll", "NtWaitForSingleObject", 3 },
    .{ "ntdll", "NtQueryInformationProcess", 5 },
    .{ "ntdll", "RtlAllocateHeap", 3 },
    .{ "ntdll", "RtlDosPathNameToNtPathName_U_WithStatus", 4 },
    .{ "ntdll", "NtWriteFile", 9 },
    .{ "ntdll", "RtlUnicodeToUTF8N", 5 },
    .{ "ntdll", "RtlExitUserProcess", 1 },
};
