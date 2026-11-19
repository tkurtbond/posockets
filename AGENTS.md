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

As of 2026-11-15, Phases 1 (the skeleton), 2 (errors and addresses),
3 (blocking TCP), 4 (`SocketTasks`), 5 (deadlines), 6 (Unix-domain
sockets), 8 (examples and documentation) and 9 (the BSD port) are
done: the
build, the test and valgrind runners, and `Sockets` with its C part:
`Error`, `Address`, `Resolve`, `Pair`, `Close`, `LocalAddress`,
`PeerAddress`, `Listen`, `Accept`, `Connect`, `ConnectTo`,
`FinishConnect`, `Read`, `Write`, `WriteAll`, `Shutdown`,
`SetNonBlocking`, `Adopt`, `IgnoreBrokenPipe`, `BeginWait`/`EndWait`,
`Now`, `SetDeadline`, `TimeLeft`, `TimedOut`, `ListenUnix`,
`ConnectUnix`; and `SocketTasks`: `Accept`, `Connect`, `ConnectTo`,
`ConnectUnix` (all three with a time limit), `Read`,
`Write`, `WriteAll`, `LingeringClose`, waiting through `Tasks` until
the socket's deadline; the examples `EchoServer`, `EchoClient`,
`Netcat`, `Forward` and `FileServer`, each tested from outside; and the
reference in `doc/`; tested on Linux, FreeBSD, OpenBSD and NetBSD.
Phase 7, socket options, waits for a user to ask for one. Since
2026-11-16 `Sockets.Now`, and so the deadlines, take poDateTime's
monotonic clock (PLAN.md, "poDateTime's clock": Peaseblossom's
"Ongoing library enhancements" 7, step 3).

**poc 0.13.0 or later** (`Tasks.AwaitReadableFor`), **and poDateTime
built by the same poc.** This machine (atla) and the BSD hosts have
0.14.0 since 2026-11-16. A poc library works only with the poc that
built it, so the poDateTime the library needs (`PODATETIME`, default
`POCLIBDIR`) must come from the same poc; without it, make stops,
saying so. The copies of poDateTime and posockets in
`~/.local/lib/poc`, which polibtls and pogemini use, were installed
with 0.14.0 on 2026-11-16. After a poc upgrade, reinstall them, each
from a `git archive` of its commit by `make install`.

## Reference material

| What | Where |
|---|---|
| poc | installed from the Peaseblossom RPM: `/usr/bin/poc` (0.14.0 since 2026-11-16), its runtime `poc-rtl` under `/usr/lib/poc`; `poc(1)`, `/usr/share/doc/peaseblossom/` |
| poc source | `~/Repos/Oberon/Peaseblossom` (`doc/users-guide.md`, `doc/reference-guide.md`, `doc/developer/language-extensions.md`) |
| poc's runtime | `~/Repos/Oberon/Peaseblossom/rtl/llvm/`: `Platform.Mod`/`.c` (descriptors, `errno`, signals), `Tasks.Mod`, `TaskWaiting.Mod`/`.c` (the `poll` loop), and `doc/developer/tasks.md` (the design of `Tasks`) |
| poDateTime | `~/Repos/Oberon/poDateTime`: `Clocks.Monotonic`, a `Durations.Duration` in ns, which `Sockets.Now` takes in ms |
| Oberon-2 report | `~/Reference/Computer/Languages/Oberon/Oberon2.pdf`; plain text `Oberon2-layout.text`, `Oberon2-no-layout.text` |
| Sockets API | the Linux man pages: `socket(7)`, `ip(7)`, `ipv6(7)`, `tcp(7)`, `unix(7)`, `getaddrinfo(3)`, `getnameinfo(3)`, `accept4(2)`, `connect(2)` (`EINPROGRESS`), `send(2)` (`MSG_NOSIGNAL`); POSIX for what the BSDs share |
| polibtls | `~/Repos/Oberon/polibtls` (the first user) |

## Build

