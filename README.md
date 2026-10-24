# exelink

A windows exe that "links" (forwards invocations) to another exe.

It preserves the same arguments, stdin/stdout/stderr and console, and exits
with its exit code. Unlike a `.bat` wrapper, it's a real `.exe`, so tools that
look for the exe on `PATH` find it.

## Usage

```text
exelink [options] LINK to TARGET   make LINK, a small exe that runs TARGET
exelink --print LINK               print the TARGET that LINK runs
```

For example, python is installed in `C:\path\to`, which isn't on `PATH`, and
`C:\bin` is:

```bat
> C:\path\to\python.exe --version
Python 3.13.3
> python --version
'python' is not recognized as an internal or external command,
operable program or batch file.
> exelink C:\bin\python.exe to C:\path\to\python.exe
created C:\bin\python.exe to C:\path\to\python.exe
> python --version
Python 3.13.3
> exelink --print C:\bin\python.exe
C:\path\to\python.exe
```

`python` now runs `C:\bin\python.exe`, the link, which runs
`C:\path\to\python.exe` with the same arguments, stdin/stdout/stderr and
console, and exits with its exit code.

TARGET must exist, unless `--unchecked`. An absolute TARGET is stored resolved
(symlinks followed). A relative one is stored as given and resolved against
LINK's directory each time LINK runs, so a link and its target can move
together:

```bat
> exelink C:\tools\bin\python.exe to ..\python\python.exe
```

runs `C:\tools\python\python.exe`, and still finds it after `C:\tools` moves.

Running exelink on an existing link replaces it, so the same command retargets
a link; if it's already that exact link, it's left alone. Any other file at
LINK is refused (most likely a wrong path) unless `-f`/`--force`.

A link is the arch of the exelink that made it: each exelink embeds its own
arch's template. Use the machine's native one; an x86 link on x64 runs under
WOW64, ~2 ms slower per launch.

## Size

A link is the template plus its target's path (UTF-16):

| arch    | template |
|---------|----------|
| x86_64  | 2,816 bytes |
| aarch64 | 3,072 bytes |
| x86     | 2,368 bytes |

## Errors

A link exits with its target's exit code. If the link itself fails, it prints
one line on stderr naming the link, what it couldn't do and on what, and the
failing call's error code, and exits with that code: an NTSTATUS, or for
starting the target, its Win32 error as an HRESULT (`0x8007xxxx`), so it can't
pass for a small exit code of the target's:

```text
C:\bin\python.exe: can't find 'C:\path\to\python.exe': 0x80070002
```

Ctrl+C goes to the target as usual; the link keeps waiting, so it still exits
with the target's exit code (Ctrl+Break ends the link, and so its target). A
link started without a console (detached) starts its target without one too.
A link killed from outside (a timeout, a stop button, Task Manager) takes its
target with it.

## How it works

The link exe imports only ntdll and kernel32, with no CRT. It starts the
target with `CreateProcessW`, waits for it, and exits with its exit code.
argv[0] is replaced with the target's path, so the target sees its own path,
as if it were run directly. `exelink` appends the target's path to the
template's last section and records where it is in the DOS header.

`CreateProcessW`, not ntdll's `RtlCreateUserProcessEx`, though that's ~1 ms
faster per launch: it skips the step that applies the target's manifest, so
the target would lose what its manifest declares (UTF-8 code page, long-path
and DPI awareness, ...), and a target that requires elevation would run
unelevated. With `CreateProcessW`, that target fails with a message instead:
a link can't elevate.

## Scope

