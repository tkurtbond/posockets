# PLAN.md

posockets: an Oberon-2 library of TCP and Unix-domain sockets for poc,
the Peaseblossom Oberon Compiler, working with poc's cooperative
`Tasks`. AGENTS.md has the operational notes; this file is the design,
the decisions and the roadmap. Append to the relevant section as work
goes; mark a finished phase `[done]`, and strike through an open
question once it is decided, saying what was decided and when.

## Goal and scope

poc's runtime can read and write a descriptor (`Platform`) and wait for
one (`Tasks.AwaitReadable`/`AwaitWritable`), but it cannot make a
socket. posockets fills that gap, small and portable:

- **TCP**, IPv4 and IPv6: listen, accept, connect, read, write,
  shutdown, close; local and peer addresses as text.
- **Names**: `getaddrinfo` for the host, so `localhost`,
  `example.org` and `::1` all work.
- **Unix-domain stream sockets** and `socketpair`.
- **Two ways to wait**: blocking calls for simple programs, and
  non-blocking calls that wait through `Tasks`, for servers that serve
  many connections in one OS thread. Without `Tasks`, a non-blocking
  call reports that it would block, so a program with its own `poll`
  loop can still use the library.
- **Deadlines** on the `Tasks` waits, since a server must drop a client
  that stops sending (Deadlines, below).
- **`SIGPIPE`**: a way to ignore it process-wide (I/O, below).

