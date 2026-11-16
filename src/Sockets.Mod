MODULE Sockets; (* TCP and Unix-domain sockets for poc *)

(* A Socket wraps a descriptor, so a closed one is visible (fd = -1) and
   an operation on it halts instead of acting on a descriptor number the
   kernel may since have given to something else. Anything the network
   or the system does comes back as a BOOLEAN result and an Error, never
   a halt; only a programmer's error halts, with one of the Assert codes
   below (PLAN.md, "Halt codes").

   The C part (Sockets.c) does everything that touches struct sockaddr,
   getaddrinfo and errno, and hands back only integers and text. An open
   array reaches a ["C"] procedure as its first element's address alone,
   so its length is always passed beside it.

   Every procedure here either never waits or waits in the kernel, and a
   wait in the kernel stops every task (PLAN.md, "Tasks"); SocketTasks
   does the same operations waiting through Tasks, on a non-blocking
   socket. Sockets never imports Tasks, so a program without tasks
   doesn't link them.

   Phase 2 (PLAN.md, "Roadmap"): errors, addresses, Resolve, Pair, Close,
   LocalAddress and PeerAddress. Phase 3: Listen, Accept, Connect,
   ConnectTo, FinishConnect, Read, Write, WriteAll, Shutdown,
   SetNonBlocking, Adopt and IgnoreBrokenPipe, for TCP. Phase 4:
   BeginWait and EndWait, for SocketTasks. Phase 5: SetDeadline, and
   Now, and TimeLeft and TimedOut for SocketTasks. Phase 6: ListenUnix
   and ConnectUnix. *)

IMPORT SYSTEM;

