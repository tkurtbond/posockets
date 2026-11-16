MODULE TooManyFiles; (* TestErrors' EMFILE check, run as a separate process *)

(* With RLIMIT_NOFILE lowered, Pair runs out with EMFILE, Accept then
   reports EMFILE, and the connection stays queued, so it is accepted
   once a descriptor is free (PLAN.md, "I/O").

   A separate process because valgrind 3.27.1 reports a lowered
   RLIMIT_NOFILE back but doesn't enforce it: under valgrind, descriptors
   go on being made past it. valgrind doesn't follow a child (no
   --trace-children), so this runs natively even under make valgrind.

   Silent on success, exit status 0; otherwise it names the step that
   failed on standard error and exits with 1. *)

IMPORT Err, Platform, Sockets, TestHelp;

VAR
  ls: ARRAY 2 OF Sockets.Socket;
  pairs: ARRAY 128 OF Sockets.Socket;
  l, c, s: Sockets.Socket;
  a: Sockets.Address;
  err: Sockets.Error;
  n, np, i: INTEGER;
  limit: LONGINT;

PROCEDURE Fail(what: ARRAY OF CHAR);
BEGIN
  Err.String("TooManyFiles: "); Err.String(what); Err.String(" ("); Err.String(err.text);
  Err.String(")"); Err.Ln; Err.Flush;
  Platform.Exit(1)
END Fail;

BEGIN
  IF ~Sockets.Listen("127.0.0.1", 0, 5, FALSE, ls, n, err) THEN Fail("listen") END;
  l := ls[0];
  IF ~Sockets.LocalAddress(l, a, err) THEN Fail("local address") END;
  IF ~Sockets.Connect("127.0.0.1", a.port, c, err) THEN Fail("connect") END;
  IF ~TestHelp.WaitReadable(l.fd, 5000) THEN Fail("connection queued") END;
  limit := TestHelp.FileLimit();
  IF ~TestHelp.SetFileLimit(TestHelp.OpenFds() + 8) THEN Fail("lower RLIMIT_NOFILE") END;
  np := 0;
  WHILE (np < LEN(pairs) - 1) & Sockets.Pair(pairs[np], pairs[np + 1], err) DO
    INC(np, 2)
  END;
  IF (err.kind # Sockets.system) OR (err.code # Sockets.EMFILE) THEN
    Fail("Pair runs out with EMFILE")
  END;
  IF Sockets.Accept(l, FALSE, s, a, err) THEN Fail("Accept with no descriptor free") END;
  IF (err.kind # Sockets.system) OR (err.code # Sockets.EMFILE) THEN
    Fail("Accept reports EMFILE")
  END;
  FOR i := 0 TO np - 1 DO Sockets.Close(pairs[i]) END;
  IF ~TestHelp.SetFileLimit(limit) THEN Fail("restore RLIMIT_NOFILE") END;
  IF ~TestHelp.WaitReadable(l.fd, 5000) THEN Fail("connection still queued") END;
  IF ~Sockets.Accept(l, FALSE, s, a, err) THEN Fail("Accept once a descriptor is free") END;
  Sockets.Close(s); Sockets.Close(c); Sockets.Close(l)
END TooManyFiles.