Not in scope, at least at first: UDP and other datagram sockets, raw
sockets, multicast, out-of-band data, descriptor passing over
Unix-domain sockets, an asynchronous resolver (Names, below), and TLS
(that is polibtls, which takes posockets' descriptors).

Linux first; then the BSDs that poc supports (AGENTS.md,
"Conventions"). VAX/VMS, which poc also targets, is out of scope.

## Users

**polibtls** (`~/Repos/Oberon/polibtls`): its PLAN.md, "Sockets:
posockets", lists what it needs, and is this plan's starting point:

- `Listen(host, port, backlog, VAR listeners)`: one descriptor per
  address family, `SO_REUSEADDR`, `IPV6_V6ONLY`; port 0 and reading the
  chosen port back.
- `Accept`, with the peer's address as text; `Connect(host, port)`.
- Non-blocking mode, `Close`, `Shutdown(how)`, `Pair` (`socketpair`).
- `IgnoreBrokenPipe`.
- Accept and connect waiting through `Tasks`.
- Descriptors as `LONGINT`; errors a `BOOLEAN` result and an error with
  `errno` and its text, never a halt.

All of it is planned below; where the shape differs (a `Socket` object
rather than a bare descriptor), polibtls takes the descriptor from
`s.fd`. polibtls never imports posockets; it gets descriptors, and
whoever made a descriptor closes it.

**The Gemini server** (a later project): listens on port 1965 on both
families, accepts in a task per listener, hands each connection to
polibtls, reads a request of at most 1024 bytes with a deadline, and
writes a response. It may also want a plain TCP or Unix-domain listener
behind a proxy. Its needs beyond polibtls's go here as they appear.

## Design

### Modules

- **`Sockets`** (`src/Sockets.Mod`, with its C part `src/Sockets.c`):
  the `Socket` and `Address` types, errors, names, and every operation,
  blocking or not. It imports only `SYSTEM` and `Platform`, never
  `Tasks`, so a program that doesn't use tasks doesn't link them.
- **`SocketTasks`** (`src/SocketTasks.Mod`): `Accept`, `Connect`,
  `Read`, `Write`, `WriteAll` that wait through `Tasks` on a
  non-blocking socket, and deadlines. Pure Oberon over `Sockets`.

A thin/thick split as in polibfyaml and polibtls would add little: the
C part is already the thin layer, small and private, because the
sockets API is made of structs (`sockaddr_*`, `addrinfo`) that Oberon
should not mirror. The C part turns them into integers and text.

The names stay `Sockets` and `SocketTasks`, unprefixed (decided
2026-11-15): they read well at every call site, poc's runtime has no
module by either name, and posockets is meant for poc only, so a clash
would be with Peaseblossom's own runtime, which can avoid it.

### Integer model

`-OC`, as in polibfyaml and polibtls: `INTEGER` 32 bits, `LONGINT` 64.
Descriptors are `LONGINT`, as `Platform.FileHandle` and
`Tasks.AwaitReadable` have them. Ports are `INTEGER`. Byte counts are
`LONGINT`. The C part declares everything with explicit widths
(`SYSTEM.INT32`, `SYSTEM.INT64`, `SYSTEM.ADDRESS`), so it means the same
under either model.

### Sockets and closing

```oberon
TYPE
  Socket* = POINTER TO SocketDesc;
  SocketDesc* = RECORD
    fd-: LONGINT;          (* -1 once closed *)
    family-: INTEGER;      (* inet, inet6, unix *)
    listening-: BOOLEAN;   (* made by Listen, or SO_ACCEPTCONN on Adopt *)
    nonBlocking-: BOOLEAN;
    deadline-: LONGINT;    (* monotonic ms, 0 for none (Deadlines) *)
    waiters-: INTEGER      (* SocketTasks calls waiting on it now *)
  END;
```

A `Socket` is a record, not a bare `LONGINT`, so a closed one is
visible (`fd` = -1) and every operation can halt on it (Halt codes)
instead of acting on a descriptor number the kernel may have handed to
something else. `fd` is read-only and exported, for `Tasks`, `Platform`
and polibtls. `Adopt(fd)` wraps a descriptor made elsewhere (one
inherited from a parent, or from systemd's socket activation), and
fills in the other fields from the kernel: `family` from
`getsockname`, `listening` from `SO_ACCEPTCONN`, `nonBlocking` from
`fcntl(F_GETFL)`. `listening` is what halt code 85 checks. `nonBlocking`
is a cache: a caller that changes the mode behind posockets' back (with
`fcntl` in C) makes it wrong, which is documented, not detected.

`deadline` and `waiters` are for `SocketTasks` (decided 2026-11-15).
They live in `SocketDesc` because `Close`, in `Sockets`, must see
`waiters`, and `Sockets` never imports `Tasks`. Read-only export means
`SocketTasks` can't assign them, so `Sockets` exports the procedures
that do: `SetDeadline(s, ms)` (from now, on the C part's monotonic
clock; 0 clears it), which any caller may use, and `BeginWait(s)` /
`EndWait(s)`, which are for `SocketTasks` only and say so.

`Close(s)` closes the descriptor and sets `fd` to -1; on a closed
socket it does nothing, so it is safe to call twice. `close` is never
retried on `EINTR` (on Linux the descriptor is gone either way).

`Close` while another task waits on the socket halts (code 86; decided
2026-11-15): that task's `poll` would see `POLLNVAL`, or worse, a
reused number, and data would go silently to the wrong place.
`SocketTasks` counts its waits in `waiters`, so a `Close` that finds it
nonzero is caught. Waits made outside `SocketTasks` (polibtls's) aren't
counted; that stays documented only. A task that wants another to stop
uses a deadline or `Shutdown`.

A plain `close` of a TCP socket with unread data in its receive buffer
sends RST instead of FIN, and the peer may lose the end of what was
written to it. A server that ends a response by closing should shut
down its writing side, read and discard until end of stream or a short
deadline, then close (the "lingering close"). The Gemini server needs
this; a `SocketTasks` helper for it is likely (Phase 4).

**No finalizer closes a socket** (decided 2026-11-15). polibtls's
`Connection` holds only the descriptor, so a `Socket` that became
unreachable while TLS still used its descriptor would have it closed
under TLS by a finalizer; the number would then be reused by the next
`accept`, and TLS would talk to the wrong peer. A descriptor leaked by a
forgotten `Close` is visible (valgrind's `--track-fds`, `/proc/self/fd`,
`EMFILE`); a descriptor closed behind a user's back is not. Revisit only
if a user asks, and then as an opt-in.

### Addresses

```oberon
TYPE
  Address* = RECORD
    family-: INTEGER;
    host-: ARRAY 128 OF CHAR;   (* numeric: "192.0.2.1", "2001:db8::1", or a Unix path *)
    port-: INTEGER
  END;
```

Addresses cross the C boundary as text and integers only: the C part
converts with `getnameinfo(NI_NUMERICHOST | NI_NUMERICSERV)` and never
does a reverse lookup, which would block. `LocalAddress(s, VAR a)`
(`getsockname`) reads back the port the kernel chose for port 0;
`PeerAddress(s, VAR a)` (`getpeername`); `Accept` returns the peer's.
An IPv4-mapped IPv6 address doesn't arise, since IPv6 listeners are
`IPV6_V6ONLY`. A Unix-domain path is limited to `sun_path`'s size
(108 bytes on Linux, 104 on the BSDs): longer is a programmer error.
Scope ids (`fe80::1%eth0`) come back as `getnameinfo` writes them.
`host` is 128 characters because it must hold a Unix path (up to 108
bytes with its terminator); an IPv6 address with a scope id is at most
`INET6_ADDRSTRLEN` (46) plus `%` and an interface name (`IF_NAMESIZE`,
16), so it fits too. (It was 64 until 2026-11-15, too short for a
path.) Checked 2026-11-15 on Fedora 44: `sun_path` 108,
`INET6_ADDRSTRLEN` 46, `IF_NAMESIZE` 16; `fe80::1%lo` came back as
written.

The peer of an accepted Unix-domain connection usually has no name
(the client didn't `bind`); its `Address` then has family `unix` and
an empty `host`. Linux's abstract namespace (a `sun_path` starting with
a NUL byte) is out of scope: it isn't portable, and its names aren't
text.

### Names

`getaddrinfo` blocks while it asks a name server, and stops every task
while it does. For a server that only binds its own addresses this is
harmless (it resolves once, at start), and numeric hosts never block
(`AI_NUMERICHOST` is tried first, in C). A client resolving names
inside a busy task-based program would stall it; an asynchronous
resolver is out of scope for now (Open questions).

Ports are `INTEGER`s, 0..65535 (halt 84 outside), not service names
(decided 2026-11-15): every known caller has a number, and a name would
mean reading `/etc/services` and another kind of error. The C part
formats the number for `getaddrinfo` with `AI_NUMERICSERV`.

- `Listen(host, port, backlog, VAR listeners, VAR n, VAR err):
  BOOLEAN`: `AI_PASSIVE`; an empty host means every address of both
  families. One socket per family the host resolves to (one per
  distinct address otherwise), each with `SO_REUSEADDR`, IPv6 ones with
  `IPV6_V6ONLY`. One listener per family because OpenBSD has no
  dual-stack sockets, and the same code then runs everywhere.
- Port 0 gives every listener the same port (decided 2026-11-15, in
  place of a separate `ListenOn`): `Listen` binds the first address,
  reads its port back, and binds the rest to it. If a later bind finds
  that port taken (`EADDRINUSE`), it closes what it made and starts
  again with port 0, a few times, before reporting the error.
- `getaddrinfo` is called with `ai_socktype = SOCK_STREAM`; without it
  each address comes back once per socket type, and `Listen` would try
  to bind it twice.
- A family that can't be bound (decided 2026-11-15): for the empty
  host only, `EAFNOSUPPORT` and `EADDRNOTAVAIL` skip that family, so a
  host with IPv6 disabled still serves IPv4; `n` says how many
  listeners were made. Any other failure, and any failure for a host
  the caller named, closes the sockets made and is reported: the caller
  asked for those addresses. If every family is skipped, that is an
  error too. A `listeners` array too small for the addresses found is a
  programmer error (halt 84), since two (one per family) suffices for
  every host but a name with many addresses.
- `Connect(host, port, VAR s, VAR err): BOOLEAN`: tries each
  address in `getaddrinfo`'s order until one connects, and reports the
  last error. This works only in blocking mode: a non-blocking
  `connect` stops at the first address with `wouldBlock`, and if
  `FinishConnect` then fails, nothing tries the next one. So `Sockets`
  also offers the two halves:
  - `Resolve(host, port, VAR addrs, VAR n, VAR err): BOOLEAN`,
    `getaddrinfo`'s results as `Address` values (numeric text, so the
    C part converts them back with `AI_NUMERICHOST` and no lookup);
  - `ConnectTo(a, nonBlocking, VAR s, VAR err): BOOLEAN`, one address.

  `SocketTasks.Connect` loops over `Resolve`'s addresses with
  `ConnectTo` and `FinishConnect`, as blocking `Connect` does in C.
  (Happy Eyeballs, racing the families, is a later refinement on the
  same halves, if a user needs it.)
- A blocking `Connect` has no timeout of its own: to an address that
  doesn't answer it waits for the kernel to give up (about two minutes
  on Linux, by `tcp_syn_retries`). Documented; a caller that minds uses
  `SocketTasks`, whose deadlines cover connecting.
