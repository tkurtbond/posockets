MODULE SocketTasks; (* Sockets' operations, waiting through Tasks *)

(* Accept, Connect, ConnectTo, ConnectUnix, Read, Write and WriteAll as
   in Sockets,
   but where Sockets on a non-blocking socket would give wouldBlock,
   these wait through Tasks (AwaitReadable, AwaitWritable) and try
   again, so other tasks run meanwhile. One OS thread can then serve
   many connections: a task per listener accepting, and a task per
   connection (PLAN.md, "Tasks").

   Every socket given here must be non-blocking (Listen's and Accept's
   nonBlocking argument, or Sockets.SetNonBlocking); a blocking one
   halts (Sockets.AssertBlocking), since a wait in the kernel stops
   every task. Every socket made here is non-blocking.

   Deadlines: a socket given a deadline (Sockets.SetDeadline) waits here
   only until then, and the call returns kind = timedOut; nothing is
   shut down, so the socket stays usable, and a caller may set another
   deadline and try again. A call that can finish without waiting does,
   even past the deadline. Connect, ConnectTo and ConnectUnix, which
   make their socket, take a time limit instead. Requires a poc whose Tasks has
   AwaitReadableFor (after 0.12.0).

   Each wait is counted in the socket's waiters, so a Close from another
   task while one waits halts (Sockets.AssertWaiting). To stop a task
   waiting on a socket, another task calls Sockets.Shutdown on it, which
   wakes the wait with end of stream; or the socket has a deadline.

   Two tasks may wait on one socket at once, one reading and one
   writing (a proxy). Two reading, or two writing, would interleave
   their data, which nothing here prevents. They share its deadline.

   Errors are Sockets.Error, as from Sockets, and never wouldBlock.

   Two things about Tasks itself, not posockets, that a program using
   this module will meet:

   - Tasks keeps a self-pipe, two descriptors it opens the first time
     the program waits idle and never closes. A program that counts its
     open descriptors, or checks for leaks at exit (valgrind
     --track-fds=yes), sees two it never opened. Tasks.WakeDescriptor()
     opens them at once, so a count taken after it includes them.

   - valgrind's memcheck can't follow poc's coroutines (poc 0.12.0):
     their stacks aren't registered with valgrind, so it warns "client
     switching stacks?" and reports thousands of uninitialised values
     that aren't the program's. Run a program with tasks under
     valgrind --tool=none --track-fds=yes to check descriptors only.
     The fix (VALGRIND_STACK_REGISTER in poc's Coroutines) is noted in
     Peaseblossom's PLAN.md, "Ongoing bug fixing", 21. *)

IMPORT Sockets, Tasks;

(* t appended to s, truncated to fit. *)
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

(* Halts unless s is open and non-blocking. *)
PROCEDURE Check(s: Sockets.Socket);
BEGIN
  ASSERT(s.fd # -1, Sockets.AssertClosed);
  ASSERT(s.nonBlocking, Sockets.AssertBlocking)
END Check;

(* Waits until s is ready in the direction want says, or its deadline
   passes, counted in s.waiters. FALSE, with err set to timedOut (its
   text from what), if the deadline came first. A deadline already past
   still looks once, without waiting. *)
PROCEDURE Await(s: Sockets.Socket; want: INTEGER; what: ARRAY OF CHAR;
    VAR err: Sockets.Error): BOOLEAN;
  VAR left: LONGINT; ready: BOOLEAN;
BEGIN
  left := Sockets.TimeLeft(s);
  Sockets.BeginWait(s);
  IF left < 0 THEN
    IF want = Sockets.wantRead THEN Tasks.AwaitReadable(s.fd)
    ELSE Tasks.AwaitWritable(s.fd)
    END;
    ready := TRUE
  ELSIF want = Sockets.wantRead THEN ready := Tasks.AwaitReadableFor(s.fd, left)
  ELSE ready := Tasks.AwaitWritableFor(s.fd, left)
  END;
  Sockets.EndWait(s);
  IF ~ready THEN Sockets.TimedOut(s, err, what) END;
  RETURN ready
END Await;

(* The next connection on listener l, as a non-blocking s, waiting
   until one comes or l's deadline passes. EMFILE and ENFILE come back
   as errors at once, and the connection stays queued, so l stays
   readable: a loop that accepts again at once spins at full CPU. Back
   off first (Tasks.Sleep, or close idle connections). Halts
   (Sockets.AssertListening) unless l is listening.

   An accept loop that must stop gives l a short deadline before each
   Accept and, on timedOut, checks a flag the program sets to stop it
   (PLAN.md, "Stopping a server"). *)
PROCEDURE Accept*(l: Sockets.Socket; VAR s: Sockets.Socket;
    VAR peer: Sockets.Address; VAR err: Sockets.Error): BOOLEAN;
BEGIN
  Check(l);
  WHILE ~Sockets.Accept(l, TRUE, s, peer, err) DO
    IF (err.kind # Sockets.wouldBlock)
      OR ~Await(l, Sockets.wantRead, "accept", err) THEN RETURN FALSE
    END
  END;
  RETURN TRUE
END Accept;

(* Waits for s's connection, in progress, to be made, at most ms
   milliseconds (0: no limit). On failure s is closed and NIL; on
   success it has no deadline. *)
PROCEDURE Finish(VAR s: Sockets.Socket; ms: LONGINT;
    VAR err: Sockets.Error): BOOLEAN;
  VAR ok: BOOLEAN;
BEGIN
  Sockets.SetDeadline(s, ms);
  REPEAT
    ok := Await(s, Sockets.wantWrite, "connect", err)
      & Sockets.FinishConnect(s, err)
  UNTIL ok OR (err.kind # Sockets.wouldBlock);
  IF ok THEN Sockets.SetDeadline(s, 0)
  ELSE Sockets.Close(s); s := NIL
  END;
  RETURN ok
END Finish;

(* A connection to one address, as Sockets.Resolve gives it, as a
   non-blocking s, waiting while it is made: at most ms milliseconds,
   or as long as the system tries if ms = 0 (on Linux about two minutes
   for an address that never answers). On failure s is NIL and closed;
   on success s has no deadline. Halts (Sockets.AssertArgument) for an
   address that isn't inet or inet6, or a negative ms. *)
PROCEDURE ConnectTo*(a: Sockets.Address; ms: LONGINT; VAR s: Sockets.Socket;
    VAR err: Sockets.Error): BOOLEAN;
BEGIN
  ASSERT(ms >= 0, Sockets.AssertArgument);
  IF Sockets.ConnectTo(a, TRUE, s, err) THEN RETURN TRUE END;
  RETURN (err.kind = Sockets.wouldBlock) & Finish(s, ms, err)
END ConnectTo;

(* A connection to host and port, as a non-blocking s: each of host's
   addresses in getaddrinfo's order until one connects, reporting the
   last error ("connect to 127.0.0.1 port 7: Connection refused"), in at
   most ms milliseconds for them all (0: no limit, as ConnectTo).
   Resolving the name is Sockets.Resolve, which waits in the kernel and
   so stops every task while it does, and isn't counted in ms (PLAN.md,
   "Open questions"); a name that doesn't resolve gives its error
   ("resolve example.invalid port 80: ..."). Halts
   (Sockets.AssertArgument) for a port outside 0..65535 or a negative
   ms. *)
PROCEDURE Connect*(host: ARRAY OF CHAR; port: INTEGER; ms: LONGINT;
    VAR s: Sockets.Socket; VAR err: Sockets.Error): BOOLEAN;
  VAR addrs: ARRAY 16 OF Sockets.Address; n, i: INTEGER; end, left: LONGINT;
BEGIN
  ASSERT(ms >= 0, Sockets.AssertArgument);
  s := NIL;
  IF ~Sockets.Resolve(host, port, addrs, n, err) THEN RETURN FALSE END;
  end := Sockets.Now() + ms; left := 0;
  i := 0;
  WHILE i < n DO
    IF ms > 0 THEN
      (* Out of time: the next address still gets 1 ms, so a connection
         that can be made at once is, and the error names the address. *)
      left := end - Sockets.Now(); IF left < 1 THEN left := 1 END
    END;
    IF ConnectTo(addrs[i], left, s, err) THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END Connect;

(* A Unix-domain connection to the listener at path, as a non-blocking
   s, in at most ms milliseconds (0: no limit). On Linux a listener
   whose queue is full refuses at once with EAGAIN, and its socket
   can't be waited on (Sockets.ConnectUnix), so this sleeps (Tasks.Sleep), from 1 ms
   doubling to 64 ms, and tries again, until there is room or ms has
   passed: "connect to <path>: timed out". Any other failure, as
   ECONNREFUSED for a stale socket file, comes back at once. Halts as
   Sockets.ConnectUnix for the path, and (Sockets.AssertArgument) for a
   negative ms. *)
PROCEDURE ConnectUnix*(path: ARRAY OF CHAR; ms: LONGINT;
    VAR s: Sockets.Socket; VAR err: Sockets.Error): BOOLEAN;
  VAR end, left, pause: LONGINT; what: ARRAY 256 OF CHAR;
BEGIN
  ASSERT(ms >= 0, Sockets.AssertArgument);
  end := Sockets.Now() + ms; pause := 1;
  LOOP
    IF Sockets.ConnectUnix(path, TRUE, s, err) THEN RETURN TRUE
    ELSIF err.kind = Sockets.wouldBlock THEN
      (* in progress, which Linux never gives *)
      left := 0;
      IF ms > 0 THEN left := end - Sockets.Now(); IF left < 1 THEN left := 1 END END;
      RETURN Finish(s, left, err)
    ELSIF (err.kind # Sockets.system) OR (err.code # Sockets.EAGAIN) THEN
      RETURN FALSE
    END;
    IF ms > 0 THEN
      left := end - Sockets.Now();
      IF left <= 0 THEN
        what := "connect to "; Append(what, path);
        Sockets.TimedOut(NIL, err, what); RETURN FALSE
      END;
      IF pause > left THEN pause := left END
    END;
    Tasks.Sleep(pause);
    IF pause < 64 THEN pause := pause * 2 END
  END
END ConnectUnix;

(* Up to len bytes from s into buf[pos..pos+len-1], n of them, waiting
   until there is at least one or s's deadline passes; as Sockets.Read
   otherwise (closed at the end of stream; len = 0 returns at once). *)
PROCEDURE Read*(s: Sockets.Socket; VAR buf: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
BEGIN
  Check(s);
  WHILE ~Sockets.Read(s, buf, pos, len, n, err) DO
    IF (err.kind # Sockets.wouldBlock)
      OR ~Await(s, Sockets.wantRead, "recv", err) THEN RETURN FALSE
    END
  END;
  RETURN TRUE
END Read;

(* Up to len bytes of buf[pos..pos+len-1] to s, n of them, waiting
   until at least one can be written or s's deadline passes; as
   Sockets.Write otherwise. *)
PROCEDURE Write*(s: Sockets.Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
BEGIN
  Check(s);
  WHILE ~Sockets.Write(s, buf, pos, len, n, err) DO
    IF (err.kind # Sockets.wouldBlock)
      OR ~Await(s, Sockets.wantWrite, "send", err) THEN RETURN FALSE
    END
  END;
  RETURN TRUE
END Write;

(* All of buf[pos..pos+len-1] to s, waiting whenever its buffer is full,
   until s's deadline; n is what was written, which is len unless it
   fails (a timeout too). *)
PROCEDURE WriteAll*(s: Sockets.Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
  VAR k: LONGINT;
BEGIN
  Check(s);
  n := 0;
  WHILE ~Sockets.WriteAll(s, buf, pos + n, len - n, k, err) DO
    n := n + k;
    IF (err.kind # Sockets.wouldBlock)
      OR ~Await(s, Sockets.wantWrite, "send", err) THEN RETURN FALSE
    END
  END;
  n := n + k;
  RETURN TRUE
END WriteAll;

(* Ends a connection without losing the end of what was written to it:
   shuts down s's writing side, so the peer sees the end of the stream,
   reads and discards what the peer still sends until it closes too or
   ms milliseconds pass, then closes s. A plain Close with unread data
   waiting sends a reset instead, and the peer may lose the last of what
   it was sent (PLAN.md, "Sockets and closing"). TRUE if the peer closed
   in time; s is closed either way. Halts (Sockets.AssertArgument) unless
   ms > 0: without a limit, a peer that never closes would hold the
   task for ever. *)
PROCEDURE LingeringClose*(s: Sockets.Socket; ms: LONGINT): BOOLEAN;
  VAR buf: ARRAY 512 OF CHAR; n: LONGINT; err: Sockets.Error; ok: BOOLEAN;
BEGIN
  Check(s);
  ASSERT(ms > 0, Sockets.AssertArgument);
  ok := Sockets.Shutdown(s, Sockets.shutWrite, err);
  IF ok THEN
    Sockets.SetDeadline(s, ms);
    WHILE Read(s, buf, 0, LEN(buf), n, err) DO END;
    ok := err.kind = Sockets.closed
  END;
  Sockets.Close(s);
  RETURN ok
END LingeringClose;

END SocketTasks.
