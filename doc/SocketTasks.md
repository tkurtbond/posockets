# SocketTasks: Sockets' operations, waiting through Tasks

<!-- Made by doc/mkref.py from SocketTasks.Mod; edit the source, then make doc. -->

Accept, Connect, ConnectTo, ConnectUnix, Read, Write and WriteAll as in Sockets, but where Sockets on a non-blocking socket would give wouldBlock, these wait through Tasks (AwaitReadable, AwaitWritable) and try again, so other tasks run meanwhile. One OS thread can then serve many connections: a task per listener accepting, and a task per connection (PLAN.md, "Tasks").

Every socket given here must be non-blocking (Listen's and Accept's nonBlocking argument, or Sockets.SetNonBlocking); a blocking one halts (Sockets.AssertBlocking), since a wait in the kernel stops every task. Every socket made here is non-blocking.

Deadlines: a socket given a deadline (Sockets.SetDeadline) waits here only until then, and the call returns kind = timedOut; nothing is shut down, so the socket stays usable, and a caller may set another deadline and try again. A call that can finish without waiting does, even past the deadline. Connect, ConnectTo and ConnectUnix, which make their socket, take a time limit instead. Requires a poc whose Tasks has AwaitReadableFor (after 0.12.0).

Each wait is counted in the socket's waiters, so a Close from another task while one waits halts (Sockets.AssertWaiting). To stop a task waiting on a socket, another task calls Sockets.Shutdown on it, which wakes the wait with end of stream; or the socket has a deadline.

Two tasks may wait on one socket at once, one reading and one writing (a proxy). Two reading, or two writing, would interleave their data, which nothing here prevents. They share its deadline.

Errors are Sockets.Error, as from Sockets, and never wouldBlock.

Two things about Tasks itself, not posockets, that a program using this module will meet:

- Tasks keeps a self-pipe, two descriptors it opens the first time
  the program waits idle and never closes. A program that counts its
  open descriptors, or checks for leaks at exit (valgrind
  --track-fds=yes), sees two it never opened. Tasks.WakeDescriptor()
  opens them at once, so a count taken after it includes them.

- valgrind 3.27.1 counts each descriptor open at exit as an error
  under --track-fds=yes, so the self-pipe alone fails
  --error-exitcode; compare the errors with the descriptors instead
  (test/vg-errors.sh). memcheck follows poc's coroutines since
  Peaseblossom's bug 21 was fixed (2026-11-15), so a program with
  tasks gets the full check.

## Procedures

#### Accept

```oberon
PROCEDURE Accept*(l: Sockets.Socket; VAR s: Sockets.Socket;
    VAR peer: Sockets.Address; VAR err: Sockets.Error): BOOLEAN;
```

The next connection on listener l, as a non-blocking s, waiting until one comes or l's deadline passes. EMFILE and ENFILE come back as errors at once, and the connection stays queued, so l stays readable: a loop that accepts again at once spins at full CPU. Back off first (Tasks.Sleep, or close idle connections). Halts (Sockets.AssertListening) unless l is listening.

An accept loop that must stop gives l a short deadline before each Accept and, on timedOut, checks a flag the program sets to stop it (PLAN.md, "Stopping a server").

#### ResolveAll

```oberon
PROCEDURE ResolveAll*(host: ARRAY OF CHAR; port: INTEGER; ms: LONGINT;
    VAR addrs: Sockets.Addresses; VAR err: Sockets.Error): BOOLEAN;
```

host's TCP addresses for port, as Sockets.ResolveAll gives them, but with a name looked up in a thread of the C part (Sockets.StartResolve) while this task waits and others run, for at most ms milliseconds (0: no limit). Past ms, FALSE with timedOut, "resolve <host> port <port>: timed out"; the lookup goes on in its thread, and is freed when done. Halts (Sockets.AssertArgument) for a port outside 0..65535 or a negative ms.

#### Resolve

