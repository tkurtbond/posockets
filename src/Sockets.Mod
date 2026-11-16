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

   Phase 2 (PLAN.md, "Roadmap"): errors, addresses, Resolve, Pair, Close,
   LocalAddress and PeerAddress. Listening and connecting come in
   Phase 3. *)

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

TYPE
  Socket* = POINTER TO SocketDesc;
  SocketDesc* = RECORD
    fd-: LONGINT;          (* -1 once closed *)
    family-: INTEGER;      (* inet, inet6 or unix *)
    listening-: BOOLEAN;   (* made by Listen, or SO_ACCEPTCONN on Adopt *)
    nonBlocking-: BOOLEAN;
    deadline-: LONGINT;    (* monotonic ms, 0 for none *)
    waiters-: INTEGER      (* SocketTasks calls waiting on it now *)
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
  EAFNOSUPPORT-, EADDRNOTAVAIL-: INTEGER;

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

(* Errors *)

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
  s.nonBlocking := FALSE; s.deadline := 0; s.waiters := 0;
  RETURN s
END NewSocket;

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
  ASSERT((port >= 0) & (port <= 65535), AssertArgument);
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

BEGIN
  ECONNREFUSED := CErrnoValue(0); ECONNRESET := CErrnoValue(1);
  EPIPE := CErrnoValue(2); EADDRINUSE := CErrnoValue(3);
  EMFILE := CErrnoValue(4); ENFILE := CErrnoValue(5);
  EAFNOSUPPORT := CErrnoValue(6); EADDRNOTAVAIL := CErrnoValue(7)
END Sockets.