CONST
  (* Address families, Socket.family and Address.family *)
  inet* = 1; inet6* = 2; unix* = 3;

  (* Error.kind. none: no error. system: errno in code. name: a name
     that didn't resolve, getaddrinfo's EAI_ code in code. closed: the
     peer closed in an orderly way (a read of 0). wouldBlock: a
     non-blocking call needs a wait, in the direction Error.want says.
     timedOut: a deadline passed. *)
  none* = 0; system* = 1; name* = 2; closed* = 3; wouldBlock* = 4;
  timedOut* = 5;

  (* Error.want, when kind = wouldBlock *)
  wantRead* = 1; wantWrite* = 2;

  (* Shutdown's how *)
  shutRead* = 0; shutWrite* = 1; shutBoth* = 2;

  (* Codes of the ASSERTs that catch a programmer's error. poc's ASSERT
     exits with status 10 and prints "assertion failed (n)". *)
  AssertClosed* = 80;      (* a closed socket used, other than by Close *)
  AssertRange* = 81;       (* a buffer range outside its array *)
  AssertBlocking* = 82;    (* a blocking socket given to SocketTasks *)
  AssertPath* = 83;        (* a Unix-domain path too long for sun_path *)
  AssertArgument* = 84;    (* an argument out of range *)
  AssertListening* = 85;   (* Accept on a socket that isn't listening, or
                              I/O on one that is *)
  AssertWaiting* = 86;     (* Close while a SocketTasks call waits on it *)

  (* Address.host's size: a Unix path is at most 108 bytes with its
     terminator (sun_path on Linux, 104 on the BSDs), and an IPv6 address
     with a scope id at most INET6_ADDRSTRLEN (46) plus "%" and an
     interface name (IF_NAMESIZE, 16). *)
  HostLen = 128;
  TextLen = 256;           (* Error.text's size *)

  (* The C part's results beside 0 and errno values: a non-blocking call
     needs a wait; Listen found more addresses than its array holds. *)
  WouldBlock = -1;
  TooMany = 99;

TYPE
  Socket* = POINTER TO SocketDesc;
  SocketDesc* = RECORD
    fd-: LONGINT;          (* -1 once closed *)
    family-: INTEGER;      (* inet, inet6 or unix *)
    listening-: BOOLEAN;   (* made by Listen, or SO_ACCEPTCONN on Adopt *)
    nonBlocking-: BOOLEAN;
    deadline-: LONGINT;    (* monotonic ms, 0 for none *)
    waiters-: INTEGER;     (* SocketTasks calls waiting on it now *)
    (* the address a non-blocking ConnectTo is connecting to, for
       FinishConnect's error text; NIL once it is finished *)
    target: POINTER TO Address
  END;

  (* An address as text, never a reverse lookup: host is numeric
     ("192.0.2.1", "2001:db8::1", "fe80::1%eth0") or a Unix path, empty
     for an unnamed Unix-domain peer; port is 0 for a Unix address. *)
  Address* = RECORD
    family-: INTEGER;
    host-: ARRAY HostLen OF CHAR;
    port-: INTEGER
  END;

  (* What went wrong: kind, and for a system or name error the code and a
     text saying what was being done ("resolve example.invalid port 80:
     Name or service not known"), truncated, never overflowed. *)
  Error* = RECORD
    kind-: INTEGER;
    want-: INTEGER;
    code-: INTEGER;
    text-: ARRAY TextLen OF CHAR
  END;

VAR
  (* errno values a caller may act on, as Error.code of a system error.
     Their numbers differ between systems, so they come from the C part. *)
  ECONNREFUSED-, ECONNRESET-, EPIPE-, EADDRINUSE-, EMFILE-, ENFILE-,
  EAFNOSUPPORT-, EADDRNOTAVAIL-, ENOENT-, EAGAIN-: INTEGER;

  unixPathMax: INTEGER;    (* sun_path's size, terminator included *)

PROCEDURE ["C", "Sockets.-errno-value"] CErrnoValue(which: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-error-text"] CErrorText(kind, code: SYSTEM.INT32;
  what: ARRAY OF CHAR; whatLen: SYSTEM.ADDRESS;
  VAR text: ARRAY OF CHAR; textLen: SYSTEM.ADDRESS);
PROCEDURE ["C", "Sockets.-sock-address"] CSockAddress(fd: SYSTEM.INT64;
  which: SYSTEM.INT32; VAR family: SYSTEM.INT32;
  VAR host: ARRAY OF CHAR; hostLen: SYSTEM.ADDRESS;
  VAR port: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-pair"] CPair(VAR fds: ARRAY OF SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-close"] CClose(fd: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-resolve"] CResolve(host: ARRAY OF CHAR;
  hostLen: SYSTEM.ADDRESS; port, passive: SYSTEM.INT32;
  VAR families: ARRAY OF SYSTEM.INT32; VAR hosts: ARRAY OF CHAR;
  stride: SYSTEM.ADDRESS; VAR ports: ARRAY OF SYSTEM.INT32;
  max: SYSTEM.INT32; VAR count, code: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-listen"] CListen(host: ARRAY OF CHAR;
  hostLen: SYSTEM.ADDRESS; port, backlog, nonBlocking: SYSTEM.INT32;
  VAR fds: ARRAY OF SYSTEM.INT64; VAR families: ARRAY OF SYSTEM.INT32;
  max: SYSTEM.INT32; VAR count, code: SYSTEM.INT32;
  VAR what: ARRAY OF CHAR; whatLen: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-accept"] CAccept(fd: SYSTEM.INT64;
  nonBlocking: SYSTEM.INT32; VAR newFd: SYSTEM.INT64;
  VAR family: SYSTEM.INT32; VAR host: ARRAY OF CHAR;
  hostLen: SYSTEM.ADDRESS; VAR port: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-connect"] CConnect(host: ARRAY OF CHAR;
  hostLen: SYSTEM.ADDRESS; port: SYSTEM.INT32; VAR fd: SYSTEM.INT64;
  VAR family, code: SYSTEM.INT32;
  VAR what: ARRAY OF CHAR; whatLen: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-connect-to"] CConnectTo(host: ARRAY OF CHAR;
  hostLen: SYSTEM.ADDRESS; port, nonBlocking: SYSTEM.INT32;
  VAR fd: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-finish-connect"] CFinishConnect(fd: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-recv"] CRecv(fd: SYSTEM.INT64; buf: SYSTEM.ADDRESS;
  pos, len: SYSTEM.INT64; VAR n: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-send"] CSend(fd: SYSTEM.INT64; buf: SYSTEM.ADDRESS;
  pos, len: SYSTEM.INT64; VAR n: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-shutdown"] CShutdown(fd: SYSTEM.INT64; how: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-set-nonblocking"] CSetNonBlocking(fd: SYSTEM.INT64;
  on: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-adopt"] CAdopt(fd: SYSTEM.INT64;
  VAR family, listening, nonBlocking: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-ignore-sigpipe"] CIgnoreSigpipe(): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-now"] CNow(): SYSTEM.INT64;
PROCEDURE ["C", "Sockets.-unix-path-max"] CUnixPathMax(): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-listen-unix"] CListenUnix(path: ARRAY OF CHAR;
  pathLen: SYSTEM.ADDRESS; backlog, nonBlocking: SYSTEM.INT32;
  VAR fd: SYSTEM.INT64; VAR what: ARRAY OF CHAR;
  whatLen: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "Sockets.-connect-unix"] CConnectUnix(path: ARRAY OF CHAR;
  pathLen: SYSTEM.ADDRESS; nonBlocking: SYSTEM.INT32;
  VAR fd: SYSTEM.INT64): SYSTEM.INT32;

(* Text building, for an Error's prefix *)

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  j := 0;
  WHILE (i < LEN(s) - 1) & (j < LEN(t)) & (t[j] # 0X) DO
    s[i] := t[j]; INC(i); INC(j)
  END;
  IF i < LEN(s) THEN s[i] := 0X END
END Append;

PROCEDURE AppendInt(VAR s: ARRAY OF CHAR; n: LONGINT);
  VAR digits: ARRAY 24 OF CHAR; d: ARRAY 24 OF CHAR; i, k: INTEGER;
BEGIN
  IF n < 0 THEN Append(s, "-"); n := -n END;
  i := 0;
  REPEAT digits[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i)
  UNTIL n = 0;
  k := 0; WHILE i > 0 DO DEC(i); d[k] := digits[i]; INC(k) END;
  d[k] := 0X;
  Append(s, d)
END AppendInt;

(* "<verb> <host> port <port>", or for a Unix-domain address "<verb>
   <path>", appended to s. *)
PROCEDURE AppendAddress(VAR s: ARRAY OF CHAR; verb: ARRAY OF CHAR;
    a: Address);
BEGIN
  Append(s, verb); Append(s, " "); Append(s, a.host);
  IF a.family # unix THEN Append(s, " port "); AppendInt(s, a.port) END
END AppendAddress;

(* Errors *)

(* Sets err to no error: kind = none, an empty text. *)
PROCEDURE ClearError*(VAR err: Error);
BEGIN
  err.kind := none; err.want := 0; err.code := 0; err.text[0] := 0X
END ClearError;

(* Sets err to a system (kind = system) or name (kind = name) error with
   code, its text "<what>: <message>". *)
PROCEDURE SetError(VAR err: Error; kind, code: INTEGER; what: ARRAY OF CHAR);
BEGIN
  err.kind := kind; err.want := 0; err.code := code;
  CErrorText(kind, code, what, LEN(what), err.text, LEN(err.text))
END SetError;

(* Sockets *)

PROCEDURE NewSocket(fd: LONGINT; family: INTEGER): Socket;
  VAR s: Socket;
BEGIN
  NEW(s); s.fd := fd; s.family := family; s.listening := FALSE;
  s.nonBlocking := FALSE; s.deadline := 0; s.waiters := 0; s.target := NIL;
  RETURN s
END NewSocket;

PROCEDURE Flag(b: BOOLEAN): SYSTEM.INT32;
BEGIN
  IF b THEN RETURN 1 ELSE RETURN 0 END
END Flag;

PROCEDURE SetWouldBlock(VAR err: Error; want: INTEGER);
BEGIN
  err.kind := wouldBlock; err.want := want; err.code := 0;
  err.text := "operation would block"
END SetWouldBlock;

(* The result of a C call on a socket: TRUE for 0; otherwise err is set,
   a wouldBlock waiting for want, or a system error saying what. *)
PROCEDURE Outcome(r: SYSTEM.INT32; want: INTEGER; what: ARRAY OF CHAR;
    VAR err: Error): BOOLEAN;
BEGIN
  IF r = 0 THEN RETURN TRUE
  ELSIF r = WouldBlock THEN SetWouldBlock(err, want)
  ELSE SetError(err, system, r, what)
  END;
  RETURN FALSE
END Outcome;

PROCEDURE CheckPort(port: INTEGER);
BEGIN
  ASSERT((port >= 0) & (port <= 65535), AssertArgument)
END CheckPort;

(* Halts unless s is open and connected: not closed, not listening. *)
PROCEDURE CheckStream(s: Socket);
BEGIN
  ASSERT(s.fd # -1, AssertClosed);
  ASSERT(~s.listening, AssertListening)
END CheckStream;

(* Halts unless buf[pos..pos+len-1] is inside buf. *)
PROCEDURE CheckRange(bufLen, pos, len: LONGINT);
BEGIN
  ASSERT((pos >= 0) & (len >= 0) & (pos <= bufLen) & (len <= bufLen - pos),
    AssertRange)
END CheckRange;

(* Closes s and sets s.fd to -1; does nothing if it is already closed,
   so it is safe to call twice. Halts (AssertWaiting) while a
   SocketTasks call waits on s: that task's poll would see a closed
   descriptor, or another file the kernel gave its number to. *)
PROCEDURE Close*(s: Socket);
  VAR r: SYSTEM.INT32;
BEGIN
  IF s.fd # -1 THEN
    ASSERT(s.waiters = 0, AssertWaiting);
    (* A failing close has still released the descriptor on Linux,
       and there is nothing a caller could do about it. *)
    r := CClose(s.fd);
    s.fd := -1
  END
END Close;

(* A connected pair of Unix-domain stream sockets (socketpair), both
   close-on-exec and blocking. *)
PROCEDURE Pair*(VAR a, b: Socket; VAR err: Error): BOOLEAN;
  VAR fds: ARRAY 2 OF SYSTEM.INT64; r: SYSTEM.INT32;
BEGIN
  ClearError(err); a := NIL; b := NIL;
  r := CPair(fds);
  IF r # 0 THEN SetError(err, system, r, "socketpair"); RETURN FALSE END;
  (* SYSTEM.INT64 is not assignable to LONGINT even where they are the
     same size. *)
  a := NewSocket(SYSTEM.VAL(LONGINT, fds[0]), unix);
  b := NewSocket(SYSTEM.VAL(LONGINT, fds[1]), unix);
  RETURN TRUE
END Pair;

PROCEDURE SockAddress(s: Socket; which: INTEGER; what: ARRAY OF CHAR;
    VAR a: Address; VAR err: Error): BOOLEAN;
  VAR family, port, r: SYSTEM.INT32;
BEGIN
  ASSERT(s.fd # -1, AssertClosed);
  ClearError(err);
  r := CSockAddress(s.fd, which, family, a.host, LEN(a.host), port);
  IF r # 0 THEN
    a.family := 0; a.host[0] := 0X; a.port := 0;
    SetError(err, system, r, what); RETURN FALSE
  END;
  a.family := family; a.port := port;
  RETURN TRUE
END SockAddress;

(* s's own address (getsockname): after binding to port 0, the port the
   kernel chose. *)
PROCEDURE LocalAddress*(s: Socket; VAR a: Address; VAR err: Error): BOOLEAN;
BEGIN
  RETURN SockAddress(s, 0, "getsockname", a, err)
END LocalAddress;

(* The address of s's peer (getpeername); an unnamed Unix-domain peer,
   such as a socketpair's, has an empty host. *)
PROCEDURE PeerAddress*(s: Socket; VAR a: Address; VAR err: Error): BOOLEAN;
BEGIN
  RETURN SockAddress(s, 1, "getpeername", a, err)
END PeerAddress;

(* Names *)

(* host's addresses for a TCP connection to port, as getaddrinfo gives
   them, in its order, into addrs[0..n-1]. A numeric host never consults
   a name server; a name may, and blocks every task meanwhile. An empty
   host gives the loopback addresses. A name that doesn't resolve is a
   name error. Halts (AssertArgument) for a port outside 0..65535, or if
   addrs can't hold every address. *)
PROCEDURE Resolve*(host: ARRAY OF CHAR; port: INTEGER;
    VAR addrs: ARRAY OF Address; VAR n: INTEGER; VAR err: Error): BOOLEAN;
  VAR
    families, ports: POINTER TO ARRAY OF SYSTEM.INT32;
    hosts: POINTER TO ARRAY OF CHAR;
    count, code, kind: SYSTEM.INT32;
    i, j: LONGINT;
    what: ARRAY 512 OF CHAR;
    ok: BOOLEAN;
BEGIN
  CheckPort(port);
  ClearError(err); n := 0;
  NEW(families, LEN(addrs)); NEW(ports, LEN(addrs));
  NEW(hosts, LEN(addrs) * HostLen);
  kind := CResolve(host, LEN(host), port, 0, families^, hosts^, HostLen,
    ports^, SHORT(LEN(addrs)), count, code);
  IF kind # 0 THEN
    what := "resolve "; Append(what, host); Append(what, " port ");
    AppendInt(what, port);
    SetError(err, kind, code, what); ok := FALSE
  ELSE
    ASSERT(count <= LEN(addrs), AssertArgument);
    FOR i := 0 TO count - 1 DO
      addrs[i].family := families[i]; addrs[i].port := ports[i];
      j := 0;
      WHILE (j < HostLen - 1) & (hosts[i * HostLen + j] # 0X) DO
        addrs[i].host[j] := hosts[i * HostLen + j]; INC(j)
      END;
      addrs[i].host[j] := 0X
    END;
    n := count; ok := TRUE
  END;
  RETURN ok
END Resolve;

(* Listening and connecting (TCP) *)

(* Listening TCP sockets on host's addresses and port, one per address
   (getaddrinfo with AI_PASSIVE), into listeners[0..n-1]. The empty host
   is every address of both families, as two listeners (0.0.0.0 and ::).
   Each has SO_REUSEADDR, an IPv6 one IPV6_V6ONLY, so the two families
   never share a socket. Port 0 gives them all the same port, the
   kernel's choice (LocalAddress reads it). For the empty host only, a
   family the machine can't have (IPv6 disabled) is skipped; any other
   failure closes what was made and is reported. The sockets are
   blocking unless nonBlocking. Halts (AssertArgument) for a port outside
   0..65535, a negative backlog, or listeners too small for every
   address (two suffices for every host but a name with many addresses). *)
PROCEDURE Listen*(host: ARRAY OF CHAR; port, backlog: INTEGER;
    nonBlocking: BOOLEAN; VAR listeners: ARRAY OF Socket; VAR n: INTEGER;
    VAR err: Error): BOOLEAN;
  VAR
    fds: POINTER TO ARRAY OF SYSTEM.INT64;
    families: POINTER TO ARRAY OF SYSTEM.INT32;
    count, code, kind: SYSTEM.INT32;
    i: INTEGER;
    what: ARRAY 512 OF CHAR;
BEGIN
  CheckPort(port); ASSERT(backlog >= 0, AssertArgument);
  ClearError(err); n := 0;
  NEW(fds, LEN(listeners)); NEW(families, LEN(listeners));
  what[0] := 0X;
  kind := CListen(host, LEN(host), port, backlog, Flag(nonBlocking), fds^,
    families^, SHORT(LEN(listeners)), count, code, what, LEN(what));
  ASSERT(kind # TooMany, AssertArgument);
  IF kind # 0 THEN
    IF kind = name THEN
      what := "listen on "; Append(what, host); Append(what, " port ");
      AppendInt(what, port)
    END;
    SetError(err, kind, code, what); RETURN FALSE
  END;
  FOR i := 0 TO count - 1 DO
    listeners[i] := NewSocket(SYSTEM.VAL(LONGINT, fds[i]), families[i]);
    listeners[i].listening := TRUE; listeners[i].nonBlocking := nonBlocking
  END;
  n := count;
  RETURN TRUE
END Listen;

(* A connection from listener l's queue, as s, with its peer's address.
   On a blocking listener it waits for one; on a non-blocking one it
   gives wouldBlock (want = wantRead) when none is queued. s is blocking
   unless nonBlocking, whatever l is. A client that gave up while queued
   is skipped, never reported. EMFILE and ENFILE are reported: the
   connection stays queued, so a caller that retries at once spins; back
   off first. Halts (AssertListening) unless l is listening. *)
PROCEDURE Accept*(l: Socket; nonBlocking: BOOLEAN; VAR s: Socket;
    VAR peer: Address; VAR err: Error): BOOLEAN;
  VAR fd: SYSTEM.INT64; family, port, r: SYSTEM.INT32;
BEGIN
  ASSERT(l.fd # -1, AssertClosed); ASSERT(l.listening, AssertListening);
  ClearError(err); s := NIL;
  r := CAccept(l.fd, Flag(nonBlocking), fd, family, peer.host, LEN(peer.host),
    port);
  IF ~Outcome(r, wantRead, "accept", err) THEN
    peer.family := 0; peer.host[0] := 0X; peer.port := 0; RETURN FALSE
  END;
  peer.family := family; peer.port := port;
  s := NewSocket(SYSTEM.VAL(LONGINT, fd), family);
  s.nonBlocking := nonBlocking;
  RETURN TRUE
END Accept;

(* A blocking TCP connection to host and port, as s: each of host's
   addresses in getaddrinfo's order until one connects, reporting the
   last error ("connect to 127.0.0.1 port 7: Connection refused"). Waits
   for the kernel to give up on an address that doesn't answer (about
   two minutes on Linux), with every task stopped; SocketTasks.Connect
   takes a time limit. Halts (AssertArgument) for a port outside 0..65535. *)
PROCEDURE Connect*(host: ARRAY OF CHAR; port: INTEGER; VAR s: Socket;
    VAR err: Error): BOOLEAN;
  VAR fd: SYSTEM.INT64; family, code, kind: SYSTEM.INT32;
    what: ARRAY 512 OF CHAR;
BEGIN
  CheckPort(port);
  ClearError(err); s := NIL; what[0] := 0X;
  kind := CConnect(host, LEN(host), port, fd, family, code, what, LEN(what));
  IF kind # 0 THEN
    IF kind = name THEN
      what := "connect to "; Append(what, host); Append(what, " port ");
      AppendInt(what, port)
    END;
    SetError(err, kind, code, what); RETURN FALSE
  END;
  s := NewSocket(SYSTEM.VAL(LONGINT, fd), family);
  RETURN TRUE
END Connect;

(* A TCP connection to one address, as Resolve gives it. Blocking unless
   nonBlocking; then it may give wouldBlock (want = wantWrite) with s
   made and the connection in progress: wait until s is writable, then
   call FinishConnect. It may also connect at once, as to a loopback
   address, and return TRUE. On any other failure s is NIL. Halts
   (AssertArgument) for an address that isn't inet or inet6. *)
PROCEDURE ConnectTo*(a: Address; nonBlocking: BOOLEAN; VAR s: Socket;
    VAR err: Error): BOOLEAN;
  VAR fd: SYSTEM.INT64; r: SYSTEM.INT32; what: ARRAY 256 OF CHAR;
BEGIN
  ASSERT((a.family = inet) OR (a.family = inet6), AssertArgument);
  CheckPort(a.port);
  ClearError(err); s := NIL;
  r := CConnectTo(a.host, LEN(a.host), a.port, Flag(nonBlocking), fd);
  IF (r = 0) OR (r = WouldBlock) THEN
    s := NewSocket(SYSTEM.VAL(LONGINT, fd), a.family);
    s.nonBlocking := nonBlocking;
    IF r = WouldBlock THEN NEW(s.target); s.target^ := a END
  END;
  what[0] := 0X; AppendAddress(what, "connect to", a);
  RETURN Outcome(r, wantWrite, what, err)
END ConnectTo;

(* The outcome of a non-blocking ConnectTo, once s is writable: TRUE if
   connected, a system error if the connection failed ("connect to
   127.0.0.1 port 7: Connection refused"), or wouldBlock (want =
   wantWrite) if it is still in progress, so calling it early is
   harmless. *)
PROCEDURE FinishConnect*(s: Socket; VAR err: Error): BOOLEAN;
  VAR r: SYSTEM.INT32; what: ARRAY 256 OF CHAR;
BEGIN
  CheckStream(s); ClearError(err);
  r := CFinishConnect(s.fd);
  IF s.target = NIL THEN what := "connect"
  ELSE what[0] := 0X; AppendAddress(what, "connect to", s.target^)
  END;
  IF r # WouldBlock THEN s.target := NIL END;
  RETURN Outcome(r, wantWrite, what, err)
END FinishConnect;

(* Unix-domain sockets *)

(* Halts unless path is a usable Unix-domain path: not empty
   (AssertArgument), and short enough for sun_path with its terminator
   (AssertPath): at most 107 bytes on Linux, 103 on the BSDs. *)
PROCEDURE CheckPath(path: ARRAY OF CHAR);
  VAR n: LONGINT;
BEGIN
  n := 0; WHILE (n < LEN(path)) & (path[n] # 0X) DO INC(n) END;
  ASSERT(n > 0, AssertArgument);
  ASSERT(n < unixPathMax, AssertPath)
END CheckPath;

(* A listening Unix-domain stream socket at path, as l, blocking unless
   nonBlocking. bind makes a file at path, which stays when l is closed:
   removing it is the caller's (Files.Delete, Platform.Unlink), and
   posockets never removes a file. A file already there, even a stale
   socket left by an earlier run, gives EADDRINUSE ("bind <path>:
   Address already in use"); a server that knows the file is its own
   removes it first. Who may connect is up to the file's permissions,
   from the umask. Halts (AssertArgument) for an empty path or a
   negative backlog, (AssertPath) for one too long (CheckPath). *)
PROCEDURE ListenUnix*(path: ARRAY OF CHAR; backlog: INTEGER;
    nonBlocking: BOOLEAN; VAR l: Socket; VAR err: Error): BOOLEAN;
  VAR fd: SYSTEM.INT64; r: SYSTEM.INT32; what: ARRAY 256 OF CHAR;
BEGIN
  CheckPath(path); ASSERT(backlog >= 0, AssertArgument);
  ClearError(err); l := NIL; what[0] := 0X;
  r := CListenUnix(path, LEN(path), backlog, Flag(nonBlocking), fd, what,
    LEN(what));
  IF r # 0 THEN SetError(err, system, r, what); RETURN FALSE END;
  l := NewSocket(SYSTEM.VAL(LONGINT, fd), unix);
  l.listening := TRUE; l.nonBlocking := nonBlocking;
  RETURN TRUE
END ListenUnix;

(* A Unix-domain stream connection to the listener at path, as s,
   blocking unless nonBlocking. A connection is queued at once, so this
   never waits for the listener to accept; but when the listener's queue
   is full, a blocking connect waits for room (on Linux), and a
   non-blocking one fails with EAGAIN, nothing in progress, s NIL: try
   again later (SocketTasks.ConnectUnix does). No file at path gives
   ENOENT, a file with no listener (a stale socket) ECONNREFUSED: "connect
   to <path>: Connection refused". Halts as ListenUnix for the path. *)
PROCEDURE ConnectUnix*(path: ARRAY OF CHAR; nonBlocking: BOOLEAN;
    VAR s: Socket; VAR err: Error): BOOLEAN;
  VAR fd: SYSTEM.INT64; r: SYSTEM.INT32; a: Address; what: ARRAY 256 OF CHAR;
BEGIN
  CheckPath(path);
  ClearError(err); s := NIL;
  a.family := unix; COPY(path, a.host); a.port := 0;
  r := CConnectUnix(path, LEN(path), Flag(nonBlocking), fd);
  IF (r = 0) OR (r = WouldBlock) THEN
    s := NewSocket(SYSTEM.VAL(LONGINT, fd), unix);
    s.nonBlocking := nonBlocking;
    IF r = WouldBlock THEN NEW(s.target); s.target^ := a END
  END;
  what[0] := 0X; AppendAddress(what, "connect to", a);
  RETURN Outcome(r, wantWrite, what, err)
END ConnectUnix;

(* Deadlines *)

(* The monotonic clock in milliseconds, from an arbitrary start: for
   measuring time, never for the time of day. *)
PROCEDURE Now*(): LONGINT;
BEGIN
  RETURN SYSTEM.VAL(LONGINT, CNow())
END Now;

(* Gives s a deadline ms milliseconds from now, on the monotonic clock,
   which the time of day being set doesn't move; ms = 0 clears it.
   SocketTasks' calls on s that would wait past it return timedOut
   instead; s stays usable, and a caller may set another and try again.
   Sockets' own calls never wait in a task, so they ignore it. Halts
   (AssertArgument) for a negative ms. *)
PROCEDURE SetDeadline*(s: Socket; ms: LONGINT);
BEGIN
  ASSERT(s.fd # -1, AssertClosed);
  ASSERT(ms >= 0, AssertArgument);
  IF ms = 0 THEN s.deadline := 0
  ELSE s.deadline := Now() + ms
  END
END SetDeadline;

(* For SocketTasks: the milliseconds left before s's deadline, 0 once it
   has passed, or -1 if s has none. *)
PROCEDURE TimeLeft*(s: Socket): LONGINT;
  VAR left: LONGINT;
BEGIN
  IF s.deadline = 0 THEN RETURN -1 END;
  left := s.deadline - Now();
  IF left < 0 THEN left := 0 END;
  RETURN left
END TimeLeft;

(* For SocketTasks: sets err to timedOut, its text "<what>: timed out",
   or for a connection still being made, "connect to <host> port <p>:
   timed out". s may be NIL, for a wait with no socket yet. *)
PROCEDURE TimedOut*(s: Socket; VAR err: Error; what: ARRAY OF CHAR);
BEGIN
  err.kind := timedOut; err.want := 0; err.code := 0; err.text[0] := 0X;
  IF (s # NIL) & (s.target # NIL) THEN
    AppendAddress(err.text, "connect to", s.target^); s.target := NIL
  ELSE Append(err.text, what)
  END;
  Append(err.text, ": timed out")
END TimedOut;

(* Waits *)

(* For SocketTasks only: around each wait through Tasks on s, BeginWait
   before and EndWait after, so that a Close from another task while it
   waits halts (AssertWaiting) instead of leaving the wait on a closed
   descriptor, or on another file given its number. *)
PROCEDURE BeginWait*(s: Socket);
BEGIN
  ASSERT(s.fd # -1, AssertClosed);
  INC(s.waiters)
END BeginWait;

(* For SocketTasks only: the end of a wait begun with BeginWait. *)
PROCEDURE EndWait*(s: Socket);
BEGIN
  DEC(s.waiters)
END EndWait;

(* I/O *)

(* Up to len bytes from s into buf[pos..pos+len-1], n of them. A read of
   fewer than len is normal. The peer having closed its side gives
   kind = closed; a non-blocking socket with nothing to read gives
   wouldBlock (want = wantRead). len = 0 returns TRUE at once with n = 0.
   Halts (AssertRange) for a range outside buf. *)
PROCEDURE Read*(s: Socket; VAR buf: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Error): BOOLEAN;
  VAR got: SYSTEM.INT64; r: SYSTEM.INT32;
BEGIN
  CheckStream(s); CheckRange(LEN(buf), pos, len);
  ClearError(err); n := 0;
  IF len = 0 THEN RETURN TRUE END;
  r := CRecv(s.fd, SYSTEM.ADR(buf[0]), pos, len, got);
  IF ~Outcome(r, wantRead, "recv", err) THEN RETURN FALSE END;
  n := SYSTEM.VAL(LONGINT, got);
  IF n = 0 THEN
    err.kind := closed; err.text := "connection closed by peer"; RETURN FALSE
  END;
  RETURN TRUE
END Read;

(* Up to len bytes of buf[pos..pos+len-1] to s, n of them; fewer than
   len is normal (WriteAll loops). A peer that has gone gives a system
   error, EPIPE or ECONNRESET, never a SIGPIPE. A non-blocking socket
   whose buffer is full gives wouldBlock (want = wantWrite). Halts
   (AssertRange) for a range outside buf. *)
PROCEDURE Write*(s: Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Error): BOOLEAN;
  VAR sent: SYSTEM.INT64; r: SYSTEM.INT32;
BEGIN
  CheckStream(s); CheckRange(LEN(buf), pos, len);
  ClearError(err); n := 0;
  IF len = 0 THEN RETURN TRUE END;
  r := CSend(s.fd, SYSTEM.ADR(buf[0]), pos, len, sent);
  IF ~Outcome(r, wantWrite, "send", err) THEN RETURN FALSE END;
  n := SYSTEM.VAL(LONGINT, sent);
  RETURN TRUE
END Write;

(* All of buf[pos..pos+len-1] to s, looping over short writes; n is what
   was written, which is len unless it fails. On a non-blocking socket
   it stops with wouldBlock when the buffer fills, and n says how far it
   got, so the caller can wait and resume at pos + n. *)
PROCEDURE WriteAll*(s: Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Error): BOOLEAN;
  VAR k: LONGINT;
BEGIN
  CheckStream(s); CheckRange(LEN(buf), pos, len);
  ClearError(err); n := 0;
  WHILE n < len DO
    IF ~Write(s, buf, pos + n, len - n, k, err) THEN RETURN FALSE END;
    n := n + k
  END;
  RETURN TRUE
END WriteAll;

(* Shuts down s's reading (shutRead), writing (shutWrite) or both sides.
   shutWrite sends the peer end of stream, so its Read gives closed,
   while s can still read what the peer sends. Halts (AssertArgument) for
   another how. *)
PROCEDURE Shutdown*(s: Socket; how: INTEGER; VAR err: Error): BOOLEAN;
BEGIN
  CheckStream(s);
  ASSERT((how >= shutRead) & (how <= shutBoth), AssertArgument);
  ClearError(err);
  RETURN Outcome(CShutdown(s.fd, how), 0, "shutdown", err)
END Shutdown;

(* Sets (on) or clears O_NONBLOCK on s. *)
PROCEDURE SetNonBlocking*(s: Socket; on: BOOLEAN; VAR err: Error): BOOLEAN;
BEGIN
  ASSERT(s.fd # -1, AssertClosed);
  ClearError(err);
  IF ~Outcome(CSetNonBlocking(s.fd, Flag(on)), 0, "fcntl", err) THEN
    RETURN FALSE
  END;
  s.nonBlocking := on;
  RETURN TRUE
END SetNonBlocking;

(* Wraps fd, a stream socket made elsewhere (inherited from a parent, or
   from systemd's socket activation), as s, taking its family, whether it
   is listening, and its mode from the kernel. s then owns fd: Close
   closes it. A descriptor that isn't a socket is a system error
   (ENOTSOCK), as is one that isn't a stream socket (EPROTOTYPE); fd is
   left open then. Halts (AssertArgument) for a negative fd. *)
PROCEDURE Adopt*(fd: LONGINT; VAR s: Socket; VAR err: Error): BOOLEAN;
  VAR family, listening, nonBlocking, r: SYSTEM.INT32;
BEGIN
  ASSERT(fd >= 0, AssertArgument);
  ClearError(err); s := NIL;
  r := CAdopt(fd, family, listening, nonBlocking);
  IF ~Outcome(r, 0, "adopt", err) THEN RETURN FALSE END;
  s := NewSocket(fd, family);
  s.listening := listening # 0; s.nonBlocking := nonBlocking # 0;
  RETURN TRUE
END Adopt;

(* Sets SIGPIPE to ignored, process-wide. posockets' own writes never
   raise it (send with MSG_NOSIGNAL); this is for writes made elsewhere
   on its descriptors, as libtls's through OpenSSL. An ignored signal
   stays ignored across exec, so every child started afterwards
   (Platform.System) inherits it, and a pipeline in such a child, such as
   "yes | head", may never end. *)
PROCEDURE IgnoreBrokenPipe*;
  VAR r: SYSTEM.INT32;
BEGIN
  (* sigaction fails only for a bad signal number or action. *)
  r := CIgnoreSigpipe()
END IgnoreBrokenPipe;

BEGIN
  ECONNREFUSED := CErrnoValue(0); ECONNRESET := CErrnoValue(1);
  EPIPE := CErrnoValue(2); EADDRINUSE := CErrnoValue(3);
  EMFILE := CErrnoValue(4); ENFILE := CErrnoValue(5);
  EAFNOSUPPORT := CErrnoValue(6); EADDRNOTAVAIL := CErrnoValue(7);
  ENOENT := CErrnoValue(8); EAGAIN := CErrnoValue(9);
  unixPathMax := CUnixPathMax()
END Sockets.
