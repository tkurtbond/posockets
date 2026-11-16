MODULE TestUnix; (* Unix-domain sockets: Pair, ListenUnix, ConnectUnix *)

(* PLAN.md, "Testing": a socketpair's addresses; a listener at a path,
   a blocking connection to it and its addresses; binding over an
   existing file, a stale socket file, no file; many clients at once
   through SocketTasks, each echoing more than a socket buffer holds;
   a full listen queue (backlog 0), where a non-blocking connect gives
   EAGAIN and SocketTasks.ConnectUnix retries until there is room or its
   limit passes; Adopt of a Unix listener; the longest path Linux takes.
   Every socket file is under ../build and removed again. A watchdog
   task ends the program if anything waits too long. *)

IMPORT Platform, Out, Coroutines, Tasks, Sockets, SocketTasks, Check, TestHelp;

CONST
  Clients = 10;
  Size = 200000;           (* bytes each client sends: several buffers *)
  Stack = Coroutines.DefaultStackSize;
  Patience = 60000;        (* ms the watchdog allows the whole test *)
  Buffers = 4096;          (* each connection's socket buffers, asked for *)
  Limit = 200;             (* ms a connect to a full queue may take *)

TYPE
  Echo = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket
  END;
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket
  END;
  Client = POINTER TO RECORD (Tasks.TaskDesc)
    ok: BOOLEAN;
    why: ARRAY 256 OF CHAR
  END;
  Writer = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    ok: BOOLEAN
  END;
  LateAccept = POINTER TO RECORD (Tasks.TaskDesc)
    l, s: Sockets.Socket;
    ok: BOOLEAN
  END;
  Watchdog = POINTER TO RECORD (Tasks.TaskDesc) END;

VAR
  path, queuePath, longPath: ARRAY 128 OF CHAR;
  echoes, echoFailures, fds0, i: INTEGER;
  clients: ARRAY Clients OF Client;
  acceptor: Acceptor;
  late: LateAccept;
  watchdog: Watchdog;
  a, b, l, s, c, c2, q: Sockets.Socket;
  addr, peer: Sockets.Address;
  err: Sockets.Error;
  ok: BOOLEAN;
  n, t0, t: LONGINT;
  buf: ARRAY 16 OF CHAR;
  label: ARRAY 256 OF CHAR;

PROCEDURE Equal(s, t: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN s = t
END Equal;

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

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  j := 0;
  WHILE (j < LEN(t)) & (t[j] # 0X) & (i < LEN(s) - 1) DO
    s[i] := t[j]; INC(i); INC(j)
  END;
  s[i] := 0X
END Append;

(* Removes the file at p, if there is one. *)
PROCEDURE Remove(p: ARRAY OF CHAR);
  VAR e: Platform.ErrorCode;
BEGIN
  e := Platform.Unlink(p)
END Remove;

PROCEDURE (w: Watchdog) Run*;
BEGIN
  Tasks.Sleep(Patience);
  Out.String("FAIL - the test took longer than "); Out.Int(Patience DIV 1000, 0);
  Out.String(" s"); Out.Ln;
  Platform.Exit(1)
END Run;

(* Sends back what it reads until end of stream, then closes. *)
PROCEDURE (e: Echo) Run*;
  VAR buf: ARRAY 4096 OF CHAR; n, k: LONGINT; err: Sockets.Error;
BEGIN
  WHILE SocketTasks.Read(e.s, buf, 0, LEN(buf), n, err) DO
    IF ~SocketTasks.WriteAll(e.s, buf, 0, n, k, err) THEN INC(echoFailures) END
  END;
  IF err.kind # Sockets.closed THEN INC(echoFailures) END;
  Sockets.Close(e.s)
END Run;

(* Accepts Clients connections, an Echo task each, and waits for them.
   Each peer is unnamed: family unix, an empty host. *)
PROCEDURE (t: Acceptor) Run*;
  VAR es: ARRAY Clients OF Echo; i: INTEGER; peer: Sockets.Address;
    err: Sockets.Error;
BEGIN
  i := 0;
  WHILE i < Clients DO
    NEW(es[i]);
    IF SocketTasks.Accept(t.l, es[i].s, peer, err) THEN
      IF (peer.family # Sockets.unix) OR (peer.host # "")
        OR (es[i].s.family # Sockets.unix)
        OR ~TestHelp.SmallBuffers(es[i].s.fd, Buffers) THEN
        INC(echoFailures)
      END;
      Tasks.Start(es[i], Stack); INC(echoes); INC(i)
    ELSE
      INC(echoFailures); Tasks.Sleep(10)
    END
  END;
  FOR i := 0 TO Clients - 1 DO Tasks.Join(es[i]) END
END Run;

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

(* Connects to path, writes from a Writer task while reading the echo
   here, and checks that it is the pattern, all of it. *)
PROCEDURE (t: Client) Run*;
  VAR s: Sockets.Socket; w: Writer; err: Sockets.Error;
    buf: ARRAY 5000 OF CHAR; n, got, i: LONGINT;
BEGIN
  t.ok := FALSE;
  IF ~SocketTasks.ConnectUnix(path, 0, s, err) THEN
    COPY(err.text, t.why); RETURN
  END;
  IF ~s.nonBlocking OR (s.family # Sockets.unix) THEN
    t.why := "not a non-blocking Unix-domain socket"; Sockets.Close(s); RETURN
  END;
  IF ~TestHelp.SmallBuffers(s.fd, Buffers) THEN
    t.why := "SO_SNDBUF"; Sockets.Close(s); RETURN
  END;
  NEW(w); w.s := s; Tasks.Start(w, Stack);
  got := 0; t.ok := TRUE;
  WHILE t.ok & SocketTasks.Read(s, buf, 0, LEN(buf), n, err) DO
    FOR i := 0 TO n - 1 DO
      t.ok := t.ok & (buf[i] = CHR((got + i) MOD 251))
    END;
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

(* After 50 ms, accepts one queued connection, making room in the queue. *)
PROCEDURE (t: LateAccept) Run*;
  VAR peer: Sockets.Address; err: Sockets.Error;
BEGIN
  Tasks.Sleep(50);
  t.ok := Sockets.Accept(t.l, FALSE, t.s, peer, err)
END Run;

BEGIN
  NEW(watchdog); Tasks.Start(watchdog, Stack);
  (* Tasks' self-pipe, made now so that it is counted in fds0. *)
  IF Tasks.WakeDescriptor() < 0 THEN Check.Check(FALSE, "Tasks has its self-pipe") END;
  fds0 := TestHelp.OpenFds();
  path := "../build/TestUnix.sock"; queuePath := "../build/TestUnixQueue.sock";
  Remove(path); Remove(queuePath);

  (* A socketpair: both ends unix, both unnamed. *)
  ok := Sockets.Pair(a, b, err);
  Check.Check(ok & (a.family = Sockets.unix) & (b.family = Sockets.unix),
    "Pair gives two Unix-domain sockets");
  ok := ok & Sockets.LocalAddress(a, addr, err) & Sockets.PeerAddress(b, peer, err);
  Check.Check(ok & (addr.family = Sockets.unix) & (addr.host = "") & (addr.port = 0)
    & (peer.family = Sockets.unix) & (peer.host = ""),
    "a pair's addresses are unix and unnamed");
  buf := "ping";
  ok := Sockets.WriteAll(a, buf, 0, 4, n, err) & Sockets.Read(b, buf, 0, LEN(buf), n, err);
  Check.Check(ok & (n = 4) & (buf[0] = "p") & (buf[3] = "g"), "a pair carries data");
  Sockets.Close(a); Sockets.Close(b);

  (* A blocking listener and a blocking connection. *)
  ok := Sockets.ListenUnix(path, 4, FALSE, l, err);
  Check.Check(ok & l.listening & ~l.nonBlocking & (l.family = Sockets.unix),
    "ListenUnix gives a blocking Unix-domain listener");
  ok := ok & Sockets.LocalAddress(l, addr, err);
  Check.Check(ok & (addr.family = Sockets.unix) & Equal(addr.host, path) & (addr.port = 0),
    "its address is its path");
  ok := Sockets.ConnectUnix(path, FALSE, c, err);
  Check.Check(ok & ~c.nonBlocking & (c.family = Sockets.unix),
    "a blocking ConnectUnix completes before any Accept");
  ok := ok & Sockets.Accept(l, FALSE, s, peer, err);
  Check.Check(ok & (s.family = Sockets.unix) & (peer.family = Sockets.unix)
    & (peer.host = ""), "Accept gives the connection, its peer unnamed");
  ok := ok & Sockets.PeerAddress(c, addr, err);
  Check.Check(ok & Equal(addr.host, path), "the connecting side's peer is the path");
  buf := "hello";
  ok := Sockets.WriteAll(c, buf, 0, 5, n, err) & Sockets.Read(s, buf, 0, LEN(buf), n, err);
  Check.Check(ok & (n = 5) & (buf[0] = "h"), "the connection carries data");
  Sockets.Close(s); Sockets.Close(c);

  (* Adopt of a Unix listener's duplicate. *)
  ok := Sockets.Adopt(TestHelp.Dup(l.fd), a, err);
  Check.Check(ok & (a.family = Sockets.unix) & a.listening,
    "Adopt sees a Unix-domain listener");
  Sockets.Close(a);

  (* The file stays: binding over it, connecting to it once stale, and
     once removed. *)
  ok := ~Sockets.ListenUnix(path, 4, FALSE, a, err);
  label := "bind "; Append(label, path); Append(label, ": ");
  Check.Check(ok & (a = NIL) & (err.kind = Sockets.system)
    & (err.code = Sockets.EADDRINUSE) & StartsWith(err.text, label),
    "ListenUnix over an existing file is EADDRINUSE, saying where");
  Sockets.Close(l);
  ok := ~Sockets.ConnectUnix(path, FALSE, c, err);
  label := "connect to "; Append(label, path); Append(label, ": ");
  Check.Check(ok & (c = NIL) & (err.kind = Sockets.system)
    & (err.code = Sockets.ECONNREFUSED) & StartsWith(err.text, label),
    "ConnectUnix to a stale socket file is ECONNREFUSED, saying where");
  ok := ~SocketTasks.ConnectUnix(path, 1000, c, err);
  Check.Check(ok & (c = NIL) & (err.code = Sockets.ECONNREFUSED),
    "SocketTasks.ConnectUnix gives ECONNREFUSED at once");
  Remove(path);
  ok := ~Sockets.ConnectUnix(path, TRUE, c, err);
  Check.Check(ok & (c = NIL) & (err.kind = Sockets.system) & (err.code = Sockets.ENOENT),
    "ConnectUnix where there is no file is ENOENT");

  (* Many connections at once, through SocketTasks. *)
  ok := Sockets.ListenUnix(path, Clients, TRUE, l, err);
  Check.Check(ok & l.nonBlocking, "a non-blocking Unix-domain listener");
  NEW(acceptor); acceptor.l := l; Tasks.Start(acceptor, Stack);
  FOR i := 0 TO Clients - 1 DO
    NEW(clients[i]); clients[i].why := ""; Tasks.Start(clients[i], Stack)
  END;
  ok := TRUE;
  FOR i := 0 TO Clients - 1 DO
    Tasks.Join(clients[i]);
    IF ~clients[i].ok THEN
      ok := FALSE; Out.String("# client "); Out.Int(i, 0); Out.String(": ");
      Out.String(clients[i].why); Out.Ln
    END
  END;
  Tasks.Join(acceptor);
  Check.Check(ok, "10 clients at once each get back the 200000 bytes they sent");
  Check.Check((echoes = Clients) & (echoFailures = 0),
    "10 connections accepted and echoed, with no error");
  Sockets.Close(l); Remove(path);

  (* A full queue: backlog 0 queues one connection, and no more. *)
  ok := Sockets.ListenUnix(queuePath, 0, FALSE, q, err)
    & Sockets.ConnectUnix(queuePath, TRUE, c, err);
  Check.Check(ok, "backlog 0 queues one connection");
  ok := ~Sockets.ConnectUnix(queuePath, TRUE, c2, err);
  Check.Check(ok & (c2 = NIL) & (err.kind = Sockets.system) & (err.code = Sockets.EAGAIN),
    "a non-blocking ConnectUnix to a full queue is EAGAIN, with no socket");
  t0 := Sockets.Now();
  ok := ~SocketTasks.ConnectUnix(queuePath, Limit, c2, err);
  t := Sockets.Now() - t0;
  label := "connect to "; Append(label, queuePath); Append(label, ": timed out");
  Check.Check(ok & (c2 = NIL) & (err.kind = Sockets.timedOut) & Equal(err.text, label),
    "SocketTasks.ConnectUnix to a full queue times out, saying where");
  Check.Check((t >= Limit) & (t < Limit + 100), "after its limit");
  IF ~((t >= Limit) & (t < Limit + 100)) THEN
    Out.String("# took "); Out.Int(t, 0); Out.String(" ms"); Out.Ln
  END;
  NEW(late); late.l := q; Tasks.Start(late, Stack);
  t0 := Sockets.Now();
  ok := SocketTasks.ConnectUnix(queuePath, 5000, c2, err);
  t := Sockets.Now() - t0;
  Tasks.Join(late);
  Check.Check(ok & late.ok & (t >= 40) & (t < 1000),
    "it connects once another task's Accept makes room");
  Sockets.Close(c2); Sockets.Close(late.s); Sockets.Close(c); Sockets.Close(q);
  Remove(queuePath);

  (* The longest path sun_path holds on Linux, 107 bytes. *)
  longPath := "../build/";
  i := 9; WHILE i < 107 DO longPath[i] := "x"; INC(i) END; longPath[107] := 0X;
  Remove(longPath);
  ok := Sockets.ListenUnix(longPath, 1, FALSE, l, err) & Sockets.LocalAddress(l, addr, err);
  Check.Check(ok & Equal(addr.host, longPath), "a path of 107 bytes binds");
  Sockets.Close(l); Remove(longPath);

  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again");
  Check.Summary
END TestUnix.
