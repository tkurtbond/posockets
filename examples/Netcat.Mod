MODULE Netcat; (* Standard input to a socket, the socket to standard output *)

(* Usage: Netcat host port         connect over TCP
          Netcat -U path           connect to a Unix-domain socket
          Netcat -l host port      listen over TCP, take one connection
          Netcat -l -U path        listen on a Unix-domain path, take one

   Copies standard input to the connection and the connection to
   standard output, until both directions have ended. When standard
   input ends, Netcat ends its side of the connection (Shutdown), so the
   peer reads end of stream and can still answer; when the peer ends its
   side, Netcat goes on sending until standard input ends. Exits 0 when
   both ended cleanly, 1 on an error, saying what failed on standard
   error.

   Listening, it says where on standard error ("listening on 127.0.0.1
   port 40123"; port 0 gives one the kernel chooses), takes the first
   connection and closes the listener. A Unix-domain path must not exist
   yet; Netcat removes the file it made once it has the connection.

   Two tasks share the one thread: one waits for standard input
   (Tasks.AwaitReadable on descriptor 0) and writes to the socket, the
   other reads the socket and writes standard output. Writing standard
   output is a plain blocking write: if the reader of a pipe stops
   reading, every task stops with it. *)

IMPORT SYSTEM, Platform, Err, Args, Coroutines, Tasks, Sockets, SocketTasks;

CONST
  Stack = Coroutines.DefaultStackSize;
  Tick = 200;               (* ms an accept waits before looking again *)
  Limit = 10000;            (* ms allowed to connect *)

TYPE
  Up = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    ok: BOOLEAN
  END;
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket
  END;

VAR
  conn: Sockets.Socket;     (* the connection, once there is one *)
  failed: BOOLEAN;          (* an accept failed other than by timing out *)

PROCEDURE Report(err: Sockets.Error);
BEGIN
  Err.String("Netcat: "); Err.String(err.text); Err.Ln
END Report;

(* Standard input to the socket, then Shutdown. *)
PROCEDURE (u: Up) Run*;
  VAR buf: ARRAY 4096 OF CHAR; n, k: LONGINT; err: Sockets.Error;
BEGIN
  u.ok := TRUE;
  LOOP
    Tasks.AwaitReadable(Platform.StdIn);
    IF Platform.Read(Platform.StdIn, SYSTEM.ADR(buf), LEN(buf), n) # 0 THEN
      Err.String("Netcat: reading standard input failed"); Err.Ln;
      u.ok := FALSE; EXIT
    END;
    IF n = 0 THEN EXIT END;
    IF ~SocketTasks.WriteAll(u.s, buf, 0, n, k, err) THEN
      Report(err); u.ok := FALSE; EXIT
    END
  END;
  IF ~Sockets.Shutdown(u.s, Sockets.shutWrite, err) & u.ok THEN
    Report(err); u.ok := FALSE
  END
END Run;

(* Takes the first connection on l, unless another Acceptor has. *)
PROCEDURE (a: Acceptor) Run*;
  VAR s: Sockets.Socket; peer: Sockets.Address; err: Sockets.Error;
BEGIN
  WHILE (conn = NIL) & ~failed DO
    Sockets.SetDeadline(a.l, Tick);
    IF SocketTasks.Accept(a.l, s, peer, err) THEN
      IF conn = NIL THEN conn := s ELSE Sockets.Close(s) END
    ELSIF err.kind # Sockets.timedOut THEN
      Report(err); failed := TRUE
    END
  END
END Run;

(* Listens on host and port, or on path if host is "", and takes one
   connection as conn. *)
PROCEDURE ListenOnce(host, path: ARRAY OF CHAR; port: INTEGER): BOOLEAN;
  VAR ls: ARRAY 2 OF Sockets.Socket; as: ARRAY 2 OF Acceptor;
    a: Sockets.Address; err: Sockets.Error; n, i: INTEGER; ok: BOOLEAN;
    e: Platform.ErrorCode; name: ARRAY 128 OF CHAR;
BEGIN
  IF host # "" THEN
    ok := Sockets.Listen(host, port, 1, TRUE, ls, n, err)
      & Sockets.LocalAddress(ls[0], a, err)
  ELSE
    ok := Sockets.ListenUnix(path, 1, TRUE, ls[0], err); n := 1
  END;
  IF ~ok THEN Report(err); RETURN FALSE END;
  Err.String("listening on ");
  IF host # "" THEN Err.String(host); Err.String(" port "); Err.Int(a.port, 0)
  ELSE Err.String(path)
  END;
  Err.Ln;
  FOR i := 0 TO n - 1 DO NEW(as[i]); as[i].l := ls[i]; Tasks.Start(as[i], Stack) END;
  FOR i := 0 TO n - 1 DO Tasks.Join(as[i]); Sockets.Close(ls[i]) END;
  IF host = "" THEN COPY(path, name); e := Platform.Unlink(name) END;
  RETURN conn # NIL
END ListenOnce;

PROCEDURE Usage;
BEGIN
  Err.String("usage: Netcat [-l] host port | Netcat [-l] -U path"); Err.Ln;
  Platform.Exit(2)
END Usage;

PROCEDURE Main;
  VAR arg, host, path: ARRAY 256 OF CHAR; port: LONGINT; i: INTEGER;
    listen, ok: BOOLEAN; up: Up; buf: ARRAY 4096 OF CHAR; n: LONGINT;
    err: Sockets.Error;
BEGIN
  i := 1; listen := FALSE; host := ""; path := ""; port := 0;
  Args.Get(i, arg);
  IF arg = "-l" THEN listen := TRUE; INC(i); Args.Get(i, arg) END;
  IF arg = "-U" THEN
    IF Args.argc # i + 2 THEN Usage END;
    Args.Get(i + 1, path);
    IF path = "" THEN Usage END
  ELSE
    IF Args.argc # i + 2 THEN Usage END;
    COPY(arg, host); port := -1; Args.GetInt(i + 1, port);
    IF (host = "") OR (port < 0) OR (port > 65535) OR ~listen & (port = 0) THEN
      Usage
    END
  END;
  (* A peer that closes while Netcat writes gives EPIPE, not a signal
     that would end the program. *)
  Sockets.IgnoreBrokenPipe;

  IF listen THEN ok := ListenOnce(host, path, SHORT(port))
  ELSIF host # "" THEN ok := SocketTasks.Connect(host, SHORT(port), Limit, conn, err)
  ELSE ok := SocketTasks.ConnectUnix(path, Limit, conn, err)
  END;
  IF ~ok THEN
    IF ~listen THEN Report(err) END;
    Platform.Exit(1)
  END;

  NEW(up); up.s := conn; Tasks.Start(up, Stack);
  WHILE SocketTasks.Read(conn, buf, 0, LEN(buf), n, err) DO
    IF Platform.Write(Platform.StdOut, SYSTEM.ADR(buf), n) # 0 THEN
      Err.String("Netcat: writing standard output failed"); Err.Ln;
      Platform.Exit(1)
    END
  END;
  (* A reset, or another failure, while up may be waiting on standard
     input, which may never end: there is nothing more to do. *)
  IF err.kind # Sockets.closed THEN Report(err); Platform.Exit(1) END;
  Tasks.Join(up);
  Sockets.Close(conn);
  IF ~up.ok THEN Platform.Exit(1) END
END Main;

BEGIN
  Main
END Netcat.
