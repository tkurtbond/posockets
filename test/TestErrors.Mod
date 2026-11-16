MODULE TestErrors; (* What the network and the system do, as errors *)

(* PLAN.md, "Testing": every failure here comes back as FALSE and an
   Error, never a halt or a signal. Both ends of each connection are in
   this program: a blocking connect to a loopback listener completes
   from the listener's queue before any Accept, and the data moved fits
   in the socket buffers, so nothing here waits on itself.

   The refused port is one listened on and then closed; another process
   could in principle take it between the two, a rare and recognisable
   flake on a busy machine (PLAN.md, "Testing"). *)

IMPORT SYSTEM, Platform, Sockets, Check, TestHelp;

VAR
  l, c, s, t: Sockets.Socket;
  ls: ARRAY 2 OF Sockets.Socket;
  a, peer: Sockets.Address;
  addrs: ARRAY 4 OF Sockets.Address;
  err: Sockets.Error;
  n, port, i, fds0: INTEGER;
  got, total: LONGINT;
  ok: BOOLEAN;
  buf: ARRAY 4096 OF CHAR;
  text: ARRAY 64 OF CHAR;

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

PROCEDURE AppendInt(VAR s: ARRAY OF CHAR; n: LONGINT);
  VAR d: ARRAY 24 OF CHAR; i, j: INTEGER;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  j := 0; WHILE s[j] # 0X DO INC(j) END;
  WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END;
  s[j] := 0X
END AppendInt;

(* A listener on 127.0.0.1, port 0, as l, its port in port. *)
PROCEDURE Listener(nonBlocking: BOOLEAN): BOOLEAN;
BEGIN
  l := NIL; port := 0;
  IF ~Sockets.Listen("127.0.0.1", 0, 5, nonBlocking, ls, n, err) THEN
    RETURN FALSE
  END;
  l := ls[0];
  IF ~Sockets.LocalAddress(l, a, err) THEN RETURN FALSE END;
  port := a.port;
  RETURN (n = 1) & (port > 0)
END Listener;

(* A connection to l: c the connecting end, s the accepted one. *)
PROCEDURE Connection(): BOOLEAN;
BEGIN
  RETURN Sockets.Connect("127.0.0.1", port, c, err)
    & TestHelp.WaitReadable(l.fd, 5000)
    & Sockets.Accept(l, FALSE, s, peer, err)
END Connection;