`GNUmakefile`, adapted from polibfyaml's: `make`, `make test`, `make
valgrind`, `make clean`,
`make install`/`uninstall` into `POCLIBDIR` (`~/.local/lib/poc` by
default), with `POC` from `PATH`, output under `build/` via
`-output-dir`, `.NOTPARALLEL`, and `POC_LIBRARY_PATH` unexported so an
installed copy is never tested in place of this checkout. `LIBMODS`
lists the library's modules, and `LIBSRC` takes each one's C part
(`src/<Module>.c`) if it has one. The library
links nothing beyond libc and poDateTime, so a program using posockets
passes no flags, though poDateTime must be on its library path.
poDateTime comes from `PODATETIME` (default `POCLIBDIR`), after
`build/lib` on the library path, so an installed posockets there never
hides this checkout's. polibtls's TCP tests take the installed library, so a change
here that polibtls depends on means `make install` before testing
there.

The integer size model is `-OC`, as in polibfyaml and polibtls
(PLAN.md, "Integer model"). The C part uses only `int32_t`, `int64_t`
and `intptr_t`, so its boundary means the same under either model.

## Test

PLAN.md, "Testing": one main module per concern
in `test/`, printing `ok   - <label>` / `FAIL - <label>` through a shared
`test/Check.Mod` and ending with `All checks passed.` or `<N> check(s)
failed.`, listed in `TESTS`; halt tests `test/Halt*.Mod` listed in
`HALTTESTS` as `name:code`. **poc's `ASSERT(x, n)` exits with status
10**, printing `assertion failed (n)`, not with `n`; `make test`
requires both. **poc rejects an `ASSERT` whose condition is the
constant `FALSE`** ("ASSERT condition is always FALSE"), so a halt test
must reach its `ASSERT` with a value known only when it runs. Each
test runs from `test/`, with standard input `/dev/null`.

Tests use only the loopback interface: TCP on `127.0.0.1` and `::1`
with port 0 (the kernel's choice, read back with `LocalAddress`), so
two runs never collide, and Unix-domain sockets in a directory under
`build/`. A test needing IPv6 skips, saying so, when `::1` can't be
bound. No test reaches outside the machine, and none needs a name
server: names resolved are `localhost` and numeric addresses.

Both sides of a connection run in one program, as tasks. A blocking
call stops every task, so a test that blocks runs its peer in a child
process instead.

`make valgrind` runs every test under valgrind with polibfyaml's
`test/poc-gc.supp` and `test/vg-reachable.sh` copied here (the latter
also accepting the memory glibc's loader keeps for the NSS modules
`getaddrinfo` loads with `dlopen`), and
`--track-fds=yes`; `test/vg-fds.sh` fails a test that leaves a
descriptor open (more open at exit than it inherited, less the two of
Tasks' self-pipe, which it allows). A test may also check its own count
with `TestHelp.OpenFds` (`fcntl(F_GETFD)` on each descriptor below the
limit; the BSDs have no usable `/proc/self/fd`); one using tasks calls `Tasks.WakeDescriptor`
first, so the self-pipe is already counted. Every test, tasks or not,
runs under full memcheck, without `--error-exitcode` (valgrind counts
the self-pipe's descriptors as errors): `test/vg-errors.sh` passes a
log only if its errors are all descriptors. A test whose log needs a
suppression of its own has it in `test/<name>.supp`
(`TestFileServer.supp`: the collector's conservative scan of task
stacks).

## Testing on the BSD hosts

Phase 9 ran `gmake test` on FreeBSD 15.1 amd64 (alerik), OpenBSD 7.9
i386 (cymoril) and amd64 (jherek), and NetBSD 11.0 amd64 (artos) and
i386 (yishana), each with poc 0.13.0, and again with 0.14.0 for the
move to poDateTime's clock (2026-11-16); rackhir (FreeBSD) builds
packages, so ask before using it. Log in by `ssh <host>`, put
`/usr/pkg/bin:/usr/local/bin` on `PATH`, and use `gmake`. Copy the
working tree there (`tar` less `build/` and `.git`) into a directory
under `~/tmp`, with poDateTime from a `git archive`, installed by
`gmake install POCLIBDIR=<dir>` there and passed as `gmake test
PODATETIME=<dir>`; remove it all when done, and never work in a
checkout on the host. There is no valgrind there. Judge a run by make's exit status
and count `assertion failed` lines as well as `FAIL`: a test that
halts prints no `FAIL` (`TestUnix` hid a halt this way).

## Layout

- `src/Sockets.Mod`, `src/Sockets.c`: sockets, addresses, errors, and
  the calls that never wait (or wait in the kernel, in blocking mode).
  The C part does everything that touches `struct sockaddr`,
  `getaddrinfo`, socket options and `errno`, and hands Oberon only
  integers and text. The names stay unprefixed (PLAN.md, "Modules").
- `src/SocketTasks.Mod`: the same operations waiting through `Tasks`
  instead of in the kernel, and (Phase 5) deadlines. No C part.
- `test/`: `Check.Mod`, the tests and halt tests, `poc-gc.supp`,
  `vg-reachable.sh`, `vg-fds.sh`. `TestHelp.Mod`/`.c`: what tests need
  that the library doesn't offer (a `poll` with a timeout, `SO_LINGER`
  0, a small send or receive buffer, `sun_path`'s size, the descriptor
  limit and count). Helper programs a test runs as a
  child (`BlockingPeer`, `TooManyFiles`) are listed in `HELPERS` and
  built into `build/` before the tests. `Run.Mod`: starts a program
  in the background, its output in `build/`, reads the port a server
  prints first, and waits for its exit status; `TestEcho`,
  `TestNetcat`, `TestForward` and `TestFileServer` use it to drive the
  examples, with the other side as tasks in the test.
- `examples/`: `EchoServer`, `EchoClient`, `Netcat`, `Forward`,
  `FileServer` (PLAN.md, Phase 8), listed in `EXAMPLEPROGS` and built
  before the tests against the library in `build/`. Each server prints
  `port <n>` as its first line and takes a count of connections to
  serve before exiting. `EXAMPLES` (programs compared with an
  `.expected` file) is empty.
- `doc/`: `Sockets.md` and `SocketTasks.md`, the reference, made by
  `doc/mkref.py` from the source with `make doc` and committed. Edit
  the comments in `src/`, never the `.md`; run `make doc` after
  changing an exported declaration or its comment. mkref.py reads the
  layout the sources keep (a comment just above each declaration,
  procedures grouped under one-line `(* Heading *)` comments), not
  Oberon in general.
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
  `AwaitReadableFor`/`AwaitWritableFor`, not yet in a release, which
  Phase 5 uses.

- **valgrind's `--track-fds=yes` reports `FILE DESCRIPTORS: <n> open
  (<m> inherited) at exit.`** (valgrind 3.27.1), not `(3 std)` as older
  versions did. A test program run by make inherits 0, 1 and 2 (3 open,
  3 inherited); a descriptor opened in C and left open made it 4 open,
  3 inherited, and was listed with the stack that opened it. Hence
  `test/vg-fds.sh` compares the two numbers rather than expecting 3.
- **poc rejects `ASSERT(FALSE, n)`** at compile time ("ASSERT condition
  is always FALSE"); `b := FALSE; ASSERT(b, n)` compiles, and halts with
  status 10 and `assertion failed (n)`.
- **An open array reaches a `["C"]` procedure as its first element's
  address alone**, in any mode, so `Sockets` passes `LEN` beside it
  (`host: ARRAY OF CHAR; hostLen: SYSTEM.ADDRESS`); a `VAR` scalar
  (`VAR port: SYSTEM.INT32`) arrives as a pointer. Used throughout
  `Sockets.c`, checked by `TestAddress`.
- **`SYSTEM.INT64` is not assignable to `LONGINT`**, even under `-OC`
  where both are 64 bits ("argument is not assignment compatible ...
  SYSTEM.INT64 to LONGINT"); convert with `SYSTEM.VAL(LONGINT, x)`.
  `SYSTEM.INT32` to `INTEGER` is accepted.
- **glibc's `EAI_` codes are negative** (`EAI_NONAME` = -2,
  `EAI_SYSTEM` = -11). `getaddrinfo` with no `AI_ADDRCONFIG` gives
  `::1` then `127.0.0.1` for `localhost` and for a `NULL` host.
- **`getaddrinfo` leaves memory still reachable at exit**: glibc
  `dlopen`s the NSS modules and keeps them, so valgrind shows the
  loader's blocks with stacks through `dl-open.c`.
- **A library with no C part and no procedures** builds with `poc
  -library`, installs with `-install-library`, and a program built with
  `-library-path` at the install directory takes it from there, not
  from source (`make install` into a scratch directory, then a program
  built against it; checked 2026-11-15).

- **A test module's C part is compiled with it**: `TestHelp.c` beside
  `test/TestHelp.Mod`, imported through `-import-path test`, was
  compiled and linked by a plain `poc` of the test.
- **glibc declares `accept4` only with `_GNU_SOURCE`**; `Sockets.c`
  defines it under `#ifdef __linux__`.
