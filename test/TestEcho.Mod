MODULE TestEcho; (* examples/EchoServer and EchoClient, driven from outside *)

(* PLAN.md, Phase 8: EchoServer is started in the background on port 0,
   to serve a fixed number of connections with a 500 ms idle limit, and
   its first line read for the port. EchoClient is run against it; then
   clients here, as tasks, send more than the socket buffers hold over
   IPv4 and (when ::1 can be bound) IPv6 and check the echo, while one
   that sends nothing is closed by the server once the idle limit
   passes. The server must then exit 0 by itself. *)

IMPORT Platform, Out, Coroutines, Tasks, Sockets, SocketTasks, Check, TestHelp, Run;

CONST
  Size = 200000;
  Buffers = 4096;
  Idle = 500;                (* the server's idle limit, ms *)
  Stack = Coroutines.DefaultStackSize;
  Patience = 60000;

TYPE
  Client = POINTER TO RECORD (Tasks.TaskDesc)
    host: ARRAY 16 OF CHAR;
    ok: BOOLEAN;
    why: ARRAY 256 OF CHAR
  END;
  Writer = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    ok: BOOLEAN
  END;
  Silent = POINTER TO RECORD (Tasks.TaskDesc)
    ok: BOOLEAN;
    took: LONGINT
  END;
  Watchdog = POINTER TO RECORD (Tasks.TaskDesc) END;

VAR
  port: LONGINT;
  fds0, status, count: INTEGER;
  ok, ipv6: BOOLEAN;
  watchdog: Watchdog;
  c4, c6: Client;
  silent: Silent;
  cmd: ARRAY 256 OF CHAR;
  path: ARRAY 64 OF CHAR;

PROCEDURE (w: Watchdog) Run*;
BEGIN
  Tasks.Sleep(Patience);
  Out.String("FAIL - the test took longer than "); Out.Int(Patience DIV 1000, 0);
  Out.String(" s"); Out.Ln;
  Run.Stop("EchoServer");
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
    buf: ARRAY 5000 OF CHAR; n, got, i: LONGINT;
BEGIN
  t.ok := FALSE;
  IF ~SocketTasks.Connect(t.host, SHORT(port), 10000, s, err) THEN
    COPY(err.text, t.why); RETURN
  END;
  IF ~TestHelp.SmallBuffers(s.fd, Buffers) THEN
    t.why := "SO_SNDBUF"; Sockets.Close(s); RETURN
  END;
  NEW(w); w.s := s; Tasks.Start(w, Stack);
  got := 0; t.ok := TRUE;
  Sockets.SetDeadline(s, 10000);
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

(* Connects, sends nothing, and waits for the server to close. *)
PROCEDURE (t: Silent) Run*;
  VAR s: Sockets.Socket; err: Sockets.Error; buf: ARRAY 16 OF CHAR;
    n, t0: LONGINT;
BEGIN
  t.ok := SocketTasks.Connect("127.0.0.1", SHORT(port), 10000, s, err);
  IF ~t.ok THEN RETURN END;
  t0 := Sockets.Now();
  Sockets.SetDeadline(s, 10000);
  t.ok := ~SocketTasks.Read(s, buf, 0, LEN(buf), n, err) & (err.kind = Sockets.closed);
  t.took := Sockets.Now() - t0;
  Sockets.Close(s)
END Run;

PROCEDURE Report(c: Client);
BEGIN
  IF ~c.ok THEN Out.String("# "); Out.String(c.host); Out.String(": "); Out.String(c.why); Out.Ln END
END Report;

PROCEDURE Main;
  VAR line: ARRAY 16 OF CHAR;
BEGIN
  IF Tasks.WakeDescriptor() < 0 THEN Check.Check(FALSE, "Tasks has its self-pipe") END;
  fds0 := TestHelp.OpenFds();
  ipv6 := HaveIPv6();
  count := 3; IF ipv6 THEN INC(count) END;

  cmd := "../build/EchoServer 0 "; AppendInt(cmd, count); Append(cmd, " ");
  AppendInt(cmd, Idle); Append(cmd, " < /dev/null");
  Run.Start(cmd, "EchoServer");
  Run.File("EchoServer", ".out", path);
  ok := Run.Number(path, "port ", 10000, port);
  Check.Check(ok & (port > 0), "EchoServer says its port first");
  IF ~ok THEN Run.Stop("EchoServer"); RETURN END;

  (* EchoClient, blocking, in a process of its own: every task here stops
     while it runs, but the server is in another. *)
  cmd := "../build/EchoClient localhost "; AppendInt(cmd, port);
  Append(cmd, " hello,  world < /dev/null > ../build/EchoClient.out");
  Check.Check(Platform.System(cmd) = 0, "EchoClient exits 0");
  line := "hello, world"; line[12] := 0AX; line[13] := 0X;
  Check.Check(Run.Holds("../build/EchoClient.out", line),
    "and prints the line it sent, echoed");

  NEW(c4); c4.host := "127.0.0.1"; Tasks.Start(c4, Stack);
  IF ipv6 THEN NEW(c6); c6.host := "::1"; Tasks.Start(c6, Stack) END;
  NEW(silent); Tasks.Start(silent, Stack);
  Tasks.Join(c4); Report(c4);
  Check.Check(c4.ok, "a client over IPv4 gets back the 200000 bytes it sent");
  IF ipv6 THEN
    Tasks.Join(c6); Report(c6);
    Check.Check(c6.ok, "a client over IPv6 gets back the 200000 bytes it sent")
  ELSE Check.Check(TRUE, "IPv6 skipped: ::1 can't be bound")
  END;
  Tasks.Join(silent);
  Check.Check(silent.ok & (silent.took >= Idle - 50) & (silent.took < Idle + 2000),
    "a client that sends nothing is closed after the idle limit");

  ok := Run.Wait("EchoServer", 10000, status);
  Check.Check(ok & (status = 0), "EchoServer exits 0 once it has served them all");
  Run.Stop("EchoServer");
  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again")
END Main;

BEGIN
  NEW(watchdog); Tasks.Start(watchdog, Stack);
  Main;
  Check.Summary
END TestEcho.
