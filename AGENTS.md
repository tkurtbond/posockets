# AGENTS.md

posockets is an Oberon-2 library of TCP and Unix-domain sockets for
poc, the Peaseblossom Oberon Compiler, whose runtime has none. Its
first users are polibtls (`~/Repos/Oberon/polibtls`, an Oberon-2
binding to libtls) and, through both, a later Gemini server; it is meant
to serve any poc program that talks over a network. It works with poc's
cooperative `Tasks`, so one OS thread can serve many connections.
PLAN.md is the design and roadmap; this file is operational notes for
an agent working in this repo, not a design doc.

The split from polibtls was decided with the user on 2026-11-15:
polibtls deals only in descriptors and never imports posockets.
polibtls's PLAN.md, "Sockets: posockets", lists what it and the Gemini
server need from this library; PLAN.md here starts from that list.

Three sibling projects are this one's model; read their `AGENTS.md`
before redesigning anything, since most of their text is confirmed
behaviour of poc that applies here unchanged:

- **polibfyaml** (`~/Repos/Oberon/polibfyaml`): a poc library with a C
  part. Its `GNUmakefile`, tests, halt tests, valgrind setup and
  conventions are copied here.
- **pofltk** (`~/Repos/Oberon/pofltk`): its "Confirmed facts" (calling
  between Oberon and C, the collector) are the newest, checked up to
  poc 0.11.2, and its notes on testing on the BSD hosts apply when
  posockets is ported.
- **polibtls**: the first user. Keep the two plans in step: what
  polibtls finds it needs from sockets goes in this PLAN.md.

## Status

As of 2026-11-15, the repo holds only this file and PLAN.md. A probe
confirmed the mechanisms the design rests on (see "Confirmed facts").

## Reference material

| What | Where |
|---|---|
| poc | installed from the Peaseblossom RPM: `/usr/bin/poc` (0.12.0 on 2026-11-15), its runtime `poc-rtl` under `/usr/lib/poc`; `poc(1)`, `/usr/share/doc/peaseblossom/` |
| poc source | `~/Repos/Oberon/Peaseblossom` (`doc/users-guide.md`, `doc/reference-guide.md`, `doc/developer/language-extensions.md`) |
| poc's runtime | `~/Repos/Oberon/Peaseblossom/rtl/llvm/`: `Platform.Mod`/`.c` (descriptors, `errno`, signals), `Tasks.Mod`, `TaskWaiting.Mod`/`.c` (the `poll` loop), and `doc/developer/tasks.md` (the design of `Tasks`) |
| Oberon-2 report | `~/Reference/Computer/Languages/Oberon/Oberon2.pdf`; plain text `Oberon2-layout.text`, `Oberon2-no-layout.text` |
| Sockets API | the Linux man pages: `socket(7)`, `ip(7)`, `ipv6(7)`, `tcp(7)`, `unix(7)`, `getaddrinfo(3)`, `getnameinfo(3)`, `accept4(2)`, `connect(2)` (`EINPROGRESS`), `send(2)` (`MSG_NOSIGNAL`); POSIX for what the BSDs share |
| polibtls | `~/Repos/Oberon/polibtls` (the first user) |

## Build

Not written yet; PLAN.md, Phase 1. It will follow polibfyaml's
`GNUmakefile`: `make`, `make test`, `make valgrind`, `make clean`,
`make install`/`uninstall` into `POCLIBDIR` (`~/.local/lib/poc` by
default), with `POC` from `PATH`, output under `build/` via
`-output-dir`, `.NOTPARALLEL`, and `POC_LIBRARY_PATH` unexported so an
installed copy is never tested in place of this checkout. The library
links nothing beyond libc, so a program using posockets passes no
flags. polibtls's TCP tests take the installed library, so a change
here that polibtls depends on means `make install` before testing
there.

The integer size model is to be `-OC`, as in polibfyaml and polibtls
(PLAN.md, "Integer model"). The C part uses only `int32_t`, `int64_t`
and `intptr_t`, so its boundary means the same under either model.

## Test

Planned (PLAN.md, Phase 1 and "Testing"): one main module per concern
in `test/`, printing `ok   - <label>` / `FAIL - <label>` through a shared
`test/Check.Mod` and ending with `All checks passed.` or `<N> check(s)
failed.`; halt tests `test/Halt*.Mod` listed as `name:code`. **poc's
`ASSERT(x, n)` exits with status 10**, printing `assertion failed (n)`,
not with `n`.

