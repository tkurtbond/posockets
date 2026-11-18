MODULE TestAwait; (* deadlines without tasks: Await and ConnectWithin *)

(* PLAN.md, Phase 10: Sockets.Await waiting in the kernel until a socket
   is ready or its deadline passes, and Sockets.ConnectWithin, the
   blocking counterpart of SocketTasks.Connect. A peer that sends
   nothing is given up on near the deadline, one that has sent is seen
   at once, even past the deadline; a writer to a peer that doesn't read
   (small buffers) times out; ConnectWithin connects, blocking or not,
   is refused, and times out against a full queue (FreeBSD resets it at
   once instead: TestDeadline). All over 127.0.0.1, and with no tasks:
   this program doesn't import Tasks, so memcheck can follow it. *)

IMPORT Sockets, Check, TestHelp;

CONST
  Slack = 500;             (* ms a timed wait may run late on a busy machine *)
  Fill = 150;              (* connections tried at most, to fill a queue *)

VAR
  l, c, s, c2: Sockets.Socket;
  ls: ARRAY 2 OF Sockets.Socket;
  cs: ARRAY Fill + 1 OF Sockets.Socket;
  queued: INTEGER;
  a, peer: Sockets.Address;
  err: Sockets.Error;
  n, fds0, port: INTEGER;
  t0, el, got: LONGINT;
  ok: BOOLEAN;
  buf: ARRAY 100000 OF CHAR;
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

(* Waits ms without a socket: there are no tasks to sleep in. *)
PROCEDURE Pause(ms: LONGINT);
  VAR end: LONGINT;
BEGIN
  end := Sockets.Now() + ms;
  WHILE Sockets.Now() < end DO END
END Pause;

(* The next connection on l, waited for at most 1 s by Await. *)
PROCEDURE Accepted(l: Sockets.Socket; VAR s: Sockets.Socket): BOOLEAN;
  VAR ok: BOOLEAN;
BEGIN
  Sockets.SetDeadline(l, 1000);
  ok := Sockets.Await(l, Sockets.wantRead, "accept", err)
    & Sockets.Accept(l, TRUE, s, peer, err);
  Sockets.SetDeadline(l, 0);
  RETURN ok
END Accepted;

BEGIN
  (* The resolver may keep descriptors after a lookup that asks a name
     server: NetBSD's keeps a kqueue (PLAN.md, Phase 9). Look one up
     now, so that they are counted in fds0. *)
  ok := Sockets.ConnectWithin("nonexistent.invalid", 80, 1000, FALSE, c, err);
  fds0 := TestHelp.OpenFds();
  ok := Sockets.Listen("127.0.0.1", 0, 5, TRUE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err);
  Check.Check(ok, "a non-blocking listener on 127.0.0.1");
  l := ls[0];

  (* ConnectWithin, non-blocking, and Await on a listener *)
  ok := Sockets.ConnectWithin("127.0.0.1", a.port, 1000, TRUE, c, err);
  Check.Check(ok & c.nonBlocking & (c.deadline = 0),
    "ConnectWithin connects, non-blocking, leaving no deadline");
  Check.Check(Accepted(l, s), "Await sees a connection queued on a listener");

  (* A peer that sends nothing *)
  Sockets.SetDeadline(s, 200);
  t0 := Sockets.Now();
  ok := Sockets.Await(s, Sockets.wantRead, "recv", err);
  el := Sockets.Now() - t0;
  Check.Check(~ok & (err.kind = Sockets.timedOut) & Near(el, 200),
    "Await on a peer that sends nothing times out near the deadline");
  Check.Check((err.text = "recv: timed out") & (s.fd # -1),
    "its text says so, and the socket is still open");
  ok := ~Sockets.Read(s, buf, 0, 10, got, err) & (err.kind = Sockets.wouldBlock);
  Check.Check(ok, "and there is still nothing to read");

  (* A peer that has sent *)
  buf[0] := "x";
  ok := Sockets.Write(c, buf, 0, 1, got, err) & (got = 1);
  Sockets.SetDeadline(s, 1000);
  t0 := Sockets.Now();
  ok := ok & Sockets.Await(s, Sockets.wantRead, "recv", err);
  el := Sockets.Now() - t0;
  Check.Check(ok & (el < 200), "Await sees data that has come, before the deadline");
  Sockets.SetDeadline(s, 1); Pause(10);
  ok := Sockets.TimeLeft(s) = 0;
  Check.Check(ok & Sockets.Await(s, Sockets.wantRead, "recv", err),
    "and with the deadline past, still sees it");
  Sockets.SetDeadline(s, 0);
  ok := Sockets.Await(s, Sockets.wantRead, "recv", err)
    & Sockets.Read(s, buf, 0, 10, got, err) & (got = 1) & (buf[0] = "x");
  Check.Check(ok, "and with none, and the data is read");

  (* The peer closes: ready, and the read says so *)
  Sockets.Close(c);
  Sockets.SetDeadline(s, 1000);
  ok := Sockets.Await(s, Sockets.wantRead, "recv", err)
    & ~Sockets.Read(s, buf, 0, 10, got, err) & (err.kind = Sockets.closed);
  Check.Check(ok, "a peer's close makes s ready, and Read gives closed");
  Sockets.Close(s);

  (* Writing to a peer that doesn't read *)
  ok := Sockets.ConnectWithin("127.0.0.1", a.port, 1000, TRUE, c, err)
    & Accepted(l, s);
  ok := ok & TestHelp.SmallSendBuffer(c.fd, 4096) & TestHelp.SmallReceiveBuffer(s.fd, 4096);
  Sockets.SetDeadline(c, 1000);
  Check.Check(ok & Sockets.Await(c, Sockets.wantWrite, "send", err),
    "Await sees an empty send buffer writable");
  (* Write, and on wouldBlock Await, as a blocking client would. On the
     BSDs, whose loopback delivers a moment after send returns, a
     buffer full at one write may have room again at the next poll. *)
  Sockets.SetDeadline(c, 200);
  t0 := Sockets.Now();
  LOOP
    IF ~ok THEN EXIT
    ELSIF Sockets.Write(c, buf, 0, LEN(buf), got, err) THEN (* more *)
    ELSIF (err.kind # Sockets.wouldBlock) OR (err.want # Sockets.wantWrite) THEN EXIT
    ELSIF ~Sockets.Await(c, err.want, "send", err) THEN EXIT
    END
  END;
  el := Sockets.Now() - t0;
  Check.Check(ok & (err.kind = Sockets.timedOut) & Near(el, 200)
    & (err.text = "send: timed out"),
    "writing to a peer that doesn't read, Await times out near the deadline");
  Sockets.Close(c); Sockets.Close(s);

  (* ConnectWithin, blocking, and with no limit *)
  ok := Sockets.ConnectWithin("127.0.0.1", a.port, 1000, FALSE, c, err);
  Check.Check(ok & ~c.nonBlocking & (c.deadline = 0), "ConnectWithin connects, blocking");
  ok := Accepted(l, s);
  buf[0] := "y";
  ok := ok & Sockets.Write(s, buf, 0, 1, got, err)
    & Sockets.Read(c, buf, 1, 1, got, err) & (got = 1) & (buf[1] = "y");
  Check.Check(ok, "and the blocking socket reads what the peer sends");
  Sockets.Close(c); Sockets.Close(s);
  ok := Sockets.ConnectWithin("127.0.0.1", a.port, 0, TRUE, c, err) & Accepted(l, s);
  Check.Check(ok & (c.deadline = 0), "ConnectWithin with no limit connects");
  Sockets.Close(c); Sockets.Close(s);
  port := a.port;
  Sockets.Close(l);

  (* Refused: nothing listens on the port now *)
  t0 := Sockets.Now();
  ok := ~Sockets.ConnectWithin("127.0.0.1", port, 1000, FALSE, c, err);
  el := Sockets.Now() - t0;
  ConnectLabel(port, label);
  Check.Check(ok & (c = NIL) & (err.kind = Sockets.system)
    & (err.code = Sockets.ECONNREFUSED) & (el < 1000),
    "ConnectWithin to a closed port is refused at once");
  Check.Check(StartsWith(err.text, label), "its text names the address");

  (* A name that doesn't resolve *)
  ok := ~Sockets.ConnectWithin("nonexistent.invalid", 80, 1000, FALSE, c, err);
  Check.Check(ok & (c = NIL) & (err.kind = Sockets.name)
    & StartsWith(err.text, "resolve nonexistent.invalid port 80"),
    "ConnectWithin to a name that doesn't resolve gives a name error");

  (* A listener whose queue is full (TestDeadline): connect until one
     doesn't, which times out at its limit, or on FreeBSD is reset. *)
  ok := Sockets.Listen("127.0.0.1", 0, 0, TRUE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err);
  l := ls[0]; queued := 0;
  LOOP
    IF ~ok OR (queued = Fill) THEN EXIT END;
    t0 := Sockets.Now();
    IF ~Sockets.ConnectWithin("127.0.0.1", a.port, 200, TRUE, cs[queued], err) THEN EXIT END;
    INC(queued)
  END;
  el := Sockets.Now() - t0;
  ok := ok & (queued >= 1) & (queued < Fill) & (cs[queued] = NIL);
  ConnectLabel(a.port, label);
  IF ok & (err.kind = Sockets.timedOut) THEN
    Check.Check(Near(el, 200), "ConnectWithin to a full queue times out at its limit");
    Append(label, "timed out");
    Check.Check(err.text = label, "its text names the address")
  ELSE
    Check.Check(ok & (err.kind = Sockets.system) & (err.code = Sockets.ECONNRESET)
      & (el < 200), "ConnectWithin to a full queue is reset at once");
    Check.Check(StartsWith(err.text, label), "its text names the address")
  END;
  WHILE queued > 0 DO DEC(queued); Sockets.Close(cs[queued]) END;
  Sockets.Close(l);

  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again");
  Check.Summary
END TestAwait.