- `ListenUnix(path, backlog, ...)`, `ConnectUnix(path, ...)`: the path
  is the caller's to remove; posockets never unlinks a file it didn't
  make, and doesn't remove a stale socket file before binding (an
  `EADDRINUSE` error says so).
- `Pair(VAR a, b, VAR err)`: `socketpair(AF_UNIX, SOCK_STREAM)`.

### Errors

Anything the network or the system does is a `BOOLEAN` result and an
`Error`, never a halt:

```oberon
TYPE
  Error* = RECORD
    kind-: INTEGER;      (* none, system, name, closed, wouldBlock, timedOut *)
    want-: INTEGER;      (* wantRead or wantWrite, when kind = wouldBlock *)
    code-: INTEGER;      (* errno, or getaddrinfo's EAI_ code *)
    text-: ARRAY 256 OF CHAR
  END;
```

`text` is `strerror_r` or `gai_strerror`, prefixed with what was being
done ("connect to ::1 port 1965: Connection refused"). The C part
returns `errno` as a value at once, since anything Oberon calls in
between (the collector, `Out`) may change it. `closed` means the peer
closed in an orderly way (a read of 0), so a caller can tell end of
stream from failure; `wouldBlock` is a non-blocking call that needs a
wait (with the direction: `wantRead` or `wantWrite`), and `timedOut` a
deadline that passed. Constants for the `errno` values a caller acts on
(`ECONNREFUSED`, `ECONNRESET`, `EPIPE`, `EADDRINUSE`, `EMFILE`,
`ENFILE`) come from the C part, since their numbers differ between
systems. `getaddrinfo`'s `EAI_SYSTEM` is reported as a `system` error
with the `errno` it leaves, not as a `name` error with no detail.
`text` is truncated, not overflowed, when a long host name makes the
prefix long.

### I/O

- `Read(s, VAR buf, pos, len, VAR n, VAR err): BOOLEAN` and
  `Write(s, buf, pos, len, VAR n, VAR err): BOOLEAN`, offsets into an
  open array as in polibtls, so no slice copies. Short reads and writes
  are normal; `WriteAll` loops over them. On a non-blocking socket,
  `Sockets.WriteAll` returns `wouldBlock` with `n` the bytes written so
  far, so the caller can resume. A `Read` with `len` = 0 returns at
  once with `n` = 0 and no error; only a read of 0 with `len` > 0 means
  `closed`.
- Reads are `recv`, writes `send` with `MSG_NOSIGNAL` (Linux, and the
  BSDs that have it; `SO_NOSIGPIPE` on those that don't, to be checked
  in the port), so a write to a closed peer fails with `EPIPE` instead
  of killing the program.
- `IgnoreBrokenPipe`: sets `SIGPIPE` to ignored process-wide. Needed
  when something else writes to the socket: libtls writes through
  OpenSSL, which uses `write`, out of posockets' reach. A program using
  polibtls calls it once at start. Whether poc's `Platform` already
  touches `SIGPIPE` is to be checked in Phase 0. An ignored signal stays
  ignored across `exec`, so every child the program starts afterwards
  (`Platform.System`) inherits it, and a pipeline such as `yes | head`
  in such a child never ends. To be documented on `IgnoreBrokenPipe`;
  a program that runs children and needs `SIGPIPE` ignored only for
  itself would need the disposition restored around the child, which
  `Platform.System` doesn't offer.
- `Shutdown(s, how)`: `read`, `write` or `both`; how a server ends a
  plain response, and how one task cuts off another's wait on a
  connection (a proxy, or a TLS wait outside `SocketTasks`).
- `SetNonBlocking(s, on)`: `O_NONBLOCK`. Sockets made by `Listen`,
  `Accept` and `Connect` take a `nonBlocking` argument and set it at
  creation (`SOCK_NONBLOCK`, `accept4`), so no window exists in which a
  task could block on one. `Accept` always passes the flags explicitly,
  since a plain `accept` copies `O_NONBLOCK` from the listener on the
  BSDs but not on Linux (Portability).
