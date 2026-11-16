MODULE Forward; (* A TCP port forwarder: two tasks per connection *)

(* Usage: Forward port host target-port [count [idle]]

   Listens on every local address, IPv6 and IPv4, at port (0: one the
   kernel chooses), and prints "port <n>" as its first line. For each
   connection it connects onward to host and target-port, trying each of
   the host's addresses in turn, and copies both ways until both
   directions have ended. When one side ends its half (Shutdown), the
   other side's is ended too, so a client that sends a request and then
   ends its side still gets the whole answer. When a direction fails (a
   reset, a refused onward connection), or nothing has moved either way
   for idle milliseconds (default 300000), both sides are shut down and
   closed. With count, it serves that many connections, waits for them
   to end, and exits; without, it serves until killed.

   It shows many connections in one thread, each a task that connects
   onward (SocketTasks.Connect) and then a pair of tasks copying, one
   each way, waiting on the same two sockets at once; and an idle limit
   on the connection as a whole, not on each direction, so a long
   download with nothing sent the other way isn't cut off. The tasks on
   a socket share its deadline, which each wait reads when it starts:
   each task sets it from the connection's last transfer, and on a
   timeout looks at that again before giving up. *)

IMPORT Platform, Out, Err, Args, Coroutines, Tasks, Sockets, SocketTasks;

CONST
  Stack = Coroutines.DefaultStackSize;
  Tick = 200;               (* ms an accept waits before looking at stop *)
  Limit = 10000;            (* ms allowed to connect onward *)

TYPE
  Conn = POINTER TO RECORD (Tasks.TaskDesc)
    client, target: Sockets.Socket;
    last: LONGINT;          (* Sockets.Now() of the last transfer *)
    failed: BOOLEAN;        (* a direction failed; both are shut down *)
    next: Conn
  END;
  Pipe = POINTER TO RECORD (Tasks.TaskDesc)
    c: Conn;
    from, to: Sockets.Socket
  END;
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket
  END;

