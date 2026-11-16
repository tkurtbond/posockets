MODULE TestForward; (* examples/Forward, between clients and servers here *)

(* PLAN.md, Phase 8: three Forwards are started in the background on
   port 0, each to serve a fixed number of connections with a 500 ms
   idle limit, in front of a target here:

   - "ForwardEcho", in front of an echo server: clients send more than
     the socket buffers hold, over IPv4 and (when ::1 can be bound)
     IPv6, end their side, and must get back all they sent, then end of
     stream (the half-close passed through both ways); a client that
     sends nothing is closed once the idle limit passes.
   - "ForwardStream", in front of a server that sends a chunk every
     100 ms for 1.5 s: a client that sends nothing must get it all,
     since the limit is on the connection, not on each direction.
   - "ForwardRefused", to a port nothing listens on: its client is
     closed, and it says why.

   Each must then exit 0 by itself. *)

IMPORT Platform, Out, Coroutines, Tasks, Sockets, SocketTasks, Check, TestHelp, Run;

CONST
  Size = 200000;
  Buffers = 4096;
  Idle = 500;               (* the forwarders' idle limit, ms *)
  Chunks = 15;              (* the stream's, one every Gap ms *)
  Gap = 100;
  Stack = Coroutines.DefaultStackSize;
  Patience = 60000;
  Tick = 200;

TYPE
  (* the targets here *)
  Server = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket;
    stream: BOOLEAN         (* send chunks, else echo *)
  END;
  Serve = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    stream: BOOLEAN;
    next: Serve
  END;
  (* the clients *)
  Client = POINTER TO RECORD (Tasks.TaskDesc)
    host: ARRAY 16 OF CHAR;
    ok: BOOLEAN;
    why: ARRAY 256 OF CHAR
  END;
  Writer = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    ok: BOOLEAN
  END;
  Quiet = POINTER TO RECORD (Tasks.TaskDesc)
    port: LONGINT;
    ok: BOOLEAN;
    got, took: LONGINT     (* bytes read before the end, ms it took *)
  END;
  Watchdog = POINTER TO RECORD (Tasks.TaskDesc) END;

VAR
  echoPort, streamPort, refusedPort: LONGINT;
  stop: BOOLEAN;
  serves: Serve;
  servers: ARRAY 2 OF Server;
  nservers: INTEGER;
  watchdog: Watchdog;

PROCEDURE StopAll;
BEGIN
  Run.Stop("ForwardEcho"); Run.Stop("ForwardStream"); Run.Stop("ForwardRefused")
END StopAll;

PROCEDURE (w: Watchdog) Run*;
BEGIN
  Tasks.Sleep(Patience);
  Out.String("FAIL - the test took longer than "); Out.Int(Patience DIV 1000, 0);
  Out.String(" s"); Out.Ln;
  StopAll;
  Platform.Exit(1)
END Run;

PROCEDURE AppendInt(VAR s: ARRAY OF CHAR; n: LONGINT);
  VAR d: ARRAY 24 OF CHAR; i, j: INTEGER;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  j := 0; WHILE s[j] # 0X DO INC(j) END;
  WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END;
  s[j] := 0X
END AppendInt;

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  j := 0; WHILE (j < LEN(t)) & (t[j] # 0X) DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

PROCEDURE HaveIPv6(): BOOLEAN;
  VAR ls: ARRAY 2 OF Sockets.Socket; n: INTEGER; err: Sockets.Error;
BEGIN
  IF Sockets.Listen("::1", 0, 1, FALSE, ls, n, err) THEN
    Sockets.Close(ls[0]); RETURN TRUE
  END;
  RETURN FALSE
END HaveIPv6;

(* Echoes until the end of stream, or sends Chunks chunks Gap ms apart;
   then closes. *)
PROCEDURE (t: Serve) Run*;
  VAR buf: ARRAY 4096 OF CHAR; n, k, i: LONGINT; err: Sockets.Error;
BEGIN
  Sockets.SetDeadline(t.s, 20000);
  IF t.stream THEN
    FOR i := 0 TO 99 DO buf[i] := "x" END;
    i := 0;
    WHILE (i < Chunks) & SocketTasks.WriteAll(t.s, buf, 0, 100, k, err) DO
      Tasks.Sleep(Gap); INC(i)
    END
  ELSE
    WHILE SocketTasks.Read(t.s, buf, 0, LEN(buf), n, err)
      & SocketTasks.WriteAll(t.s, buf, 0, n, k, err) DO
    END
  END;
  Sockets.Close(t.s)
END Run;

PROCEDURE (t: Server) Run*;
  VAR c: Serve; peer: Sockets.Address; err: Sockets.Error;
BEGIN
  WHILE ~stop DO
    NEW(c); c.stream := t.stream;
    Sockets.SetDeadline(t.l, Tick);
    IF SocketTasks.Accept(t.l, c.s, peer, err) THEN
      c.next := serves; serves := c; Tasks.Start(c, Stack)
    END
  END;
  Sockets.Close(t.l)
END Run;

(* A target server on 127.0.0.1, its port. *)
PROCEDURE StartServer(stream: BOOLEAN; VAR port: LONGINT): BOOLEAN;
  VAR ls: ARRAY 2 OF Sockets.Socket; a: Sockets.Address; err: Sockets.Error;
    n: INTEGER; t: Server;
BEGIN
  IF ~Sockets.Listen("127.0.0.1", 0, 16, TRUE, ls, n, err)
    OR ~Sockets.LocalAddress(ls[0], a, err) THEN
    RETURN FALSE
  END;
  NEW(t); t.l := ls[0]; t.stream := stream; Tasks.Start(t, Stack);
  servers[nservers] := t; INC(nservers);
  port := a.port;
  RETURN TRUE
END StartServer;

(* Starts a Forward as name to target, serving count; its port. *)
PROCEDURE StartForward(name: ARRAY OF CHAR; target, count: LONGINT;
    VAR port: LONGINT): BOOLEAN;
  VAR cmd: ARRAY 256 OF CHAR; path: ARRAY 64 OF CHAR;
BEGIN
  cmd := "../build/Forward 0 127.0.0.1 "; AppendInt(cmd, target);
  Append(cmd, " "); AppendInt(cmd, count); Append(cmd, " ");
  AppendInt(cmd, Idle); Append(cmd, " < /dev/null");
  Run.Start(cmd, name);
  Run.File(name, ".out", path);
  RETURN Run.Number(path, "port ", 10000, port) & (port > 0)
END StartForward;

(* Size bytes of a pattern, then end of stream. *)
PROCEDURE (w: Writer) Run*;
  VAR buf: ARRAY 7000 OF CHAR; sent, k, i: LONGINT; err: Sockets.Error;
BEGIN
  w.ok := TRUE; sent := 0;
  WHILE w.ok & (sent < Size) DO
    k := LEN(buf); IF Size - sent < k THEN k := Size - sent END;
    FOR i := 0 TO k - 1 DO buf[i] := CHR((sent + i) MOD 251) END;
    w.ok := SocketTasks.WriteAll(w.s, buf, 0, k, i, err) & (i = k);
    sent := sent + k
  END;
  w.ok := w.ok & Sockets.Shutdown(w.s, Sockets.shutWrite, err)
END Run;

(* Sends the pattern from a Writer while reading the echo here. *)
PROCEDURE (t: Client) Run*;
  VAR s: Sockets.Socket; w: Writer; err: Sockets.Error;
    buf: ARRAY 5000 OF CHAR; n, got, i, port: LONGINT;
BEGIN
  t.ok := FALSE;
  IF ~Run.Number("../build/ForwardEcho.out", "port ", 10000, port) THEN
    t.why := "no port"; RETURN
  END;
  IF ~SocketTasks.Connect(t.host, SHORT(port), 10000, s, err) THEN
    COPY(err.text, t.why); RETURN
  END;
  IF ~TestHelp.SmallSendBuffer(s.fd, Buffers) THEN
    t.why := "SO_SNDBUF"; Sockets.Close(s); RETURN
  END;
  NEW(w); w.s := s; Tasks.Start(w, Stack);
  got := 0; t.ok := TRUE;
  Sockets.SetDeadline(s, 20000);
  WHILE t.ok & SocketTasks.Read(s, buf, 0, LEN(buf), n, err) DO
    FOR i := 0 TO n - 1 DO t.ok := t.ok & (buf[i] = CHR((got + i) MOD 251)) END;
    got := got + n
  END;
  IF ~t.ok THEN t.why := "the echo isn't what was sent"
  ELSIF err.kind # Sockets.closed THEN t.ok := FALSE; COPY(err.text, t.why)
  ELSIF got # Size THEN t.ok := FALSE; t.why := "the echo is short"
  END;
  Tasks.Join(w);
  IF ~w.ok THEN t.ok := FALSE; t.why := "the writer failed" END;
  Sockets.Close(s)
END Run;

(* Connects, sends nothing, and reads until the end. *)
PROCEDURE (t: Quiet) Run*;
  VAR s: Sockets.Socket; err: Sockets.Error; buf: ARRAY 256 OF CHAR;
    n, t0: LONGINT;
BEGIN
  t.ok := SocketTasks.Connect("127.0.0.1", SHORT(t.port), 10000, s, err);
  IF ~t.ok THEN RETURN END;
  t0 := Sockets.Now(); t.got := 0;
  Sockets.SetDeadline(s, 20000);
  WHILE SocketTasks.Read(s, buf, 0, LEN(buf), n, err) DO t.got := t.got + n END;
  t.ok := err.kind = Sockets.closed;
  t.took := Sockets.Now() - t0;
  Sockets.Close(s)
END Run;

PROCEDURE Report(c: Client);
BEGIN
  IF ~c.ok THEN Out.String("# "); Out.String(c.host); Out.String(": "); Out.String(c.why); Out.Ln END
END Report;

PROCEDURE Ended(name: ARRAY OF CHAR);
  VAR status: INTEGER; ok: BOOLEAN; label: ARRAY 128 OF CHAR;
BEGIN
  ok := Run.Wait(name, 10000, status);
  label := ""; Append(label, name); Append(label, " exits 0 once it has served them all");
  Check.Check(ok & (status = 0), label);
  Run.Stop(name)
END Ended;

PROCEDURE Main;
  VAR fds0, n: INTEGER; ipv6, ok: BOOLEAN; port: LONGINT; c4, c6: Client;
    silent, streamed, refused: Quiet; ls: ARRAY 2 OF Sockets.Socket;
    a: Sockets.Address; err: Sockets.Error; text: ARRAY 128 OF CHAR;
    b: Run.Bytes; i: INTEGER;
BEGIN
  IF Tasks.WakeDescriptor() < 0 THEN Check.Check(FALSE, "Tasks has its self-pipe") END;
  fds0 := TestHelp.OpenFds();
  ipv6 := HaveIPv6();

  ok := StartServer(FALSE, echoPort) & StartServer(TRUE, streamPort);
  Check.Check(ok, "the targets listen");
  IF ~ok THEN RETURN END;
  (* a port nothing listens on *)
  ok := Sockets.Listen("127.0.0.1", 0, 1, FALSE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err);
  IF ok THEN Sockets.Close(ls[0]); refusedPort := a.port END;

  n := 2; IF ipv6 THEN INC(n) END;
  ok := StartForward("ForwardEcho", echoPort, n, port);
  Check.Check(ok, "a Forward says its port first");
  IF ~ok THEN StopAll; RETURN END;
  NEW(c4); c4.host := "127.0.0.1"; Tasks.Start(c4, Stack);
  IF ipv6 THEN NEW(c6); c6.host := "::1"; Tasks.Start(c6, Stack) END;
  NEW(silent); silent.port := port; Tasks.Start(silent, Stack);

  IF StartForward("ForwardStream", streamPort, 1, port) THEN
    NEW(streamed); streamed.port := port; Tasks.Start(streamed, Stack)
  END;
  IF StartForward("ForwardRefused", refusedPort, 1, port) THEN
    NEW(refused); refused.port := port; Tasks.Start(refused, Stack)
  END;

  Tasks.Join(c4); Report(c4);
  Check.Check(c4.ok, "a client over IPv4 gets back the 200000 bytes it sent");
  IF ipv6 THEN
    Tasks.Join(c6); Report(c6);
    Check.Check(c6.ok, "a client over IPv6 gets back the 200000 bytes it sent")
  ELSE Check.Check(TRUE, "IPv6 skipped: ::1 can't be bound")
  END;
  Tasks.Join(silent);
  Check.Check(silent.ok & (silent.got = 0) & (silent.took >= Idle - 50)
    & (silent.took < Idle + 2000),
    "a connection with nothing moving is closed after the idle limit");
  Ended("ForwardEcho");

  Check.Check(streamed # NIL, "a second Forward says its port");
  IF streamed # NIL THEN
    Tasks.Join(streamed);
    Check.Check(streamed.ok & (streamed.got = Chunks * 100)
      & (streamed.took >= Chunks * Gap - 50),
      "a client that sends nothing gets a stream longer than the idle limit");
    Ended("ForwardStream")
  END;

  Check.Check(refused # NIL, "a third Forward says its port");
  IF refused # NIL THEN
    Tasks.Join(refused);
    Check.Check(refused.ok & (refused.got = 0),
      "a refused onward connection closes the client's");
    Ended("ForwardRefused");
    text := "Forward: connect to 127.0.0.1 port "; AppendInt(text, refusedPort);
    b := Run.Read("../build/ForwardRefused.err");
    i := 0;
    WHILE (b # NIL) & (text[i] # 0X) & (b[i] = text[i]) DO INC(i) END;
    Check.Check((b # NIL) & (text[i] = 0X), "and Forward says why")
  END;

  stop := TRUE;
  FOR i := 0 TO nservers - 1 DO Tasks.Join(servers[i]) END;
  WHILE serves # NIL DO Tasks.Join(serves); serves := serves.next END;
  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again")
END Main;

BEGIN
  NEW(watchdog); Tasks.Start(watchdog, Stack);
  Main;
  Check.Summary
END TestForward.
