MODULE EchoServer; (* A TCP echo server: one task per connection *)

(* Usage: EchoServer port [count [idle]]

   Listens on every local address, IPv6 and IPv4, at port (0: one the
   kernel chooses), and prints "port <n>" as its first line, so a
   program that started it on port 0 learns where it is. Each connection
   gets a task that sends back what it reads until the client ends its
   side; a client that sends nothing for idle milliseconds (default
   30000) is closed. With count, it serves that many connections, waits
   for them to end, and exits; without, it serves until killed.

   It shows Sockets.Listen giving a listener per family, an accept task
   for each, SocketTasks waiting so that one thread serves every
   connection, a deadline on each read, and an accept loop that stops:
   each accept waits at most Tick ms, then looks at a flag. *)

IMPORT Platform, Out, Err, Args, Coroutines, Tasks, Sockets, SocketTasks;

CONST
  Stack = Coroutines.DefaultStackSize;
  Tick = 200;               (* ms an accept waits before looking at stop *)

TYPE
  Echo = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    next: Echo
  END;
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket
  END;

VAR
  count, idle: LONGINT;     (* connections to serve (0: no end), ms idle *)
  served: LONGINT;
  stop: BOOLEAN;
  echoes: Echo;             (* every connection's task, to join at the end *)

(* Sends back what it reads, each read waiting at most idle ms, until
   the client ends its side, goes quiet, or fails. *)
PROCEDURE (e: Echo) Run*;
  VAR buf: ARRAY 4096 OF CHAR; n, k: LONGINT; err: Sockets.Error; ok: BOOLEAN;
BEGIN
  REPEAT
    Sockets.SetDeadline(e.s, idle);
    ok := SocketTasks.Read(e.s, buf, 0, LEN(buf), n, err)
      & SocketTasks.WriteAll(e.s, buf, 0, n, k, err)
  UNTIL ~ok;
  IF err.kind # Sockets.closed THEN Err.String(err.text); Err.Ln END;
  Sockets.Close(e.s)
END Run;

(* Accepts connections on l, starting an Echo for each, until stop. *)
PROCEDURE (a: Acceptor) Run*;
  VAR e: Echo; peer: Sockets.Address; err: Sockets.Error;
BEGIN
  WHILE ~stop DO
    NEW(e);
    Sockets.SetDeadline(a.l, Tick);
    IF SocketTasks.Accept(a.l, e.s, peer, err) THEN
      e.next := echoes; echoes := e; Tasks.Start(e, Stack);
      INC(served);
      IF served = count THEN stop := TRUE END
    ELSIF err.kind # Sockets.timedOut THEN
      (* EMFILE, a connection reset while queued: report, go on *)
      Err.String(err.text); Err.Ln; Tasks.Sleep(10)
    END
  END;
  Sockets.Close(a.l)
END Run;

PROCEDURE Main;
  VAR ls: ARRAY 2 OF Sockets.Socket; as: ARRAY 2 OF Acceptor;
    a: Sockets.Address; err: Sockets.Error; port: LONGINT; n, i: INTEGER;
BEGIN
  IF (Args.argc < 2) OR (Args.argc > 4) THEN
    Err.String("usage: EchoServer port [count [idle-ms]]"); Err.Ln; Platform.Exit(2)
  END;
  port := -1; Args.GetInt(1, port);
  count := 0; IF Args.argc > 2 THEN Args.GetInt(2, count) END;
  idle := 30000; IF Args.argc > 3 THEN Args.GetInt(3, idle) END;
  IF (port < 0) OR (port > 65535) OR (count < 0) OR (idle < 0) THEN
    Err.String("EchoServer: a bad number"); Err.Ln; Platform.Exit(2)
  END;
  IF ~Sockets.Listen("", SHORT(port), 16, TRUE, ls, n, err)
    OR ~Sockets.LocalAddress(ls[0], a, err) THEN
    Err.String(err.text); Err.Ln; Platform.Exit(1)
  END;
  (* With port 0, Listen gives both families the same port. *)
  Out.String("port "); Out.Int(a.port, 0); Out.Ln;
  FOR i := 0 TO n - 1 DO NEW(as[i]); as[i].l := ls[i]; Tasks.Start(as[i], Stack) END;
  FOR i := 0 TO n - 1 DO Tasks.Join(as[i]) END;
  WHILE echoes # NIL DO Tasks.Join(echoes); echoes := echoes.next END
END Main;

BEGIN
  Main
END EchoServer.