VAR
  host: ARRAY 256 OF CHAR;
  targetPort: INTEGER;
  count, idle: LONGINT;     (* connections to serve (0: no end), ms idle *)
  served: LONGINT;
  stop: BOOLEAN;
  conns: Conn;              (* every connection's task, to join at the end *)

PROCEDURE Report(err: Sockets.Error);
BEGIN
  Err.String("Forward: "); Err.String(err.text); Err.Ln
END Report;

(* Gives s a deadline idle ms after c's last transfer; FALSE if that has
   already passed. *)
PROCEDURE Due(c: Conn; s: Sockets.Socket): BOOLEAN;
  VAR left: LONGINT;
BEGIN
  left := c.last + idle - Sockets.Now();
  IF left <= 0 THEN RETURN FALSE END;
  Sockets.SetDeadline(s, left);
  RETURN TRUE
END Due;

(* Whether a call that failed with err may be tried again: it timed out,
   but the connection has moved since (the other direction). *)
PROCEDURE Again(c: Conn; err: Sockets.Error): BOOLEAN;
BEGIN
  RETURN (err.kind = Sockets.timedOut) & ~c.failed
    & (Sockets.Now() - c.last < idle)
END Again;

(* Shuts down both sides, waking the other direction's waits with end of
   stream. Errors are of no interest now. *)
PROCEDURE Fail(c: Conn);
  VAR err: Sockets.Error; ok: BOOLEAN;
BEGIN
  IF ~c.failed THEN
    c.failed := TRUE;
    ok := Sockets.Shutdown(c.client, Sockets.shutBoth, err);
    ok := Sockets.Shutdown(c.target, Sockets.shutBoth, err)
  END
END Fail;

(* Copies from p.from to p.to; at the end of p.from's stream, ends p.to's
   writing side too. *)
PROCEDURE (p: Pipe) Run*;
  VAR buf: ARRAY 8192 OF CHAR; n, pos, k: LONGINT; err: Sockets.Error;
BEGIN
  LOOP
    IF p.c.failed OR ~Due(p.c, p.from) THEN Fail(p.c); EXIT END;
    IF SocketTasks.Read(p.from, buf, 0, LEN(buf), n, err) THEN
      p.c.last := Sockets.Now(); pos := 0;
      LOOP
        IF ~Due(p.c, p.to) THEN Fail(p.c); EXIT END;
        IF SocketTasks.WriteAll(p.to, buf, pos, n - pos, k, err) THEN EXIT END;
        pos := pos + k;
        IF k > 0 THEN p.c.last := Sockets.Now() END;
        IF ~Again(p.c, err) THEN
          IF ~p.c.failed & (err.kind # Sockets.timedOut) THEN Report(err) END;
          Fail(p.c); EXIT
        END
      END;
      IF p.c.failed THEN EXIT END
    ELSIF err.kind = Sockets.closed THEN
      IF ~p.c.failed & ~Sockets.Shutdown(p.to, Sockets.shutWrite, err) THEN
        Report(err); Fail(p.c)
      END;
      EXIT
    ELSIF ~Again(p.c, err) THEN
      IF ~p.c.failed & (err.kind # Sockets.timedOut) THEN Report(err) END;
      Fail(p.c); EXIT
    END
  END
END Run;

(* Connects onward, then copies both ways until both have ended. *)
PROCEDURE (c: Conn) Run*;
  VAR up, down: Pipe; err: Sockets.Error;
BEGIN
  IF ~SocketTasks.Connect(host, targetPort, Limit, c.target, err) THEN
    Report(err); Sockets.Close(c.client); RETURN
  END;
  c.last := Sockets.Now();
  NEW(up); up.c := c; up.from := c.client; up.to := c.target;
  NEW(down); down.c := c; down.from := c.target; down.to := c.client;
  Tasks.Start(up, Stack); Tasks.Start(down, Stack);
  Tasks.Join(up); Tasks.Join(down);
  Sockets.Close(c.client); Sockets.Close(c.target)
END Run;

(* Accepts connections on l, starting a Conn for each, until stop. *)
PROCEDURE (a: Acceptor) Run*;
  VAR c: Conn; peer: Sockets.Address; err: Sockets.Error;
BEGIN
  WHILE ~stop DO
    NEW(c);
    Sockets.SetDeadline(a.l, Tick);
    IF SocketTasks.Accept(a.l, c.client, peer, err) THEN
      c.next := conns; conns := c; Tasks.Start(c, Stack);
      INC(served);
      IF served = count THEN stop := TRUE END
    ELSIF err.kind # Sockets.timedOut THEN
      (* EMFILE, a connection reset while queued: report, go on *)
      Report(err); Tasks.Sleep(10)
    END
  END;
  Sockets.Close(a.l)
END Run;

PROCEDURE Usage;
BEGIN
  Err.String("usage: Forward port host target-port [count [idle-ms]]"); Err.Ln;
  Platform.Exit(2)
END Usage;

PROCEDURE Main;
  VAR ls: ARRAY 2 OF Sockets.Socket; as: ARRAY 2 OF Acceptor;
    a: Sockets.Address; err: Sockets.Error; port, tp: LONGINT; n, i: INTEGER;
BEGIN
  IF (Args.argc < 4) OR (Args.argc > 6) THEN Usage END;
  port := -1; Args.GetInt(1, port);
  Args.Get(2, host);
  tp := -1; Args.GetInt(3, tp);
  count := 0; IF Args.argc > 4 THEN Args.GetInt(4, count) END;
  idle := 300000; IF Args.argc > 5 THEN Args.GetInt(5, idle) END;
  IF (port < 0) OR (port > 65535) OR (host = "") OR (tp < 1) OR (tp > 65535)
    OR (count < 0) OR (idle < 1) THEN
    Usage
  END;
  targetPort := SHORT(tp);
  Sockets.IgnoreBrokenPipe;
  IF ~Sockets.Listen("", SHORT(port), 16, TRUE, ls, n, err)
    OR ~Sockets.LocalAddress(ls[0], a, err) THEN
    Report(err); Platform.Exit(1)
  END;
  Out.String("port "); Out.Int(a.port, 0); Out.Ln;
  FOR i := 0 TO n - 1 DO NEW(as[i]); as[i].l := ls[i]; Tasks.Start(as[i], Stack) END;
  FOR i := 0 TO n - 1 DO Tasks.Join(as[i]) END;
  WHILE conns # NIL DO Tasks.Join(conns); conns := conns.next END
END Main;

BEGIN
  Main
END Forward.
