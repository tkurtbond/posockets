MODULE SocketTasks; (* Sockets' operations, waiting through Tasks *)

(* Accept, Connect, ConnectTo, Read, Write and WriteAll as in Sockets,
   but where Sockets on a non-blocking socket would give wouldBlock,
   these wait through Tasks (AwaitReadable, AwaitWritable) and try
   again, so other tasks run meanwhile. One OS thread can then serve
   many connections: a task per listener accepting, and a task per
   connection (PLAN.md, "Tasks").

   Every socket given here must be non-blocking (Listen's and Accept's
   nonBlocking argument, or Sockets.SetNonBlocking); a blocking one
   halts (Sockets.AssertBlocking), since a wait in the kernel stops
   every task. Every socket made here is non-blocking.

   Each wait is counted in the socket's waiters, so a Close from another
   task while one waits halts (Sockets.AssertWaiting). To stop a task
   waiting on a socket, another task calls Sockets.Shutdown on it, which
   wakes the wait with end of stream; or, from Phase 5, a deadline.

   Two tasks may wait on one socket at once, one reading and one
   writing (a proxy). Two reading, or two writing, would interleave
   their data, which nothing here prevents.

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

(* Halts unless s is open and non-blocking. *)
PROCEDURE Check(s: Sockets.Socket);
BEGIN
  ASSERT(s.fd # -1, Sockets.AssertClosed);
  ASSERT(s.nonBlocking, Sockets.AssertBlocking)
END Check;

(* Waits until s is ready in the direction want says, counted in
   s.waiters. *)
PROCEDURE Await(s: Sockets.Socket; want: INTEGER);
BEGIN
  Sockets.BeginWait(s);
  IF want = Sockets.wantRead THEN Tasks.AwaitReadable(s.fd)
  ELSE Tasks.AwaitWritable(s.fd)
  END;
  Sockets.EndWait(s)
END Await;

(* The next connection on listener l, as a non-blocking s, waiting
   until one comes. EMFILE and ENFILE come back as errors at once, and
   the connection stays queued, so l stays readable: a loop that accepts
   again at once spins at full CPU. Back off first (Tasks.Sleep, or
   close idle connections). Halts (Sockets.AssertListening) unless l is
   listening. *)
PROCEDURE Accept*(l: Sockets.Socket; VAR s: Sockets.Socket;
    VAR peer: Sockets.Address; VAR err: Sockets.Error): BOOLEAN;
BEGIN
  Check(l);
  WHILE ~Sockets.Accept(l, TRUE, s, peer, err) DO
    IF err.kind # Sockets.wouldBlock THEN RETURN FALSE END;
    Await(l, Sockets.wantRead)
  END;
  RETURN TRUE
END Accept;

(* A connection to one address, as Sockets.Resolve gives it, as a
   non-blocking s, waiting while it is made. On failure s is NIL and
   closed. Halts (Sockets.AssertArgument) for an address that isn't
   inet or inet6. *)
PROCEDURE ConnectTo*(a: Sockets.Address; VAR s: Sockets.Socket;
    VAR err: Sockets.Error): BOOLEAN;
  VAR ok: BOOLEAN;
BEGIN
  IF Sockets.ConnectTo(a, TRUE, s, err) THEN RETURN TRUE END;
  IF err.kind # Sockets.wouldBlock THEN RETURN FALSE END;
  REPEAT
    Await(s, Sockets.wantWrite);
    ok := Sockets.FinishConnect(s, err)
  UNTIL ok OR (err.kind # Sockets.wouldBlock);
  IF ~ok THEN Sockets.Close(s); s := NIL END;
  RETURN ok
END ConnectTo;

(* A connection to host and port, as a non-blocking s: each of host's
   addresses in getaddrinfo's order until one connects, reporting the
   last error ("connect to 127.0.0.1 port 7: Connection refused").
   Resolving the name is Sockets.Resolve, which waits in the kernel and
   so stops every task while it does (PLAN.md, "Open questions"); a
   name that doesn't resolve gives its error ("resolve example.invalid
   port 80: ..."). Halts (Sockets.AssertArgument) for a port outside
   0..65535. *)
PROCEDURE Connect*(host: ARRAY OF CHAR; port: INTEGER; VAR s: Sockets.Socket;
    VAR err: Sockets.Error): BOOLEAN;
  VAR addrs: ARRAY 16 OF Sockets.Address; n, i: INTEGER;
BEGIN
  s := NIL;
  IF ~Sockets.Resolve(host, port, addrs, n, err) THEN RETURN FALSE END;
  i := 0;
  WHILE i < n DO
    IF ConnectTo(addrs[i], s, err) THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END Connect;

(* Up to len bytes from s into buf[pos..pos+len-1], n of them, waiting
   until there is at least one; as Sockets.Read otherwise (closed at the
   end of stream; len = 0 returns at once). *)
PROCEDURE Read*(s: Sockets.Socket; VAR buf: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
BEGIN
  Check(s);
  WHILE ~Sockets.Read(s, buf, pos, len, n, err) DO
    IF err.kind # Sockets.wouldBlock THEN RETURN FALSE END;
    Await(s, Sockets.wantRead)
  END;
  RETURN TRUE
END Read;

(* Up to len bytes of buf[pos..pos+len-1] to s, n of them, waiting
   until at least one can be written; as Sockets.Write otherwise. *)
PROCEDURE Write*(s: Sockets.Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
BEGIN
  Check(s);
  WHILE ~Sockets.Write(s, buf, pos, len, n, err) DO
    IF err.kind # Sockets.wouldBlock THEN RETURN FALSE END;
    Await(s, Sockets.wantWrite)
  END;
  RETURN TRUE
END Write;

(* All of buf[pos..pos+len-1] to s, waiting whenever its buffer is full;
   n is what was written, which is len unless it fails. *)
PROCEDURE WriteAll*(s: Sockets.Socket; buf-: ARRAY OF CHAR; pos, len: LONGINT;
    VAR n: LONGINT; VAR err: Sockets.Error): BOOLEAN;
  VAR k: LONGINT;
BEGIN
  Check(s);
  n := 0;
  WHILE ~Sockets.WriteAll(s, buf, pos + n, len - n, k, err) DO
    n := n + k;
    IF err.kind # Sockets.wouldBlock THEN RETURN FALSE END;
    Await(s, Sockets.wantWrite)
  END;
  n := n + k;
  RETURN TRUE
END WriteAll;

END SocketTasks.
