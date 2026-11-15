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
- **Names**: `getaddrinfo` for host and service, so `localhost`,
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

The name `Sockets` is generic and may clash with a module of the same
name in another library or a later poc runtime (Open questions).

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
    nonBlocking-: BOOLEAN
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

The deadline state (Deadlines) can't live in `Sockets`' own logic,
since `Sockets` never imports `Tasks`: either `SocketDesc` carries
fields that only `SocketTasks` reads and writes (a deadline time and a
timed-out flag), or `SocketTasks` keeps its own table or extension
type. To be decided in Phase 4, before `SocketTasks` is written, since
it shapes `SocketDesc`.

`Close(s)` closes the descriptor and sets `fd` to -1; on a closed
socket it does nothing, so it is safe to call twice. `close` is never
retried on `EINTR` (on Linux the descriptor is gone either way).

`Close` must not be called while another task waits on the socket:
that task's `poll` would see `POLLNVAL`, or worse, a reused number
(Open questions, on detecting it). A task that wants another to stop
uses `Shutdown`, as deadlines do.

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
path.) The sizes are to be checked in Phase 2.

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

- `Listen(host, service, backlog, VAR listeners, VAR n, VAR err):
  BOOLEAN`: `AI_PASSIVE`; an empty host means every address of both
  families. One socket per family the host resolves to (one per
  distinct address otherwise), each with `SO_REUSEADDR`, IPv6 ones with
  `IPV6_V6ONLY`. One listener per family because OpenBSD has no
  dual-stack sockets, and the same code then runs everywhere. With
  port 0 and both families, the kernel picks a different port for
  each; a caller that needs one port binds the first, reads its port
  back, and binds the second to it (`ListenOn` does this; Phase 3).
  Whether `Listen` should simply always do this for port 0, retrying a
  few times if the second bind gets `EADDRINUSE`, is an open question.
- `getaddrinfo` is called with `ai_socktype = SOCK_STREAM`; without it
  each address comes back once per socket type, and `Listen` would try
  to bind it twice.
- If one family can't be bound (IPv6 disabled gives `EAFNOSUPPORT` or
  `EADDRNOTAVAIL` for `::`), `Listen` either skips it or fails and
  closes the sockets it made: open question. A `listeners` array too
  small for the addresses found is a programmer error (halt 84), since
  two (one per family) suffices for every host but a name with many
  addresses.
- `Connect(host, service, VAR s, VAR err): BOOLEAN`: tries each
  address in `getaddrinfo`'s order until one connects, and reports the
  last error. This works only in blocking mode: a non-blocking
  `connect` stops at the first address with `wouldBlock`, and if
  `FinishConnect` then fails, nothing tries the next one. So `Sockets`
  also offers the two halves:
  - `Resolve(host, service, VAR addrs, VAR n, VAR err): BOOLEAN`,
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
  plain response, and how a deadline wakes a waiting task (below).
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

**Stopping a server** isn't designed yet (Open questions): an accept
task awaiting its listener needs a way to be told to stop, and
`shutdown` on a listening socket wakes a blocked `accept` on Linux but
not on the BSDs, so the deadline trick doesn't carry over.

### Deadlines

`Tasks.AwaitReadable`/`AwaitWritable` have no timeout (AGENTS.md,
"Confirmed facts"), but a server must not let a client hold a task
forever by sending nothing. The plan, to be confirmed in Phase 5:

- A deadline is a time on the socket (`SetDeadline(s, ms)`, 0 for
  none). `SocketTasks` starts one watchdog task per socket with a
  deadline, which sleeps (`Tasks.Sleep`) until the deadline and, if the
  socket's operation hasn't finished, sets a flag and calls
  `shutdown(fd, SHUT_RDWR)`. The waiting task's `poll` then sees the
  descriptor readable and writable, its retry fails, and it sees the
  flag and reports `timedOut`.
- `shutdown`, never `close`: closing a descriptor another task is
  polling invites the number's reuse under it.