- **A blocking `connect` to a loopback listener completes before any
  `accept`** (from the backlog), so a test can connect to its own
  listener in one program.
- **With no descriptor free, `accept4` fails with `EMFILE` and the
  connection stays queued**; it is accepted once one is freed.
- **valgrind 3.27.1 doesn't enforce a lowered `RLIMIT_NOFILE`**:
  `getrlimit` reports the new limit, but descriptors go on being made
  past it. A check that needs the limit runs in a child program, which
  valgrind doesn't follow (`TooManyFiles`).
- **Standard input isn't always `/dev/null`**: under the Claude Code
  Bash tool it is a socket, so a test that needs a non-socket opens
  `/dev/null` itself. `make test` gives each test `/dev/null`.
- **`Platform.System` returns the wait status**: 0 when the command
  exits 0, otherwise its exit code × 256.

- **memcheck follows poc's coroutines** since Peaseblossom's bug 21
  was fixed (2026-11-15), so the task tests get full memcheck (PLAN.md,
  2026-11-18). Before it, it reported millions of uninitialised values
  on their stacks, and they ran under `--tool=none`.
- **valgrind 3.27.1 counts each descriptor open at exit as an error**
  for `--error-exitcode`, with `--track-fds=yes`; so `make valgrind`
  doesn't use it, and `test/vg-errors.sh` requires the errors to be
  exactly the descriptors.
