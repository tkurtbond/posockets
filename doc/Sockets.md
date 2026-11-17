# Sockets: TCP and Unix-domain sockets for poc

<!-- Made by doc/mkref.py from Sockets.Mod; edit the source, then make doc. -->

A Socket wraps a descriptor, so a closed one is visible (fd = -1) and an operation on it halts instead of acting on a descriptor number the kernel may since have given to something else. Anything the network or the system does comes back as a BOOLEAN result and an Error, never a halt; only a programmer's error halts, with one of the Assert codes below (PLAN.md, "Halt codes").

The C part (Sockets.c) does everything that touches struct sockaddr, getaddrinfo and errno, and hands back only integers and text. An open array reaches a ["C"] procedure as its first element's address alone, so its length is always passed beside it.

Every procedure here either never waits or waits in the kernel, and a wait in the kernel stops every task (PLAN.md, "Tasks"); SocketTasks does the same operations waiting through Tasks, on a non-blocking socket. Sockets never imports Tasks, so a program without tasks doesn't link them.

## Constants

```oberon
inet* = 1; inet6* = 2; unix* = 3;
```

Address families, Socket.family and Address.family

```oberon
none* = 0; system* = 1; name* = 2; closed* = 3; wouldBlock* = 4;
timedOut* = 5;
```

Error.kind. none: no error. system: errno in code. name: a name that didn't resolve, getaddrinfo's EAI_ code in code. closed: the peer closed in an orderly way (a read of 0). wouldBlock: a non-blocking call needs a wait, in the direction Error.want says. timedOut: a deadline passed.

```oberon
wantRead* = 1; wantWrite* = 2;
```

Error.want, when kind = wouldBlock

```oberon
shutRead* = 0; shutWrite* = 1; shutBoth* = 2;
```

Shutdown's how

```oberon
AssertClosed* = 80;      (* a closed socket used, other than by Close *)
AssertRange* = 81;       (* a buffer range outside its array *)
AssertBlocking* = 82;    (* a blocking socket given to SocketTasks *)
AssertPath* = 83;        (* a Unix-domain path too long for sun_path *)
AssertArgument* = 84;    (* an argument out of range *)
AssertListening* = 85;   (* Accept on a socket that isn't listening, or
                            I/O on one that is *)
AssertWaiting* = 86;     (* Close while a SocketTasks call waits on it *)
```

Codes of the ASSERTs that catch a programmer's error. poc's ASSERT exits with status 10 and prints "assertion failed (n)".

## Types

```oberon
Socket* = POINTER TO SocketDesc;
SocketDesc* = RECORD
  fd-: LONGINT;          (* -1 once closed *)
  family-: INTEGER;      (* inet, inet6 or unix *)
  listening-: BOOLEAN;   (* made by Listen, or SO_ACCEPTCONN on Adopt *)
  nonBlocking-: BOOLEAN;
  deadline-: LONGINT;    (* monotonic ms, 0 for none *)
  waiters-: INTEGER;     (* SocketTasks calls waiting on it now *)
END;
```

```oberon
Address* = RECORD
  family-: INTEGER;
  host-: ARRAY HostLen OF CHAR;
  port-: INTEGER
END;
```

An address as text, never a reverse lookup: host is numeric ("192.0.2.1", "2001:db8::1", "fe80::1%eth0") or a Unix path, empty for an unnamed Unix-domain peer; port is 0 for a Unix address.

```oberon
Error* = RECORD
  kind-: INTEGER;
  want-: INTEGER;
  code-: INTEGER;
  text-: ARRAY TextLen OF CHAR
END;
```

What went wrong: kind, and for a system or name error the code and a text saying what was being done ("resolve example.invalid port 80: Name or service not known"), truncated, never overflowed.

## Variables

```oberon
ECONNREFUSED-, ECONNRESET-, EPIPE-, EADDRINUSE-, EMFILE-, ENFILE-,
EAFNOSUPPORT-, EADDRNOTAVAIL-, ENOENT-, EAGAIN-: INTEGER;
```

errno values a caller may act on, as Error.code of a system error. Their numbers differ between systems, so they come from the C part.

## Procedures

### Errors

#### ClearError

```oberon
PROCEDURE ClearError*(VAR err: Error);
```

Sets err to no error: kind = none, an empty text.

### Sockets

#### Close

```oberon
PROCEDURE Close*(s: Socket);
```

Closes s and sets s.fd to -1; does nothing if it is already closed, so it is safe to call twice. Halts (AssertWaiting) while a SocketTasks call waits on s: that task's poll would see a closed descriptor, or another file the kernel gave its number to.

#### Pair

```oberon
PROCEDURE Pair*(VAR a, b: Socket; VAR err: Error): BOOLEAN;
```

A connected pair of Unix-domain stream sockets (socketpair), both close-on-exec and blocking.

#### LocalAddress

```oberon
PROCEDURE LocalAddress*(s: Socket; VAR a: Address; VAR err: Error): BOOLEAN;
```

s's own address (getsockname): after binding to port 0, the port the kernel chose.

#### PeerAddress

