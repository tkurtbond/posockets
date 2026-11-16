MODULE TestDeadline; (* SocketTasks' deadlines and the lingering close *)

(* PLAN.md, "Testing" and "Deadlines": a peer that sends nothing is cut
   off near the deadline, one that sends in time is not, and the socket
   is usable after a timeout; a deadline already past still takes what
   is there; a WriteAll to a peer that doesn't read times out saying how
   much it wrote; an accept loop with a short deadline stops soon after
   it is told to; a connect to a listener whose queue is full times out
   (or, on FreeBSD, is reset at once), naming the address; the
   lingering close, with a peer that closes and one that doesn't. Each wait is made to happen (PLAN.md, "Testing"):
   nothing is sent, or the peer's buffers are small and it doesn't
   read. All over 127.0.0.1. A watchdog task ends the program if
   anything waits too long. *)

IMPORT Platform, Out, Coroutines, Tasks, Sockets, SocketTasks, Check, TestHelp;

CONST
  Stack = Coroutines.DefaultStackSize;
  Patience = 30000;        (* ms the watchdog allows the whole test *)
  Slack = 500;             (* ms a timed wait may run late on a busy machine *)
  Fill = 150;              (* connections tried at most, to fill a queue *)

TYPE
  (* Writes "x" to s after ms, then closes s if close is set. *)
  Late = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    ms: LONGINT;
    close: BOOLEAN
  END;
  (* Accepts on l, a deadline of ms before each, until stop is set. *)
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket;
    ms: LONGINT;
    stop: BOOLEAN;
    accepted, timeouts, errors: INTEGER;
    stopped: LONGINT       (* Sockets.Now() when it returned *)
  END;
  Watchdog = POINTER TO RECORD (Tasks.TaskDesc) END;

VAR
  l, c, s, c2, s2: Sockets.Socket;
  ls: ARRAY 2 OF Sockets.Socket;
  cs: ARRAY Fill + 1 OF Sockets.Socket;   (* the connections filling a queue *)
  queued: INTEGER;
  a: Sockets.Address;
  err: Sockets.Error;
  n, fds0: INTEGER;
  t0, el, got: LONGINT;
  ok: BOOLEAN;
  buf: ARRAY 100000 OF CHAR;
  late: Late;
  acceptor: Acceptor;
  watchdog: Watchdog;
  label: ARRAY 64 OF CHAR;

PROCEDURE StartsWith(s, prefix: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < LEN(prefix)) & (prefix[i] # 0X) DO
    IF (i >= LEN(s)) OR (s[i] # prefix[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END StartsWith;

(* Whether el, a wait's length, is ms give or take: no earlier than
   ms - 5 (the clocks' rounding), no later than ms + Slack. *)
PROCEDURE Near(el, ms: LONGINT): BOOLEAN;
BEGIN
  RETURN (el >= ms - 5) & (el <= ms + Slack)
END Near;

PROCEDURE (w: Watchdog) Run*;
BEGIN
  Tasks.Sleep(Patience);
  Out.String("FAIL - the test took longer than "); Out.Int(Patience DIV 1000, 0);
  Out.String(" s"); Out.Ln;
  Platform.Exit(1)
END Run;

PROCEDURE (t: Late) Run*;
  VAR x: ARRAY 2 OF CHAR; n: LONGINT; err: Sockets.Error; ok: BOOLEAN;
BEGIN
  Tasks.Sleep(t.ms);
  x := "x"; ok := SocketTasks.Write(t.s, x, 0, 1, n, err);
  IF t.close THEN Sockets.Close(t.s) END
END Run;

PROCEDURE (t: Acceptor) Run*;
  VAR s: Sockets.Socket; peer: Sockets.Address; err: Sockets.Error;
BEGIN
  WHILE ~t.stop DO
    Sockets.SetDeadline(t.l, t.ms);
    IF SocketTasks.Accept(t.l, s, peer, err) THEN
      INC(t.accepted); Sockets.Close(s)
    ELSIF err.kind = Sockets.timedOut THEN INC(t.timeouts)
    ELSE INC(t.errors); t.stop := TRUE
    END
  END;
  t.stopped := Sockets.Now()
END Run;

(* A connection to listener l, at address a: the client c and the
   accepted s, both non-blocking. *)
PROCEDURE Connected(l: Sockets.Socket; a: Sockets.Address;
    VAR c, s: Sockets.Socket): BOOLEAN;
  VAR peer: Sockets.Address; err: Sockets.Error;
BEGIN
  RETURN SocketTasks.ConnectTo(a, 1000, c, err)
    & SocketTasks.Accept(l, s, peer, err)
END Connected;

(* s := s + t *)
PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  j := 0;
  WHILE (t[j] # 0X) & (i < LEN(s) - 1) DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

(* label := "connect to 127.0.0.1 port <port>: " *)
PROCEDURE ConnectLabel(port: INTEGER; VAR label: ARRAY OF CHAR);
  VAR i, j: INTEGER;
BEGIN
  COPY("connect to 127.0.0.1 port ", label); i := 0;
  WHILE label[i] # 0X DO INC(i) END;
  j := 10000; WHILE j > port DO j := j DIV 10 END;
  WHILE j > 0 DO label[i] := CHR(ORD("0") + port DIV j MOD 10); INC(i); j := j DIV 10 END;
  label[i] := 0X;
  Append(label, ": ")
END ConnectLabel;

BEGIN
  NEW(watchdog); Tasks.Start(watchdog, Stack);
  IF Tasks.WakeDescriptor() < 0 THEN Check.Check(FALSE, "Tasks has its self-pipe") END;
  fds0 := TestHelp.OpenFds();

  ok := Sockets.Listen("127.0.0.1", 0, 5, TRUE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err);
  Check.Check(ok, "a non-blocking listener on 127.0.0.1");
  l := ls[0];
  ok := Connected(l, a, c, s);
  Check.Check(ok & (c.deadline = 0) & (s.deadline = 0),
    "ConnectTo with a limit gives a socket without a deadline");

  (* A peer that sends nothing *)
  Sockets.SetDeadline(s, 200);
  Check.Check(s.deadline # 0, "SetDeadline sets deadline");
  t0 := Sockets.Now();
  ok := SocketTasks.Read(s, buf, 0, 10, got, err);
  el := Sockets.Now() - t0;
  Check.Check(~ok & (err.kind = Sockets.timedOut) & Near(el, 200),
    "a Read from a peer that sends nothing times out near its deadline");
  Check.Check((err.text = "recv: timed out") & (s.fd # -1) & (s.waiters = 0),
    "its text says so, and the socket is still open, with no waiter");

  (* The same socket, a new deadline, a peer that sends in time *)
  NEW(late); late.s := c; late.ms := 50; late.close := FALSE; Tasks.Start(late, Stack);
  Sockets.SetDeadline(s, 2000);
  t0 := Sockets.Now();
  ok := SocketTasks.Read(s, buf, 0, 10, got, err);
  el := Sockets.Now() - t0;
  Tasks.Join(late);
  Check.Check(ok & (got = 1) & (buf[0] = "x") & (el < 2000),
    "after a timeout, a new deadline and data sent in time: the Read succeeds");

  (* A deadline already past: what is there is still read; when nothing
     is, it times out without waiting. The byte must have arrived before
     the Read: Linux's loopback delivers it within send, the BSDs' a
     moment later (PLAN.md, Phase 9), so poll for it, outside Tasks. *)
  Sockets.SetDeadline(s, 1); Tasks.Sleep(20);
  buf[0] := "y"; ok := SocketTasks.Write(c, buf, 0, 1, got, err);
  ok := ok & TestHelp.WaitReadable(s.fd, 5000)
    & SocketTasks.Read(s, buf, 0, 10, got, err);
  Check.Check(ok & (got = 1) & (buf[0] = "y"),
    "past its deadline, a Read that needn't wait still reads");
  t0 := Sockets.Now();
  ok := SocketTasks.Read(s, buf, 0, 10, got, err);
  el := Sockets.Now() - t0;
  Check.Check(~ok & (err.kind = Sockets.timedOut) & (el < 100),
    "past its deadline, a Read that would wait times out at once");
  Sockets.SetDeadline(s, 0);
  Check.Check(s.deadline = 0, "SetDeadline 0 clears it");

  (* A WriteAll to a peer that doesn't read *)
  ok := TestHelp.SmallSendBuffer(s.fd, 4096) & TestHelp.SmallReceiveBuffer(c.fd, 4096);
  Sockets.SetDeadline(s, 200);
  t0 := Sockets.Now();
  ok := ok & ~SocketTasks.WriteAll(s, buf, 0, LEN(buf), got, err);
  el := Sockets.Now() - t0;
  Check.Check(ok & (err.kind = Sockets.timedOut) & (err.text = "send: timed out")
    & Near(el, 200), "a WriteAll to a peer that doesn't read times out");
  Check.Check((got > 0) & (got < LEN(buf)), "saying how much it wrote");
  Sockets.Close(s); Sockets.Close(c);

  (* An accept loop that stops when told *)
  NEW(acceptor); acceptor.l := l; acceptor.ms := 100; acceptor.stop := FALSE;
  Tasks.Start(acceptor, Stack);
  Tasks.Sleep(250);
  ok := SocketTasks.ConnectTo(a, 1000, c, err);
  Tasks.Sleep(50);
  acceptor.stop := TRUE; t0 := Sockets.Now();
  Tasks.Join(acceptor);
  Check.Check(ok & (acceptor.accepted = 1) & (acceptor.timeouts >= 2)
    & (acceptor.errors = 0), "an accept loop with a deadline accepts and times out");
  Check.Check(acceptor.stopped - t0 <= 100 + Slack,
    "and stops within its interval of being told to");
  Check.Check(l.fd # -1, "the listener is still open");
  Sockets.Close(c);
  Sockets.Close(l);

  (* Connecting to a listener whose queue is full. How many connections
     a backlog of 0 queues, and what the next connect gets, differ
     (PLAN.md, Phase 9): Linux and NetBSD queue one, OpenBSD 81
     (kern.sominconn is 80), and then a SYN is dropped, so the connect
     waits until its limit; FreeBSD queues two, then resets the next
     connect at once (ECONNRESET). So connect until one doesn't. *)
  ok := Sockets.Listen("127.0.0.1", 0, 0, TRUE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err);
  l := ls[0]; queued := 0;
  LOOP
    IF ~ok OR (queued = Fill) THEN EXIT END;
    t0 := Sockets.Now();
    IF ~SocketTasks.ConnectTo(a, 200, cs[queued], err) THEN EXIT END;
    INC(queued)
  END;
  el := Sockets.Now() - t0;
  ok := ok & (queued >= 1) & (queued < Fill) & (cs[queued] = NIL);
  ConnectLabel(a.port, label);
  IF ok & (err.kind = Sockets.timedOut) THEN
    Check.Check(Near(el, 200), "a connect to a full queue times out at its limit, and is closed");
    Append(label, "timed out");
    Check.Check(err.text = label, "its text names the address");
    t0 := Sockets.Now();
    ok := ~SocketTasks.Connect("127.0.0.1", a.port, 200, c2, err);
    el := Sockets.Now() - t0;
    Check.Check(ok & (c2 = NIL) & (err.kind = Sockets.timedOut) & Near(el, 200),
      "Connect's limit too")
  ELSE
    Check.Check(ok & (err.kind = Sockets.system) & (err.code = Sockets.ECONNRESET)
      & (el < 200), "a connect to a full queue is reset at once, and is closed");
    Check.Check(StartsWith(err.text, label), "its text names the address");
    t0 := Sockets.Now();
    ok := ~SocketTasks.Connect("127.0.0.1", a.port, 200, c2, err);
    el := Sockets.Now() - t0;
    Check.Check(ok & (c2 = NIL) & (err.kind = Sockets.system)
      & (err.code = Sockets.ECONNRESET) & (el < 200), "Connect too")
  END;
  WHILE queued > 0 DO DEC(queued); Sockets.Close(cs[queued]) END;
  Sockets.Close(l);

  (* The lingering close *)
  ok := Sockets.Listen("127.0.0.1", 0, 5, TRUE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err) & Connected(ls[0], a, c, s);
  l := ls[0];
  (* The peer writes after s shuts down its side, then closes. *)
  NEW(late); late.s := c; late.ms := 50; late.close := TRUE; Tasks.Start(late, Stack);
  t0 := Sockets.Now();
  ok := ok & SocketTasks.LingeringClose(s, 2000);
  el := Sockets.Now() - t0;
  Tasks.Join(late);
  Check.Check(ok & (s.fd = -1) & (el < 2000),
    "LingeringClose: the peer sends more, then closes, in time: TRUE");
  ok := Connected(l, a, c2, s2);
  t0 := Sockets.Now();
  ok := ok & ~SocketTasks.LingeringClose(s2, 200);
  el := Sockets.Now() - t0;
  Check.Check(ok & (s2.fd = -1) & Near(el, 200),
    "LingeringClose: a peer that never closes is given up on at the limit");
  ok := ~SocketTasks.Read(c2, buf, 0, 10, got, err) & (err.kind = Sockets.closed);
  Check.Check(ok, "and the peer sees the end of the stream");
  Sockets.Close(c); Sockets.Close(s); Sockets.Close(c2); Sockets.Close(l);

  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again");
  Check.Summary
END TestDeadline.