- **The collector's conservative scan of a task's stack can make
  memcheck report `Value8` in `DrainMarkStack`**, when a word never
  written happens to point at a live block (`TestFileServer`, 22 of
  them). It goes in that test's own `.supp`, not `poc-gc.supp`: the
  same report from a record copied whole into the heap is a real bug.
- **Tasks keeps a self-pipe**: two descriptors, opened in
  `TaskWaiting.-pipe` the first time the program waits idle, or by
  `Tasks.WakeDescriptor()` (in poc 0.12.0), and never closed.
- **Loopback's socket buffers are large enough that 300 KB never
  blocked**: `send` never returned `EAGAIN`. Asking for 4096-byte
  `SO_SNDBUF`/`SO_RCVBUF` gave hundreds of waits (`strace`); so does
  `SO_SNDBUF` alone (`TestHelp.SmallSendBuffer`), which is all the
  tests now shrink, since a small `SO_RCVBUF` stalls the BSDs.
- **A record field may refer to a type declared later only as `POINTER
  TO` it** (`target: POINTER TO Address`); a named pointer type
  declared later is rejected.
- **`Shutdown(shutBoth)` from one task wakes another's
  `AwaitReadable`** on the same TCP socket, and the read then gives end
  of stream; two tasks, one reading and one writing, wait on one socket
  together (`TestTasks`).
