MODULE TestHelp; (* What the tests need from the system beyond posockets *)

(* Its C part, TestHelp.c, is compiled with it. *)

IMPORT SYSTEM;

PROCEDURE ["C", "TestHelp.-wait"] CWait(fd: SYSTEM.INT64; write, ms: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-dup"] CDup(fd: SYSTEM.INT64): SYSTEM.INT64;
PROCEDURE ["C", "TestHelp.-reset-on-close"] CResetOnClose(fd: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-small-buffer"] CSmallBuffer(fd: SYSTEM.INT64; bytes, receive: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-file-limit"] CFileLimit(): SYSTEM.INT64;
PROCEDURE ["C", "TestHelp.-set-file-limit"] CSetFileLimit(n: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-open-fds"] COpenFds(): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-open-null"] COpenNull(): SYSTEM.INT64;
PROCEDURE ["C", "TestHelp.-close"] CClose(fd: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-unix-path-max"] CUnixPathMax(): SYSTEM.INT32;
(* in Sockets.c, the library's C part, for the tests alone *)
PROCEDURE ["C", "Sockets.-set-resolve-delay"] CSetResolveDelay(ms: SYSTEM.INT32);
PROCEDURE ["C", "Sockets.-set-resolve-copies"] CSetResolveCopies(n: SYSTEM.INT32);

(* Whether fd becomes readable within ms milliseconds: a listener has a
   connection queued, so Accept won't wait. *)
PROCEDURE WaitReadable*(fd: LONGINT; ms: INTEGER): BOOLEAN;
BEGIN
  RETURN CWait(fd, 0, ms) = 1
END WaitReadable;

(* Whether fd becomes writable within ms milliseconds: a non-blocking
   connect has finished, one way or the other. *)
PROCEDURE WaitWritable*(fd: LONGINT; ms: INTEGER): BOOLEAN;
BEGIN
  RETURN CWait(fd, 1, ms) = 1
END WaitWritable;

(* A close-on-exec duplicate of fd, or -1. *)
PROCEDURE Dup*(fd: LONGINT): LONGINT;
BEGIN
  RETURN SYSTEM.VAL(LONGINT, CDup(fd))
END Dup;

(* Closing fd afterwards sends RST, not FIN (SO_LINGER, timeout 0). *)
PROCEDURE ResetOnClose*(fd: LONGINT): BOOLEAN;
BEGIN
  RETURN CResetOnClose(fd) = 0
END ResetOnClose;

(* A small send buffer on fd (SO_SNDBUF), so that a test's writes
   wait: with the loopback's own, 300,000 bytes on each of 20
   connections never did (PLAN.md, "Testing"). Only the send buffer:
   shrinking the receive buffer of a connected socket stalls transfers
   on FreeBSD, OpenBSD and NetBSD (PLAN.md, Phase 9). *)
PROCEDURE SmallSendBuffer*(fd: LONGINT; bytes: INTEGER): BOOLEAN;
BEGIN
  RETURN CSmallBuffer(fd, bytes, 0) = 0
END SmallSendBuffer;

(* A small receive buffer (SO_RCVBUF) on fd, for a peer that never
   reads, so that what is sent to it soon fills it. *)
PROCEDURE SmallReceiveBuffer*(fd: LONGINT; bytes: INTEGER): BOOLEAN;
BEGIN
  RETURN CSmallBuffer(fd, bytes, 1) = 0
END SmallReceiveBuffer;

(* sun_path's size, its terminator included: the longest Unix-domain
   path is one less (107 bytes on Linux, 103 on the BSDs). *)
PROCEDURE UnixPathMax*(): INTEGER;
BEGIN
  RETURN CUnixPathMax()
END UnixPathMax;

(* RLIMIT_NOFILE's soft limit, or -1 *)
PROCEDURE FileLimit*(): LONGINT;
BEGIN
  RETURN SYSTEM.VAL(LONGINT, CFileLimit())
END FileLimit;

PROCEDURE SetFileLimit*(n: LONGINT): BOOLEAN;
BEGIN
  RETURN CSetFileLimit(n) = 0
END SetFileLimit;

(* Descriptors open now, counted with fcntl *)
PROCEDURE OpenFds*(): INTEGER;
BEGIN
  RETURN COpenFds()
END OpenFds;

(* /dev/null, for reading: a descriptor that isn't a socket. -1 on error. *)
PROCEDURE OpenNull*(): LONGINT;
BEGIN
  RETURN SYSTEM.VAL(LONGINT, COpenNull())
END OpenNull;

PROCEDURE Close*(fd: LONGINT);
  VAR r: SYSTEM.INT32;
BEGIN
  r := CClose(fd)
END Close;

(* Makes every name lookup started from now on (Sockets.StartResolve)
   wait ms milliseconds in its thread before getaddrinfo, so that a
   lookup is slow enough to time out with no name server; 0 for none. *)
PROCEDURE SetResolveDelay*(ms: INTEGER);
BEGIN
  CSetResolveDelay(ms)
END SetResolveDelay;

(* Makes every lookup finished from now on give each address n times
   over (0 or 1: once), so a host has more addresses than a caller's
   array holds, with no name server. *)
PROCEDURE SetResolveCopies*(n: INTEGER);
BEGIN
  CSetResolveCopies(n)
END SetResolveCopies;

END TestHelp.
