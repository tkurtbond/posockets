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
    nonBlocking-: BOOLEAN
  END;
```

A `Socket` is a record, not a bare `LONGINT`, so a closed one is
visible (`fd` = -1) and every operation can halt on it (Halt codes)
instead of acting on a descriptor number the kernel may have handed to
something else. `fd` is read-only and exported, for `Tasks`, `Platform`
and polibtls. `Adopt(fd)` wraps a descriptor made elsewhere (one
inherited from a parent, or from systemd's socket activation).

`Close(s)` closes the descriptor and sets `fd` to -1; on a closed
socket it does nothing, so it is safe to call twice. `close` is never
retried on `EINTR` (on Linux the descriptor is gone either way).

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
    host-: ARRAY 64 OF CHAR;    (* numeric: "192.0.2.1", "2001:db8::1", or a Unix path *)
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
Scope ids (`fe80::1%eth0`) come back as `getnameinfo` writes them; the
buffer is sized for the longest such text plus a margin, to be checked
in Phase 2.

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
- `Connect(host, service, VAR s, VAR err): BOOLEAN`: tries each
  address in `getaddrinfo`'s order until one connects, and reports the
  last error. (Happy Eyeballs, racing the families, is a later
  refinement with `SocketTasks`, if a user needs it.)
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
(`ECONNREFUSED`, `ECONNRESET`, `EPIPE`, `EADDRINUSE`, `EMFILE`) come
from the C part, since their numbers differ between systems.

### I/O

- `Read(s, VAR buf, pos, len, VAR n, VAR err): BOOLEAN` and
  `Write(s, buf, pos, len, VAR n, VAR err): BOOLEAN`, offsets into an
  open array as in polibtls, so no slice copies. Short reads and writes
  are normal; `WriteAll` loops over them.
- Reads are `recv`, writes `send` with `MSG_NOSIGNAL` (Linux, and the
  BSDs that have it; `SO_NOSIGPIPE` on those that don't, to be checked
  in the port), so a write to a closed peer fails with `EPIPE` instead
  of killing the program.
- `IgnoreBrokenPipe`: sets `SIGPIPE` to ignored process-wide. Needed
  when something else writes to the socket: libtls writes through
  OpenSSL, which uses `write`, out of posockets' reach. A program using
  polibtls calls it once at start. Whether poc's `Platform` already
  touches `SIGPIPE` is to be checked in Phase 0.
- `Shutdown(s, how)`: `read`, `write` or `both`; how a server ends a
  plain response, and how a deadline wakes a waiting task (below).
- `SetNonBlocking(s, on)`: `O_NONBLOCK`. Sockets made by `Listen`,
  `Accept` and `Connect` take a `nonBlocking` argument and set it at
  creation (`SOCK_NONBLOCK`, `accept4`), so no window exists in which a
  task could block on one.
- Non-blocking `Connect` returns `wouldBlock` (`EINPROGRESS`) with the
  socket made; the caller waits for writable and calls
  `FinishConnect(s, VAR err)`, which reads `SO_ERROR`.
- Non-blocking `Accept` returns `wouldBlock` on `EAGAIN`. Errors that
  belong to the connection being accepted, not the listener
  (`ECONNABORTED`, and on Linux the network errors `accept(2)` lists),
  are retried in C rather than reported, so an accept loop never stops
  because one client gave up.

### Tasks

`SocketTasks`'s procedures take a non-blocking socket (halt otherwise:
on a blocking one they would stop every task) and loop: try the call,
and on `wouldBlock` `Tasks.AwaitReadable`/`AwaitWritable` on `s.fd` and
try again. An accept loop is one task per listener, each starting a
task per connection. Each task has its own stack; posockets' own calls
are shallow, but the stack size a server needs comes from what runs
on it (polibtls measures OpenSSL's).

How `Tasks` behaves when two tasks await the same descriptor (one
reading, one writing, as a proxy does), and whether `poll`'s `POLLHUP`
and `POLLERR` wake an `AwaitReadable`, are to be confirmed in Phase 0;
`Tasks.Mod`'s comment says a descriptor "at its end or in error" counts
as readable.

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
- Alternatives, if this proves awkward: a single timer task over all
  sockets' deadlines (fewer tasks, more bookkeeping); a `Tasks.Select`
  on `Tasks.After` (needs the descriptor wait as a channel, which
  `Tasks` doesn't offer); or asking Peaseblossom for a timed
  `AwaitReadable`, which would be the clean fix (Open questions).

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

### Halt codes

`ASSERT(cond, n)` exits with status 10 and prints `assertion failed
(n)`. posockets uses n in 80..89, apart from Peaseblossom's runtime
(10..20), polibfyaml's 61..65, pofltk's 70..78 and polibtls's 90..99:

| n | Meaning |
|---|---|
| 80 | a closed socket (`fd` = -1) used, other than by `Close` |
| 81 | a buffer range out of bounds (pos/len outside the array) |
| 82 | a blocking socket given to a `SocketTasks` procedure, or `SocketTasks` used outside a task |
| 83 | a Unix-domain path too long for `sun_path` |
| 84 | an argument out of range: port outside 0..65535, negative backlog, unknown `how` or family |
| 85 | `Accept` on a socket that isn't listening, or I/O on one that is |

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
- `TestTasks`: listener, accept task and client tasks in one program;
  many connections at once; a proxy-like pair of tasks on one socket.
- `TestErrors`: connection refused (a port listened on and then
  closed), `EADDRINUSE`, a write to a reset peer giving `EPIPE` and no
  signal, `EMFILE` by lowering `RLIMIT_NOFILE` in a child.
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
  any other signal a socket program cares about.
- Two tasks awaiting one descriptor, one for reading and one for
  writing; and `POLLHUP`/`POLLERR` waking `AwaitReadable`.
- `shutdown(SHUT_RDWR)` from one task wakes another awaiting the same
  descriptor (the basis of Deadlines).
- Passing an `ARRAY OF CHAR` host and a `VAR ARRAY OF CHAR` result
  buffer to C, and the C part writing text back with a length limit.

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

`Listen`, `ListenOn`, `Accept`, `Connect`, `Read`, `Write`, `WriteAll`,
`Shutdown`, `Close`, `LocalAddress`, `PeerAddress`, `Adopt`,
`IgnoreBrokenPipe`. `TestAddress`, `TestBlocking`, `TestErrors`.

### Phase 4: non-blocking and `SocketTasks`

`SetNonBlocking`, the `nonBlocking` argument, `wouldBlock`,
`FinishConnect`; `SocketTasks`. `TestTasks`. After this phase polibtls
can start its Phase 5 (TCP); `make install` here first.

### Phase 5: deadlines

The watchdog design (Deadlines), or one of its alternatives if Phase 0
or this phase shows it doesn't work. `TestDeadline`.

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