- **`Tasks.AwaitReadableFor`/`AwaitWritableFor` work on sockets**
  (the checkout's poc, Phase 5): on a Unix-domain pair and on TCP over
  `127.0.0.1`, `TRUE` as soon as data comes, `FALSE` after the limit
  (100 ms gave 100-101 ms), and with 0 ms a single look; an untimed
  wait still works after a timeout.
- **A loopback connect past a full listen queue hangs on Linux**:
  with backlog 0, one connection queues and later SYNs are dropped
  (`tcp_syncookies` = 1, `tcp_abort_on_overflow` = 0), so the connect
  neither completes nor is refused. `TestDeadline` times out a connect
  this way. NetBSD and OpenBSD do the same (OpenBSD after 81);
  FreeBSD resets the connect at once (below).
- **A poc library is tied to the `Tasks` it was built against**: a
  program built with the checkout's poc refused the copy in
  `~/.local/lib/poc` built by 0.12.0, saying to rebuild posockets. A
  throwaway program built with that poc takes this tree from source
  instead: `-clear-library-path -library-path <prefix>/lib/poc
  -import-path ~/Repos/Oberon/posockets/src`.
- **Unix-domain sockets on Linux** (Phase 6; the BSDs differ, below):
  `sun_path` is 108 bytes, and a 107-byte path binds. With backlog 0 one connection
  queues; a second non-blocking connect fails with `EAGAIN`, nothing in
  progress, and `poll(POLLOUT)` returns at once (`POLLOUT|POLLHUP`), so
  waiting on it is useless: `SocketTasks.ConnectUnix` sleeps and
  retries. A blocking connect to a full queue waits. A stale socket
  file gives `ECONNREFUSED`, no file `ENOENT`, binding over a file
  `EADDRINUSE`. An accepted unnamed peer comes back with an empty host.
- **`TestUnix` puts its socket files in `../build`** (tests run from
  `test/`) and removes them, before and after, with `Platform.Unlink`.
- **A `Close` with unread data from the peer resets the connection,
  and the peer loses what it hadn't read yet**: `FileServer`, closing
  after reading only a request's head, made `TestFileServer`'s client,
  which had sent 100,000 bytes more, get `recv: Connection reset by
  peer` instead of the response. `SocketTasks.LingeringClose` fixes it.
- **poc's `-show-interface` prints a module's declarations without
  their comments**, so `doc/` is made from the source by `mkref.py`
  instead.

### On the BSDs (Phase 9)

Confirmed on 2026-11-15 with poc 0.13.0 on FreeBSD 15.1, OpenBSD 7.9
and NetBSD 11.0 (alerik, cymoril, jherek, artos, yishana), by
throwaway C programs or the tests:

- **On i386 under `-OC`, `LEN` doesn't fit `SYSTEM.ADDRESS`**: `LEN`
  is a 64-bit `LONGINT`, an `ADDRESS` 32 bits, and passing one to the
  other fails ("LONGINT to SYSTEM.ADDRESS"). `SYSTEM.INT64` takes it,
  as does `SYSTEM.VAL(SYSTEM.ADDRESS, LEN(s))`; `Sockets` passes lengths
  as `SYSTEM.INT64`.
- **A small `SO_RCVBUF` on a connected TCP socket stalls the BSDs**:
  with 4096 bytes asked for on both ends, large transfers in
  `TestEcho`, `TestNetcat`, `TestForward` and `TestFileServer` stopped
  until their 20 s deadlines; with only `SO_SNDBUF` small, they pass.
  Linux copes with either.
- **The BSDs' loopback delivers a moment after `send`**: a read on the
  other end straight after can find nothing; Linux's has it there.
- **The loopback interface is `lo0`**, so a scope id is `%lo0`.
- **FreeBSD and OpenBSD have no `/proc/self/fd`**, and NetBSD's gave a
  wrong count; `fcntl(fd, F_GETFD)` works on all four.
- **NetBSD's resolver keeps a `kqueue`** after looking up
  `nonexistent.invalid` (`ktrace`): a descriptor that is never closed.
- **A full TCP listen queue**: FreeBSD queues two with backlog 0 or 1
  and resets the next connect at once (`ECONNRESET` from `connect`, and
  as `SO_ERROR`); OpenBSD queues 81 with backlog 0 (`kern.sominconn`
  80) and then hangs the next, as NetBSD does after one.
- **A full Unix-domain queue**: FreeBSD and NetBSD queue backlog + 1
  and refuse the next at once with `ECONNREFUSED`; OpenBSD queued all
  of 200 tried with backlog 0.
- **`sun_path` is 104 bytes**, so the longest path is 103.
- **`accept4(l, ..., SOCK_CLOEXEC)` from a non-blocking listener gives
  a blocking, close-on-exec socket**, as on Linux.
- **`shutdown` on a listener**: FreeBSD returns `ENOTCONN` but shuts
  it, and `accept` then gives `ECONNABORTED`; OpenBSD returns 0 and the
  same; NetBSD returns 0, `poll` says readable, and `accept` gives
  `EAGAIN` (Linux: 0, `POLLHUP`, `EINVAL`). `Sockets.Shutdown` halts on
  a listener anyway.
- **poc's runtime changes no signal's disposition or mask** (Linux and
  the BSDs, poc 0.13.0): a probe read them all at start and after tasks
  waited on sockets. Under `ssh` the BSDs show `SIGTSTP`, `SIGTTIN` and
  `SIGTTOU` ignored, but a plain C program does too: it is inherited.
- **Any poll event wakes a task's descriptor wait**, `POLLERR` alone
  included (`TaskWaiting.Ready` takes any nonzero `revents`). Only Linux
  gave `POLLERR`: alone on a connected UDP socket after an ICMP
  port-unreachable, and with `POLLIN|POLLHUP` for a TCP reset or a
  refused connect. The BSDs report the same errors as `POLLIN`, with
  `POLLHUP` on FreeBSD and OpenBSD; a refused connect awaited for
  writing is `POLLOUT|POLLHUP` on FreeBSD, `POLLHUP` alone on OpenBSD,
  `POLLOUT` on NetBSD. The error is in `SO_ERROR`, or from the next
  `recv`, which clears `SO_ERROR`.
- **FreeBSD usually refuses a non-blocking loopback connect at once**:
  `ECONNREFUSED` from `connect` 197 times in 200, `EINPROGRESS` the
  other 3.
- **`MSG_NOSIGNAL`, `accept4`, `SOCK_CLOEXEC`, `SOCK_NONBLOCK`** are in
  all three, with no feature macro; `TestErrors`' write to a reset peer
  gives `EPIPE` or `ECONNRESET`, never `SIGPIPE`.
- **FreeBSD's delayed ACK (`net.inet.tcp.delacktime` 40) makes a 4096-byte
  send buffer slow**: 100,000 bytes took about 3 s over loopback, longer
  than `FileServer`'s 2 s linger. And on FreeBSD a plain `Close` with
  unread data didn't lose the answer `TestFileServer` waits for, as it
  does on Linux.

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