- Non-blocking `Connect` returns `wouldBlock` (`EINPROGRESS`) with the
  socket made; the caller waits for writable and calls
  `FinishConnect(s, VAR err)`, which reads `SO_ERROR`. It may instead
  succeed at once (`connect` returns 0, as it can to a loopback
  address), and then returns `TRUE` with no wait needed.
- A `connect` interrupted by a signal (`EINTR`) can't simply be
  called again: the connection goes on in the background, and a second
  call gives `EALREADY` or `EISCONN`. The C part's blocking connect
  then `poll`s for writable (retrying `poll`'s own `EINTR`) and reads
  `SO_ERROR`, as `FinishConnect` does.
- Non-blocking `Accept` returns `wouldBlock` on `EAGAIN`. Errors that
  belong to the connection being accepted, not the listener
  (`ECONNABORTED`, and on Linux the network errors `accept(2)` lists),
  are retried in C rather than reported, so an accept loop never stops
  because one client gave up.
- `EMFILE` and `ENFILE` from `accept` are reported, never retried:
  the pending connection stays queued, the listener stays readable, and
  a loop that awaits and retries spins at full CPU. The caller backs
  off (`Tasks.Sleep`, or closing idle connections) before accepting
  again; the echo example (Phase 8) shows it, and `SocketTasks.Accept`'s
  comment says so.

### Tasks

`SocketTasks`'s procedures take a non-blocking socket (halt 82
otherwise: on a blocking one they would stop every task) and loop: try
the call, and on `wouldBlock` `Tasks.AwaitReadable`/`AwaitWritable` on `s.fd` and
try again. An accept loop is one task per listener, each starting a
task per connection. Each task has its own stack; posockets' own calls
are shallow, but the stack size a server needs comes from what runs
on it (polibtls measures OpenSSL's).

How `Tasks` behaves when two tasks await the same descriptor (one
reading, one writing, as a proxy does), and whether `poll`'s `POLLHUP`
and `POLLERR` wake an `AwaitReadable`, are to be confirmed in Phase 0;
`Tasks.Mod`'s comment says a descriptor "at its end or in error" counts
as readable.

Read in poc's source on 2026-11-15, not yet run (Phase 0 still to
confirm by a program): `Tasks.Idle` adds one `pollfd` per waiting task,
so two tasks on one descriptor get two entries; `TaskWaiting.Ready`
wakes a task on any nonzero `revents`, so `POLLHUP`, `POLLERR` and
`POLLNVAL` all wake it; the `pollfd` table doubles as needed, so the
number of waiting connections has no fixed limit (the table is rebuilt
on every idle wait, which is linear in waiters, fine at a Gemini
server's scale).

The main program is a task too (`Tasks.Mod`'s comment), so
`SocketTasks` can be called from the main body; there is no "outside a
task" to halt on. Tasks still running when the main body ends are
abandoned, so a server's main body `Join`s its accept tasks.

**Stopping a server** (decided 2026-11-15) uses deadlines: the accept
task calls `SocketTasks.Accept` with a short deadline (about a
second), and on `timedOut` checks a "stop" flag the server sets, then
either returns or accepts again. Stopping takes up to that interval,
which is fine for a server. This needs nothing beyond the timed wait
(Deadlines), and is the same on every system; `shutdown` of a listener,
which wakes `accept` on Linux but not on the BSDs, isn't used.

### Deadlines

`Tasks.AwaitReadable`/`AwaitWritable` have no timeout (AGENTS.md,
"Confirmed facts"), but a server must not let a client hold a task
forever by sending nothing. `Tasks` now has a timed wait for this
(below).

**Decided 2026-11-15: a timed descriptor wait added to poc's `Tasks`**,
rather than working around its absence here. posockets is for poc
only, and Peaseblossom is the same author's, so the clean fix upstream
is in reach, and it solves stopping a server (Tasks) too.

- Upstream, done 2026-11-15 (Peaseblossom commit 73109d2, after
  0.12.0; its `doc/developer/tasks.md`, decision 15):
  `Tasks.AwaitReadableFor(fd, ms: LONGINT): BOOLEAN` and
  `AwaitWritableFor`, `TRUE` when `fd` is ready, `FALSE` when `ms`
  passed first. The task waits on both its descriptor and its own
  timer (`Sleep`'s), and whichever ends the wait removes it from the
  other list, so nothing is left behind. If both are due at one look,
  the timer wins: a deadline that has passed reports `FALSE` even if
  data came in at the same moment. An `ms` that isn't positive polls
  `fd` once, then `Yield`s, so a loop of them can't starve other
  tasks. Trap 20 as `AwaitReadable`'s: a negative descriptor, or any
  call on VMS (POSIX only, as descriptor waits are). Checked on Linux
  and the three BSD VMs by Peaseblossom's fixtures `llvm-tasks-timed`
  and `llvm-tasks-traps` (cases 17, 18); not yet re-checked here
  (Phase 5).
- Here: a deadline is a time on the socket (`SetDeadline(s, ms)`, 0
  for none; Sockets and closing). Each `SocketTasks` wait passes the
  time remaining to the timed wait, and on `FALSE` returns `timedOut`.
  With no deadline it calls the untimed `AwaitReadable`/`AwaitWritable`.
  A deadline already past still makes one wait with 0 ms, which polls
  once: an operation that can finish at once does, and one that can't
  returns `timedOut` without waiting.
- A timed-out operation leaves the socket usable: nothing was shut
  down, and the caller may set a new deadline and try again (as the
  accept loop does). A partly done `WriteAll` reports the bytes
  written in `n`.
- Phase 5 depends on the upstream change, which is pushed but in no
  poc release yet: the installed poc is 0.12.0, so until the next
  release Phase 5 builds against the Peaseblossom checkout. Phases 1-4
  don't need it.

Considered and set aside: a watchdog task per socket that `shutdown`s
it at the deadline (works with today's `Tasks`, but doubles the
tasks and their stacks, and a deadline would end the connection); one
timer task over all sockets (more bookkeeping, same `shutdown`); a
`Tasks.Select` on `Tasks.After` (needs the descriptor wait as a
channel). With the timed wait upstream, the watchdog is no longer
needed as a fallback.

polibtls's waits don't go through `SocketTasks` (it never imports
posockets), so a deadline set here doesn't cover them. With the timed
wait in `Tasks`, polibtls's own loops can take a deadline the same way;
that belongs in polibtls's PLAN.md. A Gemini server can also still
`Shutdown` a connection from another task to cut off a TLS wait.

### Portability

Recorded as found, each with the `#ifdef` that handles it:

- `MSG_NOSIGNAL`: Linux, FreeBSD, NetBSD, OpenBSD have it; macOS
  doesn't (`SO_NOSIGPIPE` there; macOS isn't a poc target).
- `accept4`, `SOCK_CLOEXEC`, `SOCK_NONBLOCK`: in all four, and in
  POSIX.1-2024.
- No dual-stack sockets on OpenBSD: handled by design (Names).
- `sun_path` size: 108 on Linux, 104 on the BSDs.
- `errno` and `EAI_` numbers differ: always from the C part.
- `accept4` in glibc's headers needs `_GNU_SOURCE`; `Sockets.c`
  defines it under `#ifdef __linux__` only. Whether the BSDs need
  anything is to be checked in the port.
- `ENONET` (an `accept` error to retry) is Linux's; used under
  `#ifdef ENONET`.
- `O_NONBLOCK` inheritance: a plain `accept` copies it from the
  listener on the BSDs, not on Linux. `accept4` with explicit flags is
  meant to make it the same everywhere; to be checked on each BSD.
- `strerror_r`: glibc's GNU version returns a `char *` (maybe not the
  buffer), the POSIX (XSI) one an `int`; the C part must handle both,
  by feature macro or by `#ifdef __GLIBC__`.
- `shutdown` on a listening socket: wakes a blocked `accept` with
  `EINVAL` on Linux; on the BSDs it fails with `ENOTCONN` and wakes
  nothing (to be confirmed; matters for stopping a server).

### Halt codes

`ASSERT(cond, n)` exits with status 10 and prints `assertion failed
(n)`. posockets uses n in 80..89, apart from Peaseblossom's runtime
(10..20), polibfyaml's 61..65, pofltk's 70..78 and polibtls's 90..99:

| n | Meaning |
|---|---|
| 80 | a closed socket (`fd` = -1) used, other than by `Close` |
| 81 | a buffer range out of bounds (pos/len outside the array) |
| 82 | a blocking socket given to a `SocketTasks` procedure |
| 83 | a Unix-domain path too long for `sun_path` |
| 84 | an argument out of range: port outside 0..65535, negative backlog, unknown `how` or family, a `listeners` or `addrs` array too small |
| 85 | `Accept` on a socket that isn't listening, or I/O on one that is (`listening`) |
| 86 | `Close` on a socket a `SocketTasks` call is waiting on (`waiters` > 0) |

Code 82 no longer covers "`SocketTasks` used outside a task" (changed
2026-11-15): the main program is a task, so that can't happen.

## Testing

As polibfyaml's (AGENTS.md, "Test"): a `Check` module, one test program
per concern, halt tests listed as `name:code`, everything under
valgrind with `poc-gc.supp`, and descriptors counted:

- `TestAddress`: `Listen` on `127.0.0.1`, `::1`, `localhost` and the
  empty host with port 0; `LocalAddress` gives a nonzero port; both
  families' text forms; a name that doesn't resolve gives a `name`
  error, not a halt (`nonexistent.invalid`, which RFC 6761 guarantees
  never resolves, so no name server is consulted in vain).
- `TestBlocking`: a child process (`Platform.System` on a small helper,
  or a second test program) connects to a blocking listener; data both
  ways, short writes, `Shutdown`, a read of 0 as `closed`.
  `Platform.System` is `system(3)` and waits for the child, so the
  parent would block until the child ends and a two-way exchange would
  deadlock. The helper is started in the background (`helper port &`,
  the port read back by `LocalAddress` passed on its command line), and
  the parent then accepts.
- `TestTasks`: listener, accept task and client tasks in one program;
  many connections at once; a proxy-like pair of tasks on one socket.
- `TestErrors`: connection refused (a port listened on and then
  closed), `EADDRINUSE`, a write to a reset peer giving `EPIPE` and no
  signal, `EMFILE` by lowering `RLIMIT_NOFILE` in a child. A reset
  needs `SO_LINGER` with a zero timeout on the peer, which Phase 7 adds
  only if a user asks, so the test uses a small C helper in `test/`
  for it. The refused port can in principle be taken by another
  process between the close and the connect; accepted as a rare,
  recognisable flake on a busy machine.
- `TestDeadline`: a client that sends nothing is cut off near its
  deadline, and one that sends in time is not.
- `TestUnix`: `Pair`, and a listener and client on a path under
  `build/`.
- Halt tests for every code in Halt codes.

Done in Phase 3:

- `test/TestHelp.Mod` and its C part `TestHelp.c`: what the tests need
  that the library doesn't offer: a `poll` with a timeout
  (`WaitReadable`, `WaitWritable`, so no test can hang in a blocking
  call), `SO_LINGER` 0 for a reset (`ResetOnClose`), `dup`, the
  descriptor limit, the count of open descriptors from
  `/proc/self/fd`, and opening `/dev/null`. A test module's C part is
  found and compiled by `poc -import-path test`, like a library's.
- `test/BlockingPeer.Mod`, `TestBlocking`'s helper, built before the
  tests (`HELPERS` in `GNUmakefile`): it connects, says `hello`, reads
  to the end checking a byte pattern, and answers `ok <count>`.
  `TestBlocking` starts it in the background, waits at most 10 s for
  the connection, and exchanges 1,000,000 bytes over `127.0.0.1` and
  `::1`.
- `test/TooManyFiles.Mod`, `TestErrors`' `EMFILE` check, run in the
  foreground by `Platform.System`, which returns 0 when it passes.
  A child because valgrind doesn't enforce `RLIMIT_NOFILE` (Phase 3).
- Standard input isn't assumed to be `/dev/null`: under some tools it
  is a socket, so `Adopt`'s "not a socket" check opens `/dev/null`
  itself.

Each test ends with no descriptors open beyond 0, 1 and 2 (checked
through `/proc/self/fd` on Linux, valgrind's `--track-fds=yes`
everywhere).

## Roadmap

### Phase 0: spike and confirmations

Done 2026-11-15 (AGENTS.md, "Confirmed facts"): a C part beside its
module compiles and links; `VAR ARRAY OF SYSTEM.INT32` reaches C as
`int32_t *`; `Tasks.AwaitReadable` wakes on a socket; `Platform.Write`
and `ReadBuf` work on one; `Tasks` had no timed descriptor wait (since
added upstream; Deadlines).

Still to confirm:

- Whether poc's runtime sets or changes `SIGPIPE`'s disposition, or
  any other signal a socket program cares about. (Read 2026-11-15:
  `Platform` installs handlers only for `SIGINT`, `SIGQUIT` and
  `SIGILL`, on request, with `SA_RESTART`, and none for `SIGPIPE`.)
- Two tasks awaiting one descriptor, one for reading and one for
  writing; and `POLLHUP`/`POLLERR` waking `AwaitReadable`. (The source
  says both work; Tasks, above.)
- `shutdown(SHUT_RDWR)` from one task wakes another awaiting the same
  descriptor (how one task cuts off another's wait; Shutdown).
- ~~Passing an `ARRAY OF CHAR` host and a `VAR ARRAY OF CHAR` result
  buffer to C, and the C part writing text back with a length limit.~~
  Done in Phase 2: an open array of any mode reaches a `["C"]`
  procedure as its first element's address alone, so `LEN` is passed
  beside it; the C part stops at `0X` or the length, and `snprintf`
  truncates what it writes back (`TestAddress`).

### Phase 1: project skeleton [done]

`GNUmakefile`, `.gitignore`, `test/Check.Mod`, `test/poc-gc.supp`,
`test/vg-reachable.sh` and the halt-test runner copied from polibfyaml
and adapted; `make`, `make test`, `make valgrind`, `make install` work
on an empty `Sockets`.

Done 2026-11-15:

- `Sockets` has its family constants, the halt codes as `Assert*`
  constants (`AssertClosed` = 80 to `AssertWaiting` = 86), and
  `Socket`/`SocketDesc` as in "Sockets and closing"; no procedures and
  no C part yet. `TestSkeleton` checks that a program links it, and
  goes when the real tests come.
- `LIBSRC` takes a module's C part when `src/<Module>.c` exists, so
  Phase 2 adds `Sockets.c` without touching the makefile.
- `make valgrind` also fails a test that leaves a descriptor open:
  `test/vg-fds.sh` (new) compares valgrind 3.27's "`<n>` open (`<m>`
  inherited) at exit". It uses `awk`, not a `grep -E` back-reference,
  which the BSDs' `grep` needn't support (AGENTS.md, "Confirmed facts").
- Checked: `make test` and `make valgrind` pass; the halt runner passes
  a halt with the right code and fails one with the wrong code (two
  throwaway halt tests); `make install` into a scratch directory, a
  program built against it, and `make uninstall` leaving it empty.
- `LICENSE`: BSD 3-Clause, as polibfyaml's (the user, 2026-11-15).
  `README.md`: what the library is and will offer, its status, how to
  build and install it; to be kept in step as the phases land.

### Phase 2: errors and addresses [done]

`Error`, the C part's `errno`/`EAI_` handling and text, `Address`,
`getnameinfo` text, `Pair`. `TestAddress` (the parts without
listening), halt tests.

Done 2026-11-15:

- `src/Sockets.c`, the first C part: `error-text`, `errno-value`,
  `sock-address`, `pair`, `close`, `resolve`. Each returns 0 or the
  error code as its value.
- `Error` with its kinds (`none`, `system`, `name`, `closed`,
  `wouldBlock`, `timedOut`), `wantRead`/`wantWrite`, and `ClearError`.
  A success clears the error. `text` is "`<what>`: `<message>`",
  truncated to 255 characters: a 599-character host gave exactly 255.
  The `errno` constants are read-only exported variables
  (`ECONNREFUSED`, `ECONNRESET`, `EPIPE`, `EADDRINUSE`, `EMFILE`,
  `ENFILE`, and `EAFNOSUPPORT`/`EADDRNOTAVAIL`, which `Listen` skips
  families on), set from the C part at module load. glibc's `EAI_`
  codes are negative (`EAI_NONAME` = -2), so `code` keeps its sign.
- `strerror_r`: no feature macros in `Sockets.c` (`_POSIX_C_SOURCE`
  would hide `SOCK_CLOEXEC` on the BSDs), so glibc gives the XSI
  version unless the compiler defines `_GNU_SOURCE`; `error_text`
  handles both, and compiled clean both ways.
- `Address`, as designed. `Pair`, `Close`, and, taken forward from
  Phase 3 because they need no listener, `LocalAddress`,
  `PeerAddress` and `Resolve`. Phase 3 keeps the rest.
- `Resolve` tries `AI_NUMERICHOST` first, then the name. It asks for
  `SOCK_STREAM` and keeps only `AF_INET`/`AF_INET6` results. It does not
  use `AI_ADDRCONFIG`, which in glibc ignores loopback addresses, so
  `::1` would vanish on a machine with no other IPv6 address. An empty
  host is `NULL` to `getaddrinfo`: the loopback addresses (`::1`,
  `127.0.0.1`), or the wildcards for `Listen`'s `AI_PASSIVE`.
  `localhost` gave `::1` then `127.0.0.1`. A canonical text comes back
  (`2001:DB8:0:0::1` gave `2001:db8::1`), and `::ffff:1.2.3.4` stays
  IPv6.
- Halt tests: `HaltClosed` (80), `HaltPort` and `HaltAddrs` (84). The
  rest of the codes come with the operations that check them.
- `test/vg-reachable.sh` also accepts the dynamic loader's memory for
  a `dlopen` (a stack through glibc's `dl-open.c`). `getaddrinfo` loads
  the NSS modules that way and glibc keeps them loaded until exit, so
  `TestAddress` showed about 7 KB of it still reachable. The check still
  fails any other block, which was tested by renaming the allocator in
  a log.
- poc: `SYSTEM.INT64` isn't assignable to `LONGINT` even under `-OC`,
  where they are the same size, so `Pair` converts with `SYSTEM.VAL`.
  `SYSTEM.INT32` is assignable to `INTEGER`.
- `make test` and `make valgrind` pass, with no leak and no descriptor
  left open.

### Phase 3: blocking TCP [done]

`Listen` (with port 0 shared across families), `Accept`, `Connect`,
`ConnectTo`, `Read`, `Write`, `WriteAll`, `Shutdown`, `Adopt`,
`IgnoreBrokenPipe`. (`Resolve`, `Close`, `LocalAddress` and
`PeerAddress` came in Phase 2.) `TestAddress`'s listening parts,
`TestBlocking`, `TestErrors`.

Done 2026-11-15:

- All of the above, and `FinishConnect` and `SetNonBlocking`, which
  the non-blocking forms need and which are plain calls, so Phase 4
  adds only the waiting. The C part's results are 0, a positive
  `errno`, or -1 for "would block"; the Oberon side turns them into
  `Error`s with a `what` naming the call and the address
  ("`bind 127.0.0.1 port 41234`", "`connect to ::1 port 41234`",
  "`listen on nonexistent.invalid port 0`").
- `Listen` resolves (`AI_PASSIVE`; numeric first, as `Resolve`), and
  makes one listener per address, at most 64, with `SO_REUSEADDR`, and
  `IPV6_V6ONLY` on IPv6 ones (Names). With port 0 the first bind's
  port is used for the rest; if another program holds it in the other
  family (`EADDRINUSE`), all are closed and it starts again, up to 5
  times. For the empty host only, a family the machine lacks
  (`EAFNOSUPPORT`, `EADDRNOTAVAIL`) is skipped; for a named host it is
  an error, since the caller asked for that address.
- `Accept` is `accept4` with the flags given explicitly, and retries
  `EINTR` and the per-connection errors (I/O). `Connect` tries each
  address in turn and reports the last failure. A blocking connect
  interrupted by a signal waits in `poll` and reads `SO_ERROR`, as
  designed (I/O).
- `FinishConnect` reads `SO_ERROR`; if that is clean and
  `getpeername` says `ENOTCONN`, the connect is still going and it
  returns `wouldBlock` again, so calling it early is harmless.
- `Adopt(fd)` takes a descriptor made elsewhere: the family from
  `getsockname`, `SO_TYPE` must be `SOCK_STREAM` (else `EPROTOTYPE`),
  `listening` from `SO_ACCEPTCONN`, `nonBlocking` from `O_NONBLOCK`.
  A descriptor that isn't a socket (`/dev/null` in `TestErrors`) is a
  `system` error from `getsockname`, not a halt, since where it came from is outside the program's control.
- Halt tests: `HaltRange` (81), `HaltListening` and `HaltAccept`
  (85), `HaltBacklog`, `HaltListeners` and `HaltShutdown` (84).
- Linux: glibc declares `accept4` only with `_GNU_SOURCE`, so
  `Sockets.c` defines it under `#ifdef __linux__` (Portability).
  `strerror_r` is then the GNU one, which `error_text` already
  handled (Phase 2).
- Found on Linux (throwaway programs and the tests):
  - A blocking `connect` to a loopback listener completes from the
    backlog before anything accepts, so one program can connect to its
    own listener and accept afterwards (`TestErrors` does).
  - With no descriptor free, `accept4` fails with `EMFILE` and the
    connection stays queued: it was accepted once a descriptor was
    freed (I/O; `TooManyFiles`).
  - valgrind 3.27.1 reports a lowered `RLIMIT_NOFILE` back through
    `getrlimit` but doesn't enforce it: descriptors went on being made
    past it, so the `EMFILE` check never saw `EMFILE` and the blocking
    `Accept` after it waited for ever. Hence the check runs in a child
    program, which valgrind doesn't follow (Testing).
- `make test` and `make valgrind` pass, with no leak and no descriptor
  left open.

### Phase 4: non-blocking and `SocketTasks`

`SetNonBlocking`, the `nonBlocking` argument, `wouldBlock`,
`FinishConnect`; `SocketTasks`, with `Connect` over `Resolve` and
`ConnectTo`, and the lingering close (Sockets and closing);
`waiters`, `BeginWait`/`EndWait` and halt 86. `TestTasks`. After this
phase polibtls can start its Phase 5 (TCP); `make install` here first.

### Phase 5: deadlines

Needs the timed descriptor wait in poc's `Tasks` (Deadlines), done in
Peaseblossom on 2026-11-15 with its own tests, but not yet in a poc
release; build against the checkout or the next release. First
re-check here, with a program, `AwaitReadableFor` on a socket: ready
before the time, the time passing, and 0 ms. Then `SetDeadline`, the timed waits in `SocketTasks`, `timedOut`, and
stopping an accept loop with a deadline and a flag. `TestDeadline`: a
client that sends nothing is cut off near its deadline, one that sends
in time is not, a socket is usable after a timeout, and an accept loop
stops within its interval.

### Phase 6: Unix-domain sockets

`ListenUnix`, `ConnectUnix`, peer credentials (`SO_PEERCRED` on Linux,
`getpeereid` on the BSDs) if a user wants them. `TestUnix`.

### Phase 7: options

Only those a user asks for: `TCP_NODELAY`, `SO_KEEPALIVE`, buffer
sizes, `SO_LINGER`. Each a procedure, not a generic `SetOption` taking
C's numbers.

### Phase 8: examples and documentation

`examples/`: an echo server with `SocketTasks` (one task per
connection, both families, a deadline) and a blocking client, the
smallest complete programs; and three that do something useful (the
user, 2026-11-15):

- **`Netcat`**: connect to a host and port, or a Unix-domain path, or
  listen on one and take a single connection; then copy standard input
  to the socket and the socket to standard output until both directions
  end, with `Shutdown` for the half-close when standard input ends.
  Blocking or with `SocketTasks` (one task each way); handy for poking
  at the Gemini server.
- **`Forward`**, a TCP port forwarder: listen on a local port, and for
  each connection connect onward to a target host and port and copy
  both ways with a pair of tasks, closing both sides when either ends.
  Shows many connections in one thread, `SocketTasks.Connect` over
  `Resolve`'s addresses, and an idle deadline. It's the proxy pattern
  `TestTasks` exercises, as a program.
- **`FileServer`**, a minimal static-file server over HTTP/1.0: serve
  one directory, `GET` and `HEAD` only, a few content types by file
  extension, and 400/404/405 responses. It refuses paths that leave the
  directory (`..`, absolute paths) and reads the request with a
  deadline. It can be tried with `curl`. Kept small: the HTTP parsing
  is the minimum, and the example says it is not for the open internet.

The `EXAMPLES` runner in the makefile compares standard output with an
`.expected` file, which suits only programs that end by themselves. So
each of these examples gets a test that starts it on a port-0 or
`build/` address and drives it from the other side: `Netcat` against
a listener in the test, `Forward` between a test client and a test
echo server, and `FileServer` with requests for a file in `test/`, a
missing one, and a `..` path. A server example started on port 0 prints
the port it was given, read back with `LocalAddress`, as its first line,
so the test can learn it. The test starts the example in the
background, as `TestBlocking` starts its helper.

A `doc/` reference like polibfyaml's, from the exported declarations and
their comments.

### Phase 9: BSD port

Build and test on the BSD hosts (as pofltk does; AGENTS.md); fix each
difference behind an `#ifdef` and add it to Portability.

## Open questions

- ~~**Module names.** `Sockets` and `SocketTasks`, or a prefix
  (`PoSockets`)?~~ Decided 2026-11-15: `Sockets` and `SocketTasks`
  (Modules).
- ~~**Deadlines.** Watchdog task per socket, one timer task, or a timed
  wait added to `Tasks` upstream?~~ Decided 2026-11-15: a timed wait
  added to poc's `Tasks` (Deadlines), and added there the same day
  (`AwaitReadableFor`/`AwaitWritableFor`).
- **Asynchronous name resolution.** `getaddrinfo` stops every task.
  Options if a user needs names resolved while serving: resolve in a
  child process and read the answer through a pipe; `getaddrinfo_a`
  (glibc only); or a small DNS client of our own. Not needed by the
  Gemini server, which resolves only at start.
- **`Address` as text.** Text is simple and portable; a caller that
  compares addresses (rate limiting by client) would want the bytes.
  Add a binary form only when such a caller appears.
- **systemd socket activation.** `Adopt` covers the mechanism; reading
  `LISTEN_FDS` is the server's business, or a small helper here.
- ~~**Port or service.** An `INTEGER` port, as polibtls asked, or a
  service string?~~ Decided 2026-11-15: an `INTEGER` port (Names).
- ~~**Port 0 on both families.** Keep `ListenOn` separate, or have
  `Listen` give both families the same port?~~ Decided 2026-11-15:
  `Listen` does it, retrying if the second bind finds the port taken;
  no `ListenOn` (Names).
- ~~**One family failing in `Listen`.** Skip it, or fail the whole
  call?~~ Decided 2026-11-15: skip only `EAFNOSUPPORT`/`EADDRNOTAVAIL`
  for the empty host, fail otherwise (Names).
- ~~**`Close` while another task waits.** Document only, or count
  waiters and halt?~~ Decided 2026-11-15: count them in `waiters` and
  halt with code 86 (Sockets and closing).
- ~~**Stopping a server.** How an accept task learns to stop.~~
  Decided 2026-11-15: an accept with a short deadline, then a flag
  check, on the timed wait (Tasks).