- A deadline that passes ends the connection: `shutdown` can't be
  undone. It is a limit on a connection's life or on one exchange,
  not a timeout after which the same operation may be tried again.
  `SocketTasks`' comments say so.
- The watchdog holds the `Socket`, not the bare descriptor, so after
  the owner's `Close` it reads `fd` = -1 and does nothing, rather than
  shutting down a reused number.
- Cost: a watchdog task per connection doubles the tasks, and each
  task has its own `mmap`'d stack. With one deadline per connection
  that is tolerable; it is the main argument for the alternatives.
- Alternatives, if this proves awkward: a single timer task over all
  sockets' deadlines (fewer tasks, more bookkeeping); a `Tasks.Select`
  on `Tasks.After` (needs the descriptor wait as a channel, which
  `Tasks` doesn't offer); or asking Peaseblossom for a timed
  `AwaitReadable`, which would be the clean fix (Open questions).
- The timed wait looks small upstream (read 2026-11-15): every task
  already has a timer (`current.timer`, used by `Sleep`), and
  `AddTimer`/`ExpireTimers` run timers alongside the descriptor wait;
  an `AwaitDescriptor` that also arms the task's timer, and reports
  which woke it, is most of it. Raise it with Peaseblossom before
  Phase 5, and build the watchdog only if it can't come soon.

A deadline set on a socket covers polibtls's waits too only if polibtls
waits through `SocketTasks`; it doesn't (it never imports posockets),
so the Gemini server arms the deadline here and lets the `shutdown`
wake polibtls's wait. To be tried in polibtls's Phase 6.

### Portability

Recorded as found, each with the `#ifdef` that handles it:

- `MSG_NOSIGNAL`: Linux, FreeBSD, NetBSD, OpenBSD have it; macOS
  doesn't (`SO_NOSIGPIPE` there; macOS isn't a poc target).
- `accept4`, `SOCK_CLOEXEC`, `SOCK_NONBLOCK`: in all four, and in
  POSIX.1-2024.
- No dual-stack sockets on OpenBSD: handled by design (Names).
- `sun_path` size: 108 on Linux, 104 on the BSDs.
- `errno` and `EAI_` numbers differ: always from the C part.
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

Each test ends with no descriptors open beyond 0, 1 and 2 (checked
through `/proc/self/fd` on Linux, valgrind's `--track-fds=yes`
everywhere).

## Roadmap

### Phase 0: spike and confirmations

Done 2026-11-15 (AGENTS.md, "Confirmed facts"): a C part beside its
module compiles and links; `VAR ARRAY OF SYSTEM.INT32` reaches C as
`int32_t *`; `Tasks.AwaitReadable` wakes on a socket; `Platform.Write`
and `ReadBuf` work on one; `Tasks` has no timed descriptor wait.

Still to confirm:

- Whether poc's runtime sets or changes `SIGPIPE`'s disposition, or
  any other signal a socket program cares about. (Read 2026-11-15:
  `Platform` installs handlers only for `SIGINT`, `SIGQUIT` and
  `SIGILL`, on request, with `SA_RESTART`, and none for `SIGPIPE`.)
- Two tasks awaiting one descriptor, one for reading and one for
  writing; and `POLLHUP`/`POLLERR` waking `AwaitReadable`. (The source
  says both work; Tasks, above.)
- `shutdown(SHUT_RDWR)` from one task wakes another awaiting the same
  descriptor (the basis of Deadlines).
- Passing an `ARRAY OF CHAR` host and a `VAR ARRAY OF CHAR` result
  buffer to C, and the C part writing text back with a length limit.
  The C part takes `LEN` of every array it reads as well, and stops at
  `0X` or the length, so an array with no terminator can't make it
  read past the end.

### Phase 1: project skeleton

`GNUmakefile`, `.gitignore`, `test/Check.Mod`, `test/poc-gc.supp`,
`test/vg-reachable.sh` and the halt-test runner copied from polibfyaml
and adapted; `make`, `make test`, `make valgrind`, `make install` work
on an empty `Sockets`.

### Phase 2: errors and addresses

