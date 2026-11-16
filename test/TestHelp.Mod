MODULE TestHelp; (* What the tests need from the system beyond posockets *)

(* Its C part, TestHelp.c, is compiled with it. *)

IMPORT SYSTEM;

PROCEDURE ["C", "TestHelp.-wait"] CWait(fd: SYSTEM.INT64; write, ms: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-dup"] CDup(fd: SYSTEM.INT64): SYSTEM.INT64;
PROCEDURE ["C", "TestHelp.-reset-on-close"] CResetOnClose(fd: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-small-buffers"] CSmallBuffers(fd: SYSTEM.INT64; bytes: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-file-limit"] CFileLimit(): SYSTEM.INT64;
PROCEDURE ["C", "TestHelp.-set-file-limit"] CSetFileLimit(n: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-open-fds"] COpenFds(): SYSTEM.INT32;
PROCEDURE ["C", "TestHelp.-open-null"] COpenNull(): SYSTEM.INT64;
PROCEDURE ["C", "TestHelp.-close"] CClose(fd: SYSTEM.INT64): SYSTEM.INT32;

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

(* Small send and receive buffers on fd (SO_SNDBUF, SO_RCVBUF), so
   that a test's reads and writes wait: with the loopback's own, 300,000
   bytes on each of 20 connections never did (PLAN.md, "Testing"). *)
PROCEDURE SmallBuffers*(fd: LONGINT; bytes: INTEGER): BOOLEAN;
BEGIN
  RETURN CSmallBuffers(fd, bytes) = 0
END SmallBuffers;

(* RLIMIT_NOFILE's soft limit, or -1 *)
PROCEDURE FileLimit*(): LONGINT;
BEGIN
  RETURN SYSTEM.VAL(LONGINT, CFileLimit())
END FileLimit;

PROCEDURE SetFileLimit*(n: LONGINT): BOOLEAN;
BEGIN
  RETURN CSetFileLimit(n) = 0
END SetFileLimit;

(* Descriptors open now (/proc/self/fd), or -1 *)
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

END TestHelp.