```oberon
PROCEDURE PeerAddress*(s: Socket; VAR a: Address; VAR err: Error): BOOLEAN;
```

The address of s's peer (getpeername); an unnamed Unix-domain peer, such as a socketpair's, has an empty host.

### Names

#### Resolve

```oberon
PROCEDURE Resolve*(host: ARRAY OF CHAR; port: INTEGER;
    VAR addrs: ARRAY OF Address; VAR n: INTEGER; VAR err: Error): BOOLEAN;
```

host's addresses for a TCP connection to port, as getaddrinfo gives them, in its order, into addrs[0..n-1]. A numeric host never consults a name server; a name may, and blocks every task meanwhile. An empty host gives the loopback addresses. A name that doesn't resolve is a name error. Halts (AssertArgument) for a port outside 0..65535, or if addrs can't hold every address.

#### Listen

```oberon
PROCEDURE Listen*(host: ARRAY OF CHAR; port, backlog: INTEGER;
    nonBlocking: BOOLEAN; VAR listeners: ARRAY OF Socket; VAR n: INTEGER;
    VAR err: Error): BOOLEAN;
```

Listening TCP sockets on host's addresses and port, one per address (getaddrinfo with AI_PASSIVE), into listeners[0..n-1]. The empty host is every address of both families, as two listeners (0.0.0.0 and ::). Each has SO_REUSEADDR, an IPv6 one IPV6_V6ONLY, so the two families never share a socket. Port 0 gives them all the same port, the kernel's choice (LocalAddress reads it). For the empty host only, a family the machine can't have (IPv6 disabled) is skipped; any other failure closes what was made and is reported. The sockets are blocking unless nonBlocking. Halts (AssertArgument) for a port outside 0..65535, a negative backlog, or listeners too small for every address (two suffices for every host but a name with many addresses).

#### Accept

```oberon
PROCEDURE Accept*(l: Socket; nonBlocking: BOOLEAN; VAR s: Socket;
    VAR peer: Address; VAR err: Error): BOOLEAN;
```

A connection from listener l's queue, as s, with its peer's address. On a blocking listener it waits for one; on a non-blocking one it gives wouldBlock (want = wantRead) when none is queued. s is blocking unless nonBlocking, whatever l is. A client that gave up while queued is skipped, never reported. EMFILE and ENFILE are reported: the connection stays queued, so a caller that retries at once spins; back off first. Halts (AssertListening) unless l is listening.

#### Connect

```oberon
PROCEDURE Connect*(host: ARRAY OF CHAR; port: INTEGER; VAR s: Socket;
    VAR err: Error): BOOLEAN;
```

A blocking TCP connection to host and port, as s: each of host's addresses in getaddrinfo's order until one connects, reporting the last error ("connect to 127.0.0.1 port 7: Connection refused"). Waits for the kernel to give up on an address that doesn't answer (about two minutes on Linux), with every task stopped; SocketTasks.Connect takes a time limit. Halts (AssertArgument) for a port outside 0..65535.

#### ConnectTo

```oberon
PROCEDURE ConnectTo*(a: Address; nonBlocking: BOOLEAN; VAR s: Socket;
    VAR err: Error): BOOLEAN;
```

A TCP connection to one address, as Resolve gives it. Blocking unless nonBlocking; then it may give wouldBlock (want = wantWrite) with s made and the connection in progress: wait until s is writable, then call FinishConnect. It may also connect at once, as to a loopback address, and return TRUE. On any other failure s is NIL. Halts (AssertArgument) for an address that isn't inet or inet6.

#### FinishConnect

```oberon
PROCEDURE FinishConnect*(s: Socket; VAR err: Error): BOOLEAN;
```

The outcome of a non-blocking ConnectTo, once s is writable: TRUE if connected, a system error if the connection failed ("connect to 127.0.0.1 port 7: Connection refused"), or wouldBlock (want = wantWrite) if it is still in progress, so calling it early is harmless.

### Unix-domain sockets

#### ListenUnix

```oberon
PROCEDURE ListenUnix*(path: ARRAY OF CHAR; backlog: INTEGER;
    nonBlocking: BOOLEAN; VAR l: Socket; VAR err: Error): BOOLEAN;
```

A listening Unix-domain stream socket at path, as l, blocking unless nonBlocking. bind makes a file at path, which stays when l is closed: removing it is the caller's (Files.Delete, Platform.Unlink), and posockets never removes a file. A file already there, even a stale socket left by an earlier run, gives EADDRINUSE ("bind <path>: Address already in use"); a server that knows the file is its own removes it first. Who may connect is up to the file's permissions, from the umask. Halts (AssertArgument) for an empty path or a negative backlog, (AssertPath) for one too long (CheckPath).

#### ConnectUnix

```oberon
PROCEDURE ConnectUnix*(path: ARRAY OF CHAR; nonBlocking: BOOLEAN;
    VAR s: Socket; VAR err: Error): BOOLEAN;
```