`Error`, the C part's `errno`/`EAI_` handling and text, `Address`,
`getnameinfo` text, `Pair`. `TestAddress` (the parts without
listening), halt tests.

### Phase 3: blocking TCP

`Listen`, `ListenOn`, `Accept`, `Connect`, `Resolve`, `ConnectTo`,
`Read`, `Write`, `WriteAll`, `Shutdown`, `Close`, `LocalAddress`,
`PeerAddress`, `Adopt`, `IgnoreBrokenPipe`. `TestAddress`,
`TestBlocking`, `TestErrors`.

### Phase 4: non-blocking and `SocketTasks`

`SetNonBlocking`, the `nonBlocking` argument, `wouldBlock`,
`FinishConnect`; `SocketTasks`, with `Connect` over `Resolve` and
`ConnectTo`, and the lingering close (Sockets and closing). Where the
deadline state lives is decided first (Sockets and closing), and how
to stop a server (Open questions). `TestTasks`. After this phase
polibtls can start its Phase 5 (TCP); `make install` here first.

### Phase 5: deadlines

A timed descriptor wait in `Tasks` if Peaseblossom adds one (asked
before this phase starts); otherwise the watchdog design (Deadlines),
or one of its alternatives if Phase 0 or this phase shows it doesn't
work. `TestDeadline`.

### Phase 6: Unix-domain sockets

`ListenUnix`, `ConnectUnix`, peer credentials (`SO_PEERCRED` on Linux,
`getpeereid` on the BSDs) if a user wants them. `TestUnix`.

### Phase 7: options

Only those a user asks for: `TCP_NODELAY`, `SO_KEEPALIVE`, buffer
sizes, `SO_LINGER`. Each a procedure, not a generic `SetOption` taking
C's numbers.

### Phase 8: examples and documentation

`examples/`: an echo server with `SocketTasks` (one task per
connection, both families, a deadline) and a blocking client. A
`doc/` reference like polibfyaml's, from the exported declarations and
their comments.

### Phase 9: BSD port

Build and test on the BSD hosts (as pofltk does; AGENTS.md); fix each
difference behind an `#ifdef` and add it to Portability.

## Open questions

- **Module names.** `Sockets` and `SocketTasks` are generic; poc's
  runtime has no module by either name (checked 2026-11-15), but a
  later one, or another library, might. A prefix (`PoSockets`) avoids
  the clash at the cost of longer names in every user's code. Decide
  before Phase 1, since the C labels carry the name.
- **Deadlines.** Watchdog task per socket, one timer task, or a timed
  wait added to `Tasks` upstream (Deadlines). Raise the last with
  Peaseblossom whatever is chosen: it is what `Tasks` lacks.
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
- **Port or service.** polibtls asked for `Listen(host, port, ...)`
  with an `INTEGER` port; Names has a `service` string, which allows
  `"gemini"` from `/etc/services` but makes halt 84's port range
  meaningless. An `INTEGER` port is simpler and never consults a file;
  a service string is more general. Decide before Phase 3.
- **Port 0 on both families.** Keep `ListenOn` separate, or have
  `Listen` always give both families the same port when asked for
  port 0 (retrying if the second bind finds it taken)? The second is
  one call that does the expected thing.
- **One family failing in `Listen`.** Skip a family that can't be
  bound (a host with IPv6 disabled still serves IPv4), or fail the
  whole call and close what was made? Skipping is friendlier but hides
  a misconfiguration; perhaps skip only `EAFNOSUPPORT`/`EADDRNOTAVAIL`
  for the empty host, and fail otherwise.
- **`Close` while another task waits.** Document it as forbidden only,
  or have `SocketTasks` count the tasks waiting on each socket and halt
  (a new code) when `Close` finds one? The count would live with the
  deadline state.
- **Stopping a server.** How an accept task learns to stop: a flag
  checked after each wake plus something that wakes it (a
  `Tasks.Event` can't, since the task is in `AwaitReadable`;
  `shutdown` of the listener does on Linux only; a self-connection to
  the listener works everywhere but is a trick). A timed wait in
  `Tasks` would make it a polling flag. Decide in Phase 4.