Tests use only the loopback interface: TCP on `127.0.0.1` and `::1`
with port 0 (the kernel's choice, read back with `LocalAddress`), so
two runs never collide, and Unix-domain sockets in a directory under
`build/`. A test needing IPv6 skips, saying so, when `::1` can't be
bound. No test reaches outside the machine, and none needs a name
server: names resolved are `localhost` and numeric addresses.

Both sides of a connection run in one program, as tasks. A blocking
call stops every task, so a test that blocks runs its peer in a child
process instead.

Run every test under valgrind (`make valgrind`) with polibfyaml's
`test/poc-gc.supp` copied here, and check for descriptors left open
too: valgrind's `--track-fds=yes` lists them at exit, and a test may
check its own count through `/proc/self/fd`.

## Layout (planned)

- `src/Sockets.Mod`, `src/Sockets.c`: sockets, addresses, errors, and
  the calls that never wait (or wait in the kernel, in blocking mode).
  The C part does everything that touches `struct sockaddr`,
  `getaddrinfo`, socket options and `errno`, and hands Oberon only
  integers and text. The names stay unprefixed (PLAN.md, "Modules").
- `src/SocketTasks.Mod`: the same operations waiting through `Tasks`
  instead of in the kernel, and deadlines.
- `test/`, `examples/`: as polibfyaml's.
- `build/`: poc and clang output, and the tests' Unix-domain sockets
  (gitignored).
- `PLAN.md`: design, decisions, confirmed findings and open questions,
  by section. Append to the relevant section; mark a finished phase
  `[done]`, and strike through an open question once decided.

## Confirmed facts

Each was confirmed by a program that ran, with poc 0.12.0 on Fedora 44
(x86-64), on 2026-11-15 unless it says otherwise.

- **A module's C part works as in polibfyaml.** `Pair.c` beside
  `Pair.Mod` was compiled and linked with it by a plain `poc -OC
  Pair.Mod`; its function, labelled `__asm__("Pair.-make")`, was
  declared `PROCEDURE ["C", "Pair.-make"] Make(VAR fds: ARRAY OF
  SYSTEM.INT32): SYSTEM.INT32;`. A `VAR ARRAY OF SYSTEM.INT32` arrived
  as an `int32_t *`, and the C function's writes were seen in Oberon.
- **A socket descriptor works with `Tasks` and `Platform`.** With a
  `socketpair` from that C part, a task blocked in
  `Tasks.AwaitReadable(fd)` while the main program slept 50 ms, then
  woke when the main program wrote; `Platform.Write(fd, ...)` and
  `Platform.ReadBuf(fd, ...)` moved 5 bytes and returned 0.
  `Platform.FileHandle` is a `LONGINT` descriptor, the same type
  `Tasks.AwaitReadable` takes.
- **`Tasks` has no timeout on a descriptor wait** (`rtl/llvm/Tasks.Mod`,
  read 2026-11-15): `AwaitReadable`/`AwaitWritable` wait until the
  descriptor is ready, however long. A deadline needs another task to
  make it ready (PLAN.md, "Deadlines"). True of poc 0.12.0; the
  Peaseblossom checkout (commit 73109d2, 2026-11-15) adds
  `AwaitReadableFor`/`AwaitWritableFor`, not yet in a release.

### Carried from polibfyaml, pofltk and polibtls, not yet re-checked here

- **Exported `["C"]` procedures can be called from other modules**
  since poc 0.3.1; keep them unexported anyway and wrap each one.
- **No call chaining**: a function result isn't a designator.
- **Comments nest, and `*)` ends a comment anywhere.**
- **`ORD` takes a `CHAR` or a `SET`, not a `BOOLEAN`.** Never pass a
  `BOOLEAN` across the C boundary; use an `int32_t` 0 or 1.
- **The collector never sees pointers held only in C memory**, and
  scans the stack conservatively.
- **Finalizers run after the collection that finds an object
  unreachable, and for every registered object when the program ends.**
  posockets deliberately registers none on sockets (PLAN.md, "Sockets and closing").
- **A blocking call of any module stops every task**
  (`rtl/llvm/Tasks.Mod`'s module comment).
- **`Out` writes at once**; it buffers nothing.

## Conventions

- **Claim only what has been verified.** When a comment or decision
  depends on how Linux, libc or poc behaves, write a throwaway program,
  run it, and only then record the result: here under "Confirmed
  facts", and in PLAN.md. Throwaway programs go in a session directory
  under `/usr/local/sw/tmp` (`/tmp` is a RAM disk here), removed when
  done.
- **Portable by design, Linux first.** poc runs on Linux and the three
  BSDs; posockets is written and tested on Linux first, but uses only
  POSIX and the few extensions all four have (`accept4`,
  `SOCK_CLOEXEC`, `SOCK_NONBLOCK`), and keeps anything else in the C
  part behind an `#ifdef`, with a comment naming the system. Note in
  PLAN.md each such place, for the port.
- **The C part** takes and returns only `int32_t`, `int64_t` and
  `intptr_t`, mirrors no C struct as an Oberon record, retries `EINTR`
  itself, and reports failure as -1 with the `errno` value returned,
  never left in `errno` for Oberon to fetch later. Its functions are
  named `Sockets.-<name>` with `__asm__` labels.
- **Every descriptor is close-on-exec** (`SOCK_CLOEXEC`, `accept4`), so
  `Platform.System` never leaks one into a child.
- **Cleanup is idempotent.** `Close` sets the descriptor to -1, and does
  nothing if it is already -1.
- **Programmer errors halt** with the codes in PLAN.md, "Halt codes".
  Anything the network or the system does (a refused connection, a
  peer that resets, a name that doesn't resolve, too many open files)
  never halts; it comes back as a `BOOLEAN` result and an `Error`.
- **Comments explain why.**
- **Record decisions and findings in PLAN.md as they happen.**
- **Commit only when asked.** Commit messages are short and say why.