A Unix-domain stream connection to the listener at path, as s, blocking unless nonBlocking. A connection is queued at once, so this never waits for the listener to accept. When the listener's queue is full, systems differ: on Linux a blocking connect waits for room, and a non-blocking one fails with EAGAIN, nothing in progress, s NIL: try again later (SocketTasks.ConnectUnix does); on FreeBSD and NetBSD either is refused at once, ECONNREFUSED, as for a stale socket; OpenBSD queued every connection tried, 150 with backlog 0. No file at path gives ENOENT, a file with no listener (a stale socket) ECONNREFUSED: "connect to <path>: Connection refused". Halts as ListenUnix for the path.

### Deadlines

#### Now

```oberon
PROCEDURE Now*(): LONGINT;
```

The monotonic clock in milliseconds, from an arbitrary start: for measuring time, never for the time of day. It is poDateTime's (Clocks.Monotonic, in ns), which setting the time of day doesn't move.

#### SetDeadline

```oberon
PROCEDURE SetDeadline*(s: Socket; ms: LONGINT);
```

Gives s a deadline ms milliseconds from now, on the monotonic clock, which the time of day being set doesn't move; ms = 0 clears it. SocketTasks' calls on s that would wait past it return timedOut instead; s stays usable, and a caller may set another and try again. Sockets' own calls never wait in a task, so they ignore it. Halts (AssertArgument) for a negative ms.

#### TimeLeft

```oberon
PROCEDURE TimeLeft*(s: Socket): LONGINT;
```

For SocketTasks: the milliseconds left before s's deadline, 0 once it has passed, or -1 if s has none.

#### TimedOut

```oberon
PROCEDURE TimedOut*(s: Socket; VAR err: Error; what: ARRAY OF CHAR);
```

For SocketTasks: sets err to timedOut, its text "<what>: timed out", or for a connection still being made, "connect to <host> port <p>: timed out". s may be NIL, for a wait with no socket yet.

### Waits

#### BeginWait

```oberon
PROCEDURE BeginWait*(s: Socket);
```

For SocketTasks only: around each wait through Tasks on s, BeginWait before and EndWait after, so that a Close from another task while it waits halts (AssertWaiting) instead of leaving the wait on a closed descriptor, or on another file given its number.

#### EndWait

```oberon
PROCEDURE EndWait*(s: Socket);
```

For SocketTasks only: the end of a wait begun with BeginWait.

### I/O

#### Read

```oberon
PROCEDURE Read*(s: Socket; VAR buf: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Error): BOOLEAN;
```

Up to len bytes from s into buf[pos..pos+len-1], n of them. A read of fewer than len is normal. The peer having closed its side gives kind = closed; a non-blocking socket with nothing to read gives wouldBlock (want = wantRead). len = 0 returns TRUE at once with n = 0. Halts (AssertRange) for a range outside buf.

#### Write

```oberon
PROCEDURE Write*(s: Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Error): BOOLEAN;
```

Up to len bytes of buf[pos..pos+len-1] to s, n of them; fewer than len is normal (WriteAll loops). A peer that has gone gives a system error, EPIPE or ECONNRESET, never a SIGPIPE. A non-blocking socket whose buffer is full gives wouldBlock (want = wantWrite). Halts (AssertRange) for a range outside buf.

#### WriteAll

```oberon
PROCEDURE WriteAll*(s: Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Error): BOOLEAN;
```

All of buf[pos..pos+len-1] to s, looping over short writes; n is what was written, which is len unless it fails. On a non-blocking socket it stops with wouldBlock when the buffer fills, and n says how far it got, so the caller can wait and resume at pos + n.

#### Shutdown

```oberon
PROCEDURE Shutdown*(s: Socket; how: INTEGER; VAR err: Error): BOOLEAN;
```

Shuts down s's reading (shutRead), writing (shutWrite) or both sides. shutWrite sends the peer end of stream, so its Read gives closed, while s can still read what the peer sends. Halts (AssertArgument) for another how.

#### SetNonBlocking

```oberon
PROCEDURE SetNonBlocking*(s: Socket; on: BOOLEAN; VAR err: Error): BOOLEAN;
```

Sets (on) or clears O_NONBLOCK on s.

#### Adopt

```oberon
PROCEDURE Adopt*(fd: LONGINT; VAR s: Socket; VAR err: Error): BOOLEAN;
```

Wraps fd, a stream socket made elsewhere (inherited from a parent, or from systemd's socket activation), as s, taking its family, whether it is listening, and its mode from the kernel. s then owns fd: Close closes it. A descriptor that isn't a socket is a system error (ENOTSOCK), as is one that isn't a stream socket (EPROTOTYPE); fd is left open then. Halts (AssertArgument) for a negative fd.

#### IgnoreBrokenPipe

```oberon
PROCEDURE IgnoreBrokenPipe*;
```

Sets SIGPIPE to ignored, process-wide. posockets' own writes never raise it (send with MSG_NOSIGNAL); this is for writes made elsewhere on its descriptors, as libtls's through OpenSSL. An ignored signal stays ignored across exec, so every child started afterwards (Platform.System) inherits it, and a pipeline in such a child, such as "yes | head", may never end.
