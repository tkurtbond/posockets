MODULE TestNetcat; (* examples/Netcat, driven from outside *)

(* PLAN.md, Phase 8: Netcat is started in the background in each of its
   modes, with this test's own binary (a large file of every byte value)
   or /dev/null as its standard input, and the test is its peer: it
   reads all Netcat sends until Netcat ends its side, answers "reply\n",
   and closes; Netcat must then have printed the reply and exited 0.
   Connecting to a closed port must exit 1 saying so, and a bad command
   line 2. *)

IMPORT Platform, Out, Coroutines, Tasks, Sockets, SocketTasks, Check, TestHelp, Run;

CONST
  Buffers = 4096;
  Stack = Coroutines.DefaultStackSize;
  Patience = 60000;
  Payload = "../build/TestNetcat";
  Sock = "../build/TestNetcat.sock";

TYPE
  Watchdog = POINTER TO RECORD (Tasks.TaskDesc) END;

VAR
  fds0: INTEGER;
  watchdog: Watchdog;
  reply: ARRAY 8 OF CHAR;

PROCEDURE (w: Watchdog) Run*;
BEGIN
  Tasks.Sleep(Patience);
  Out.String("FAIL - the test took longer than "); Out.Int(Patience DIV 1000, 0);
  Out.String(" s"); Out.Ln;
  Run.Stop("Netcat");
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

(* Reads from s until Netcat ends its side, checking it is exactly
   expect (NIL: nothing), then sends the reply and closes s. *)
PROCEDURE Exchange(s: Sockets.Socket; expect: Run.Bytes; what: ARRAY OF CHAR);
  VAR buf: ARRAY 5000 OF CHAR; n, got, size, i, k: LONGINT; err: Sockets.Error;
    same: BOOLEAN; label: ARRAY 128 OF CHAR;
BEGIN
  same := TestHelp.SmallBuffers(s.fd, Buffers);
  size := 0; IF expect # NIL THEN size := LEN(expect^) - 1 END;
  got := 0;
  Sockets.SetDeadline(s, 10000);
  WHILE SocketTasks.Read(s, buf, 0, LEN(buf), n, err) DO
    i := 0;
    WHILE same & (i < n) DO
      same := (got + i < size) & (buf[i] = expect[got + i]); INC(i)
    END;
    got := got + n
  END;
  IF err.kind # Sockets.closed THEN Out.String("# "); Out.String(err.text); Out.Ln END;
  label := ""; Append(label, what); Append(label, ": the peer reads all of standard input");
  Check.Check(same & (err.kind = Sockets.closed) & (got = size), label);
  Sockets.SetDeadline(s, 10000);
  label := ""; Append(label, what); Append(label, ": the peer can still answer");
  Check.Check(SocketTasks.WriteAll(s, reply, 0, 6, k, err), label);
  Sockets.Close(s)
END Exchange;

(* Waits for Netcat to exit and checks it exited 0 having printed the
   reply. *)
PROCEDURE Ended(what: ARRAY OF CHAR);
  VAR status: INTEGER; ok: BOOLEAN; label: ARRAY 128 OF CHAR;
BEGIN
  ok := Run.Wait("Netcat", 10000, status);
  label := ""; Append(label, what); Append(label, ": Netcat exits 0");
  Check.Check(ok & (status = 0), label);
  label := ""; Append(label, what); Append(label, ": and prints the reply");
  Check.Check(Run.Holds("../build/Netcat.out", reply), label);
  Run.Stop("Netcat")
END Ended;

(* Netcat 127.0.0.1 <port>, to a listener here. *)
PROCEDURE Connecting(payload: Run.Bytes);
  VAR ls: ARRAY 2 OF Sockets.Socket; s: Sockets.Socket; a: Sockets.Address;
    err: Sockets.Error; n: INTEGER; ok: BOOLEAN; cmd: ARRAY 256 OF CHAR;
BEGIN
  ok := Sockets.Listen("127.0.0.1", 0, 1, TRUE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err);
  Check.Check(ok, "connect: a listener for Netcat");
  IF ~ok THEN RETURN END;
  cmd := "../build/Netcat 127.0.0.1 "; AppendInt(cmd, a.port);
  Append(cmd, " < "); Append(cmd, Payload);
  Run.Start(cmd, "Netcat");
  Sockets.SetDeadline(ls[0], 10000);
  ok := SocketTasks.Accept(ls[0], s, a, err);
  Sockets.Close(ls[0]);
  Check.Check(ok, "connect: Netcat connects");
  IF ok THEN Exchange(s, payload, "connect") END;
  Ended("connect")
