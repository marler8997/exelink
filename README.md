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

For example, to put python on `PATH` (where `C:\bin` is on `PATH`):

```bat
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

## Speed

Launching a do-nothing target on an x64 machine (median of 3 runs of 200):

| how                 | time    |
|---------------------|---------|
| the target directly | ~3.5 ms |
| an exelink          | ~8.6 ms |
| a `.bat` wrapper    | ~17 ms  |

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