A link puts a console program on `PATH`. GUI programs work, but aren't
first-class: a link is always a console exe, so started from Explorer it opens
a console window, and it waits for its target, so a shell that runs it waits
too (run directly, a GUI program returns the shell's prompt at once). A link
doesn't copy its target's GUI subsystem, icon, or other resources.

## Comparison with alternatives

Ways to run a program by name when its directory isn't on `PATH`.

### Behavior

| Option | Found by `CreateProcess`/other tools | Target's sibling DLLs load | No admin needed | No extra process | Killing it kills the target | GUI targets | Survives target update |
|---|---|---|---|---|---|---|---|
| **exe shims:** exelink, Scoop shim, Chocolatey ShimGen | ✅ | ✅ | ✅ | ❌ (see Performance) | ⚠️ varies, see below | ⚠️ varies, see below | ✅ |
| Symlink (`mklink`) | ✅ | ❌ | ⚠️ admin or Developer Mode | ✅ | ✅ | ✅ | ✅ |
| Hard link (`mklink /H`) | ✅ | ❌ | ✅ (same volume only) | ✅ | ✅ | ✅ | ❌ |
| Copy of the exe | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `.bat`/`.cmd` wrapper | ❌ | ✅ | ✅ | ❌ (see Performance) | ❌ | ⚠️ opens console, waits | ✅ |
| App Paths registry key | ❌ (ShellExecute only) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Shell alias/function | ❌ (that shell only) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

- **Found by `CreateProcess`/other tools:** `CreateProcess("foo")` only appends
  `.exe`, so build tools, editors, `subprocess.run(["foo"])`, Go's `os/exec`,
  and similar callers won't find a `.bat`/`.cmd` wrapper. App Paths entries are
  only used by `ShellExecute` (Win+R, the Start menu, `start foo`), not by
  typing `foo` in cmd or PowerShell.
- **Target's sibling DLLs load:** a program run through a symlink, hard link,
  or copy sees the link's location as its own path and directory, so the DLLs
  and files next to the real exe aren't found. Most programs that aren't a
  single file break: python run through a hard link can't find its standard
  library.
- **Survives target update:** an update that replaces the exe with a new file
  leaves a hard link on the old file's contents, and a copy is never updated.
- **`.bat`/`.cmd` wrappers** also show the "Terminate batch job (Y/N)?" prompt
  on Ctrl+C, can mangle arguments containing `%`, `^`, `!` or quotes, and
  leave the target running when cmd is killed.
- **How the exe shims differ:**
  - Killing the shim (a timeout, a stop button, Task Manager): an exelink and a
    Scoop shim take the target with them (a job object); a ShimGen shim leaves
    it running.
  - GUI targets: an exelink opens a console and waits (see Scope); a Scoop
    shim's console flashes and closes, and it waits; ShimGen makes GUI shims
    (`--shimgen-gui`).
  - A target that requires elevation gets the UAC prompt through a Scoop shim
    (`ShellExecuteEx`); through an exelink it fails with a message (see Errors).
  - A Scoop shim ([kiennq/scoop-better-shimexe](https://github.com/kiennq/scoop-better-shimexe),
    usable without Scoop) is two files per command: the shim and a `.shim` text
    file naming the target, read on every launch, which can be edited to
    retarget it and can add default arguments. An exelink is one file.
  - ShimGen is closed-source and tied to Chocolatey. Its shims are .NET exes.

### Performance

Launching a do-nothing exe on an x64 machine, median of 3 runs of 200. CPU
cycles and memory are the shim's own process, not the target's: the target's
work is the same however it's started.

| | Launch time | Added | CPU cycles | Peak working set | Peak private | Shim size | Size of the tool that makes shims |
|---|---|---|---|---|---|---|---|
| the target directly | 3.6 ms | | | | | | |
| **exelink** | 9.1 ms | ~5.5 ms | 7.7 M | 3.6 MB | 0.5 MB | ~2.9 KB | 453 KB |
| Scoop shim | 15.2 ms | ~11.6 ms | 23 M | 8.8 MB | 1.4 MB | 158 KB, and the `.shim` file | none: a copy of `shim.exe` |
| Chocolatey ShimGen | 28.7 ms | ~25 ms | 84 M | 15.3 MB | 16.0 MB | 384 KB | 556 KB, and .NET's C# compiler |
| `.bat` wrapper (`cmd /c`) | 17.3 ms | ~13.7 ms | 27 M | 8.5 MB | 7.6 MB | a line of text | |

An exelink's 7.7 M cycles are mostly what starting any process costs: the
do-nothing target itself uses 4.8 M. Scoop shim v3.2.2, Chocolatey 2.7.4.

In short: for a single-file program with Developer Mode on, a symlink adds no
process and handles GUI targets. Otherwise, the exe shims are the options that
are real exes, load the target's DLLs and need no admin, and an exelink is the
smallest and quickest of those measured, while a Scoop shim can be retargeted
with a text editor and can elevate.