END Connecting;

(* Netcat -l -U <path>; the test connects once the file is there. *)
PROCEDURE ListeningUnix(payload: Run.Bytes);
  VAR s: Sockets.Socket; err: Sockets.Error; ok: BOOLEAN; end: LONGINT;
    cmd: ARRAY 256 OF CHAR; name: ARRAY 64 OF CHAR; e: Platform.ErrorCode;
    h: Platform.FileHandle;
BEGIN
  name := Sock; e := Platform.Unlink(name);
  cmd := "../build/Netcat -l -U "; Append(cmd, Sock);
  Append(cmd, " < "); Append(cmd, Payload);
  Run.Start(cmd, "Netcat");
  (* Until Netcat has bound, there is no file (ENOENT). *)
  end := Sockets.Now() + 10000;
  REPEAT
    ok := SocketTasks.ConnectUnix(Sock, 1000, s, err);
    IF ~ok THEN Tasks.Sleep(10) END
  UNTIL ok OR (Sockets.Now() > end);
  Check.Check(ok, "listen -U: Netcat takes a connection");
  IF ok THEN Exchange(s, payload, "listen -U") END;
  Ended("listen -U");
  Check.Check(Platform.OldRO(name, h) # 0, "listen -U: Netcat removes its socket file");
  e := Platform.Unlink(name)
END ListeningUnix;

(* Netcat -l 127.0.0.1 0, with nothing to send; the test reads the port
   it says on standard error. *)
PROCEDURE ListeningTCP;
  VAR s: Sockets.Socket; err: Sockets.Error; ok: BOOLEAN; port: LONGINT;
BEGIN
  Run.Start("../build/Netcat -l 127.0.0.1 0 < /dev/null", "Netcat");
  ok := Run.Number("../build/Netcat.err", "listening on 127.0.0.1 port ", 10000, port);
  Check.Check(ok & (port > 0), "listen: Netcat says its port");
  IF ok THEN
    ok := SocketTasks.Connect("127.0.0.1", SHORT(port), 10000, s, err);
    Check.Check(ok, "listen: Netcat takes a connection");
    IF ok THEN Exchange(s, NIL, "listen") END
  END;
  Ended("listen")
END ListeningTCP;

(* A port nothing listens on, and a bad command line. *)
PROCEDURE Failing;
  VAR ls: ARRAY 2 OF Sockets.Socket; a: Sockets.Address; err: Sockets.Error;
    n: INTEGER; cmd, text: ARRAY 256 OF CHAR; b: Run.Bytes; i: INTEGER;
BEGIN
  IF ~Sockets.Listen("127.0.0.1", 0, 1, FALSE, ls, n, err)
    OR ~Sockets.LocalAddress(ls[0], a, err) THEN
    Check.Check(FALSE, "a port to find closed"); RETURN
  END;
  Sockets.Close(ls[0]);
  cmd := "../build/Netcat 127.0.0.1 "; AppendInt(cmd, a.port);
  Append(cmd, " < /dev/null > ../build/Netcat.out 2> ../build/Netcat.err");
  Check.Check(Platform.System(cmd) = 1 * 256, "a refused connection: Netcat exits 1");
  text := "Netcat: connect to 127.0.0.1 port "; AppendInt(text, a.port);
  b := Run.Read("../build/Netcat.err");
  i := 0;
  WHILE (b # NIL) & (text[i] # 0X) & (b[i] = text[i]) DO INC(i) END;
  Check.Check((b # NIL) & (text[i] = 0X), "and says what failed");
  Check.Check(Platform.System("../build/Netcat -l < /dev/null 2> ../build/Netcat.err") = 2 * 256,
    "a bad command line: Netcat exits 2")
END Failing;

PROCEDURE Main;
  VAR payload: Run.Bytes;
BEGIN
  IF Tasks.WakeDescriptor() < 0 THEN Check.Check(FALSE, "Tasks has its self-pipe") END;
  fds0 := TestHelp.OpenFds();
  reply := "reply"; reply[5] := 0AX; reply[6] := 0X;
  payload := Run.Read(Payload);
  Check.Check((payload # NIL) & (LEN(payload^) > 100000), "the payload, this test's binary");
  IF payload = NIL THEN RETURN END;
  Connecting(payload);
  ListeningUnix(payload);
  ListeningTCP;
  Failing;
  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again")
END Main;

BEGIN
  NEW(watchdog); Tasks.Start(watchdog, Stack);
  Main;
  Check.Summary
END TestNetcat.
