MODULE TestBlocking; (* Blocking TCP with a peer in another process *)

(* PLAN.md, "Testing": a blocking listener, and BlockingPeer started in
   the background as a separate process (a blocking call stops every
   task, so the peer can't be a task here). Platform.System waits for its
   command, so the command ends in "&" and the shell returns at once.

   The exchange: the peer connects and sends "hello\n"; this side accepts
   it, reads that, writes Big bytes of a pattern with WriteAll (far more
   than the socket buffers hold, so the writes are short and wait for the
   peer to read), and shuts down its writing; the peer reads to end of
   stream, checks the pattern and replies "ok <count>\n"; this side reads
   that to end of stream. Over IPv4, and IPv6 when ::1 can be bound.

   Accept is called only once TestHelp.WaitReadable has seen a
   connection queued, so a peer that never connects fails a check
   instead of hanging the test. *)

IMPORT Platform, Sockets, Check, TestHelp;

CONST Big = 1000000;

VAR
  big: ARRAY Big OF CHAR;
  fds0, i: INTEGER;
  prefix: ARRAY 32 OF CHAR;   (* the host, before each of Exchange's labels *)

PROCEDURE AppendInt(VAR s: ARRAY OF CHAR; n: LONGINT);
  VAR d: ARRAY 24 OF CHAR; i, j: INTEGER;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  j := 0; WHILE s[j] # 0X DO INC(j) END;
  WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END;
  s[j] := 0X
END AppendInt;

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: INTEGER;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  j := 0; WHILE t[j] # 0X DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

PROCEDURE C(ok: BOOLEAN; label: ARRAY OF CHAR);
  VAR t: ARRAY 128 OF CHAR;
BEGIN
  t := ""; Append(t, prefix); Append(t, label); Check.Check(ok, t)
END C;

(* Reads from s into buf until end of stream, or until buf is full;
   n is what was read. TRUE if it ended at end of stream. *)
PROCEDURE ReadToEnd(s: Sockets.Socket; VAR buf: ARRAY OF CHAR;
    VAR n: LONGINT): BOOLEAN;
  VAR k: LONGINT; err: Sockets.Error;
BEGIN
  n := 0;
  WHILE (n < LEN(buf)) & Sockets.Read(s, buf, n, LEN(buf) - n, k, err) DO
    n := n + k
  END;
  RETURN (n < LEN(buf)) & (err.kind = Sockets.closed) & (k = 0)
END ReadToEnd;

PROCEDURE Exchange(host: ARRAY OF CHAR; family: INTEGER);
  VAR
    ls: ARRAY 2 OF Sockets.Socket;
    l, s: Sockets.Socket;
    a, peer: Sockets.Address;
    err: Sockets.Error;
    n: INTEGER;
    got, k: LONGINT;
    cmd: ARRAY 128 OF CHAR;
    buf: ARRAY 64 OF CHAR;
    ok: BOOLEAN;
BEGIN
  prefix := "["; Append(prefix, host); Append(prefix, "] ");
  ok := Sockets.Listen(host, 0, 5, FALSE, ls, n, err)
    & (n = 1) & Sockets.LocalAddress(ls[0], a, err);
  C(ok, "a blocking listener on port 0");
  IF ~ok THEN RETURN END;
  l := ls[0];
  cmd := "../build/BlockingPeer "; Append(cmd, host); Append(cmd, " ");
  AppendInt(cmd, a.port); Append(cmd, " &");
  C(Platform.System(cmd) = 0, "the peer is started");
  ok := TestHelp.WaitReadable(l.fd, 10000);
  C(ok, "the peer connects within 10 s");
  IF ~ok THEN Sockets.Close(l); RETURN END;

  ok := Sockets.Accept(l, FALSE, s, peer, err);
  C(ok & (s.family = family) & ~s.listening & ~s.nonBlocking,
    "Accept gives a blocking connection of the listener's family");
  C((peer.family = family) & (peer.host = host) & (peer.port > 0)
    & (peer.port # a.port), "Accept gives the peer's address");
  ok := Sockets.PeerAddress(s, a, err);
  C(ok & (a.host = peer.host) & (a.port = peer.port),
    "PeerAddress agrees with Accept");

  (* "hello\n", in two reads: a read gives at most len bytes *)
  ok := Sockets.Read(s, buf, 0, 2, got, err);
  C(ok & (got = 2) & (err.kind = Sockets.none), "a read of 2 gives 2");
  ok := Sockets.Read(s, buf, 2, 0, got, err);
  C(ok & (got = 0) & (err.kind = Sockets.none),
    "a read of 0 bytes returns at once, not closed");
  k := 2;
  WHILE (k < 6) & Sockets.Read(s, buf, k, 6 - k, got, err) DO k := k + got END;
  C((k = 6) & (buf[5] = 0AX), "the peer's whole hello arrives");
  buf[5] := 0X;
  C(buf = "hello", "and it is hello and a newline");

  ok := Sockets.WriteAll(s, big, 0, Big, got, err);
  C(ok & (got = Big), "WriteAll writes 1000000 bytes, far more than the buffers hold");
  C(Sockets.Shutdown(s, Sockets.shutWrite, err),
    "Shutdown of the writing side");
  ok := ReadToEnd(s, buf, got);
  C(ok & (got = 11) & (buf[10] = 0AX), "the peer's reply is a line");
  buf[10] := 0X;
  C(buf = "ok 1000000",
    "the peer read every byte, in order, to end of stream");
  ok := Sockets.Read(s, buf, 0, 1, got, err);
  C(~ok & (got = 0) & (err.kind = Sockets.closed),
    "after end of stream, Read gives closed again");
  Sockets.Close(s); Sockets.Close(l)
END Exchange;

PROCEDURE HaveIPv6(): BOOLEAN;
  VAR ls: ARRAY 1 OF Sockets.Socket; n: INTEGER; err: Sockets.Error;
BEGIN
  IF Sockets.Listen("::1", 0, 1, FALSE, ls, n, err) THEN
    Sockets.Close(ls[0]); RETURN TRUE
  END;
  RETURN FALSE
END HaveIPv6;

BEGIN
  FOR i := 0 TO Big - 1 DO big[i] := CHR(i MOD 251) END;
  fds0 := TestHelp.OpenFds();
  Exchange("127.0.0.1", Sockets.inet);
  IF HaveIPv6() THEN Exchange("::1", Sockets.inet6)
  ELSE Check.Check(TRUE, "IPv6 skipped: ::1 can't be bound")
  END;
  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again");
  Check.Summary
END TestBlocking.