BEGIN
  (* The resolver may keep descriptors after a lookup that asks a name
     server: NetBSD's keeps a kqueue (PLAN.md, Phase 9). Look one up
     now, so that they are counted in fds0. *)
  ok := Sockets.Resolve("nonexistent.invalid", 80, addrs, n, err);
  fds0 := TestHelp.OpenFds();

  (* Refused: a port listened on, then closed *)
  ok := Listener(FALSE);
  Check.Check(ok, "a listener on 127.0.0.1");
  Sockets.Close(l);
  ok := Sockets.Connect("127.0.0.1", port, c, err);
  text := "connect to 127.0.0.1 port "; AppendInt(text, port);
  Check.Check(~ok & (c = NIL) & (err.kind = Sockets.system)
    & (err.code = Sockets.ECONNREFUSED) & StartsWith(err.text, text),
    "Connect to a closed port is ECONNREFUSED, saying where");
  ok := Sockets.Resolve("127.0.0.1", port, addrs, n, err)
    & ~Sockets.ConnectTo(addrs[0], FALSE, c, err);
  Check.Check(ok & (c = NIL) & (err.code = Sockets.ECONNREFUSED)
    & StartsWith(err.text, text), "so is a blocking ConnectTo");
  IF Sockets.ConnectTo(addrs[0], TRUE, c, err) THEN
    Check.Check(FALSE, "a non-blocking ConnectTo to a closed port fails");
    Sockets.Close(c)
  ELSIF err.kind = Sockets.wouldBlock THEN
    Check.Check((c # NIL) & c.nonBlocking & (err.want = Sockets.wantWrite)
      & TestHelp.WaitWritable(c.fd, 5000) & ~Sockets.FinishConnect(c, err)
      & (err.code = Sockets.ECONNREFUSED),
      "a non-blocking ConnectTo to a closed port: FinishConnect gives ECONNREFUSED");
    Sockets.Close(c)
  ELSE
    Check.Check((c = NIL) & (err.code = Sockets.ECONNREFUSED),
      "a non-blocking ConnectTo to a closed port: ECONNREFUSED at once")
  END;

  (* A name that doesn't resolve *)
  ok := Sockets.Connect("nonexistent.invalid", 80, c, err);
  Check.Check(~ok & (c = NIL) & (err.kind = Sockets.name)
    & StartsWith(err.text, "connect to nonexistent.invalid port 80: "),
    "Connect to a name that doesn't resolve is a name error");

  (* A port in use *)
  ok := Listener(FALSE);
  ok := ok & ~Sockets.Listen("127.0.0.1", port, 5, FALSE, ls, n, err);
  text := "bind 127.0.0.1 port "; AppendInt(text, port);
  Check.Check(ok & (n = 0) & (err.kind = Sockets.system)
    & (err.code = Sockets.EADDRINUSE) & StartsWith(err.text, text),
    "Listen on a port in use is EADDRINUSE, saying where");

  (* A connection within this program, both ways *)
  ok := Connection();
  Check.Check(ok & (c.family = Sockets.inet) & (peer.port # port),
    "Connect to a listener here, and Accept it");
  buf := "ping";
  ok := Sockets.Write(c, buf, 0, 4, got, err) & (got = 4)
    & Sockets.Read(s, buf, 4, 4, got, err) & (got = 4)
    & (buf[4] = "p") & (buf[7] = "g");
  Check.Check(ok, "bytes written to one end are read at the other");

  (* Read on a non-blocking socket with nothing to read *)
  ok := Sockets.SetNonBlocking(c, TRUE, err) & c.nonBlocking;
  ok := ok & ~Sockets.Read(c, buf, 0, 1, got, err) & (got = 0)
    & (err.kind = Sockets.wouldBlock) & (err.want = Sockets.wantRead);
  Check.Check(ok, "Read with nothing to read: wouldBlock, wantRead");
  (* WriteAll on a non-blocking socket whose peer doesn't read *)
  total := 0;
  WHILE Sockets.WriteAll(c, buf, 0, LEN(buf), got, err) & (total < 100000000) DO
    total := total + got
  END;
  total := total + got;
  Check.Check((err.kind = Sockets.wouldBlock) & (err.want = Sockets.wantWrite)
    & (total > 0) & (got < LEN(buf)),
    "WriteAll stops at a full buffer with wouldBlock, wantWrite, and how far it got");
  ok := Sockets.SetNonBlocking(c, FALSE, err) & ~c.nonBlocking;
  Check.Check(ok, "SetNonBlocking back to blocking");

  (* The peer gone: a reset, then EPIPE, and never SIGPIPE *)
  Check.Check(TestHelp.ResetOnClose(s.fd), "SO_LINGER 0 on the accepted end");
  Sockets.Close(s);
  ok := Sockets.Read(c, buf, 0, LEN(buf), got, err);
  WHILE ok DO ok := Sockets.Read(c, buf, 0, LEN(buf), got, err) END;
  Check.Check((err.kind = Sockets.system) & (err.code = Sockets.ECONNRESET),
    "Read after the peer resets is ECONNRESET");
  i := 0;
  WHILE (i < 100) & Sockets.Write(c, buf, 0, 1, got, err) DO INC(i) END;
  Check.Check((err.kind = Sockets.system)
    & ((err.code = Sockets.EPIPE) OR (err.code = Sockets.ECONNRESET)),
    "Write to a reset connection is EPIPE or ECONNRESET, with no SIGPIPE");
  Sockets.Close(c);

  (* Accept on a non-blocking listener with nothing queued *)
  Sockets.Close(l);
  ok := Listener(TRUE) & ~Sockets.Accept(l, FALSE, s, peer, err)
    & (s = NIL) & (err.kind = Sockets.wouldBlock) & (err.want = Sockets.wantRead);
  Check.Check(ok, "Accept with nothing queued: wouldBlock, wantRead");
  (* A non-blocking ConnectTo, finished *)
  ok := Sockets.Resolve("127.0.0.1", port, addrs, n, err);
  IF Sockets.ConnectTo(addrs[0], TRUE, c, err) THEN
    ok := ok & c.nonBlocking
  ELSE
    ok := ok & (err.kind = Sockets.wouldBlock) & (err.want = Sockets.wantWrite)
      & (c # NIL) & TestHelp.WaitWritable(c.fd, 5000)
      & Sockets.FinishConnect(c, err)
  END;
  Check.Check(ok, "a non-blocking ConnectTo connects");
  ok := TestHelp.WaitReadable(l.fd, 5000) & Sockets.Accept(l, TRUE, s, peer, err)
    & s.nonBlocking & Sockets.PeerAddress(s, a, err) & Sockets.LocalAddress(c, peer, err)
    & (a.port = peer.port);
  Check.Check(ok, "Accept from a non-blocking listener, non-blocking");
  Sockets.Close(s); Sockets.Close(c);

  (* Adopt *)
  ok := Sockets.Adopt(TestHelp.Dup(l.fd), t, err);
  Check.Check(ok & (t.family = Sockets.inet) & t.listening & t.nonBlocking,
    "Adopt of a listener's duplicate: inet, listening, non-blocking");
  Sockets.Close(t);
  Sockets.Close(l);
  ok := Sockets.Pair(s, c, err) & Sockets.Adopt(TestHelp.Dup(s.fd), t, err);
  Check.Check(ok & (t.family = Sockets.unix) & ~t.listening & ~t.nonBlocking,
    "Adopt of a pair's end: unix, not listening, blocking");
  Sockets.Close(t); Sockets.Close(s); Sockets.Close(c);
  got := TestHelp.OpenNull();
  ok := (got >= 0) & ~Sockets.Adopt(got, t, err);
  Check.Check(ok & (t = NIL) & (err.kind = Sockets.system) & (err.code # 0)
    & StartsWith(err.text, "adopt: "),
    "Adopt of /dev/null, not a socket, is an error");
  IF got >= 0 THEN TestHelp.Close(got) END;

  (* Too many open files: in a child, which valgrind doesn't follow and
     whose lowered RLIMIT_NOFILE it can't ignore (TooManyFiles.Mod). *)
  Check.Check(Platform.System("../build/TooManyFiles") = 0,
    "with no descriptor free, Accept reports EMFILE and the connection stays queued");

  (* IgnoreBrokenPipe: a plain write (not posockets', so no
     MSG_NOSIGNAL) to a closed peer then fails instead of killing the
     program. Last, since it lasts for the rest of the program. *)
  Sockets.IgnoreBrokenPipe;
  ok := Sockets.Pair(s, c, err);
  Sockets.Close(c);
  Check.Check(ok & (Platform.Write(s.fd, SYSTEM.ADR(buf[0]), 1) # 0),
    "after IgnoreBrokenPipe, a plain write to a closed peer fails, without SIGPIPE");
  Sockets.Close(s);

  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again");
  Check.Summary
END TestErrors.