```oberon
PROCEDURE Resolve*(host: ARRAY OF CHAR; port: INTEGER; ms: LONGINT;
    VAR addrs: ARRAY OF Sockets.Address; VAR n: INTEGER;
    VAR err: Sockets.Error): BOOLEAN;
```

host's TCP addresses for port, as ResolveAll gives them, into addrs[0..n-1]. Halts (Sockets.AssertArgument) for a port outside 0..65535, a negative ms, or if addrs can't hold every address.

#### ConnectTo

```oberon
PROCEDURE ConnectTo*(a: Sockets.Address; ms: LONGINT; VAR s: Sockets.Socket;
    VAR err: Sockets.Error): BOOLEAN;
```

A connection to one address, as Sockets.Resolve gives it, as a non-blocking s, waiting while it is made: at most ms milliseconds, or as long as the system tries if ms = 0 (on Linux about two minutes for an address that never answers). On failure s is NIL and closed; on success s has no deadline. Halts (Sockets.AssertArgument) for an address that isn't inet or inet6, or a negative ms.

#### Connect

```oberon
PROCEDURE Connect*(host: ARRAY OF CHAR; port: INTEGER; ms: LONGINT;
    VAR s: Sockets.Socket; VAR err: Sockets.Error): BOOLEAN;
```

A connection to host and port, as a non-blocking s: each of host's addresses in getaddrinfo's order until one connects, reporting the last error ("connect to 127.0.0.1 port 7: Connection refused"), in at most ms milliseconds for them all, the lookup (ResolveAll) included (0: no limit, as ConnectTo). A name that doesn't resolve gives its error ("resolve example.invalid port 80: ..."). Halts (Sockets.AssertArgument) for a port outside 0..65535 or a negative ms.

#### ConnectUnix

```oberon
PROCEDURE ConnectUnix*(path: ARRAY OF CHAR; ms: LONGINT;
    VAR s: Sockets.Socket; VAR err: Sockets.Error): BOOLEAN;
```

A Unix-domain connection to the listener at path, as a non-blocking s, in at most ms milliseconds (0: no limit). On Linux a listener whose queue is full refuses at once with EAGAIN, and its socket can't be waited on (Sockets.ConnectUnix), so this sleeps (Tasks.Sleep), from 1 ms doubling to 64 ms, and tries again, until there is room or ms has passed: "connect to <path>: timed out". Any other failure comes back at once: ECONNREFUSED for a stale socket file, and on FreeBSD and NetBSD for a full queue too, which can't be told from it, so there it isn't tried again. Halts as Sockets.ConnectUnix for the path, and (Sockets.AssertArgument) for a negative ms.

#### Read

```oberon
PROCEDURE Read*(s: Sockets.Socket; VAR buf: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
```

Up to len bytes from s into buf[pos..pos+len-1], n of them, waiting until there is at least one or s's deadline passes; as Sockets.Read otherwise (closed at the end of stream; len = 0 returns at once).

#### Write

```oberon
PROCEDURE Write*(s: Sockets.Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
```

Up to len bytes of buf[pos..pos+len-1] to s, n of them, waiting until at least one can be written or s's deadline passes; as Sockets.Write otherwise.

#### WriteAll

```oberon
PROCEDURE WriteAll*(s: Sockets.Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
```

All of buf[pos..pos+len-1] to s, waiting whenever its buffer is full, until s's deadline; n is what was written, which is len unless it fails (a timeout too).

#### LingeringClose

```oberon
PROCEDURE LingeringClose*(s: Sockets.Socket; ms: LONGINT): BOOLEAN;
```

Ends a connection without losing the end of what was written to it: shuts down s's writing side, so the peer sees the end of the stream, reads and discards what the peer still sends until it closes too or ms milliseconds pass, then closes s. A plain Close with unread data waiting sends a reset instead, and the peer may lose the last of what it was sent (PLAN.md, "Sockets and closing"). TRUE if the peer closed in time; s is closed either way. Halts (Sockets.AssertArgument) unless ms > 0: without a limit, a peer that never closes would hold the task for ever.
