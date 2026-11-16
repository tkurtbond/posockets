MODULE TestTasks; (* SocketTasks: many connections in one program *)

(* PLAN.md, "Testing": a listener, an accept task and client tasks in
   one program; many connections at once, each echoing more than a
   socket buffer holds, with a reader task and a writer task on each
   client's socket; Connect falling back from ::1 to 127.0.0.1; a
   refused ConnectTo and a name that doesn't resolve; waiters counting
   a wait; Shutdown from one task waking another's Read. A watchdog
   task ends the program if anything waits too long. *)

IMPORT Platform, Out, Coroutines, Tasks, Sockets, SocketTasks, Check, TestHelp;

CONST
  Clients = 20;
  Size = 300000;           (* bytes each client sends: several buffers *)
  Stack = Coroutines.DefaultStackSize;
  Patience = 60000;        (* ms the watchdog allows the whole test *)
  Buffers = 4096;          (* each connection's socket buffers, asked for:
                              the loopback's own are so large that no
                              send would ever wait (PLAN.md, "Testing") *)

TYPE
  Echo = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket
  END;
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket
  END;
  Client = POINTER TO RECORD (Tasks.TaskDesc)
    host: ARRAY 16 OF CHAR;
    port: INTEGER;
    ok: BOOLEAN;
    why: ARRAY 256 OF CHAR
  END;
  Writer = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    ok: BOOLEAN
  END;
  Reader = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    n: LONGINT;
    err: Sockets.Error
  END;
  Watchdog = POINTER TO RECORD (Tasks.TaskDesc) END;

VAR
  echoes, echoFailures, fds0, i, j, n: INTEGER;
  addrs: ARRAY 4 OF Sockets.Address;
  label: ARRAY 64 OF CHAR;
  ls: ARRAY 2 OF Sockets.Socket;
  l, s, c: Sockets.Socket;
  clients: ARRAY Clients OF Client;
  acceptor: Acceptor;
  reader: Reader;
  watchdog: Watchdog;
  a: Sockets.Address;
  err: Sockets.Error;
  port: INTEGER;
  ok: BOOLEAN;
  got: LONGINT;
  buf: ARRAY 8 OF CHAR;

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

(* Accepts Clients connections, an Echo task each, and waits for them. *)
PROCEDURE (t: Acceptor) Run*;
  VAR es: ARRAY Clients OF Echo; i: INTEGER; peer: Sockets.Address;
    err: Sockets.Error;
BEGIN
  i := 0;
  WHILE i < Clients DO
    NEW(es[i]);
    IF SocketTasks.Accept(t.l, es[i].s, peer, err) THEN
      IF ~TestHelp.SmallBuffers(es[i].s.fd, Buffers) THEN INC(echoFailures) END;
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

(* Connects, writes from a Writer task while reading the echo here, and
   checks that it is the pattern, all of it. *)
PROCEDURE (t: Client) Run*;
  VAR s: Sockets.Socket; w: Writer; err: Sockets.Error;
    buf: ARRAY 5000 OF CHAR; n, got, i: LONGINT;
BEGIN
  t.ok := FALSE;
  IF ~SocketTasks.Connect(t.host, t.port, s, err) THEN
    COPY(err.text, t.why); RETURN
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

(* Reads once into its own buffer. *)
PROCEDURE (r: Reader) Run*;
  VAR buf: ARRAY 16 OF CHAR;
BEGIN
  IF ~SocketTasks.Read(r.s, buf, 0, LEN(buf), r.n, r.err) THEN r.n := -1 END
END Run;

BEGIN
  NEW(watchdog); Tasks.Start(watchdog, Stack);
  (* Tasks makes a self-pipe the first time it waits idle and keeps it
     until the program ends; WakeDescriptor makes it now, so it is
     counted in fds0. *)
  IF Tasks.WakeDescriptor() < 0 THEN Check.Check(FALSE, "Tasks has its self-pipe") END;
  fds0 := TestHelp.OpenFds();

  (* Many connections at once. Odd clients connect to localhost, which
     resolves to ::1 first, where nothing listens on this port, so they
     fall back to 127.0.0.1. *)
  ok := Sockets.Listen("127.0.0.1", 0, Clients, TRUE, ls, n, err)
    & Sockets.LocalAddress(ls[0], a, err);
  Check.Check(ok, "a non-blocking listener on 127.0.0.1");
  l := ls[0]; port := a.port;
  NEW(acceptor); acceptor.l := l; Tasks.Start(acceptor, Stack);
  FOR i := 0 TO Clients - 1 DO
    NEW(clients[i]); clients[i].port := port; clients[i].why := "";
    IF ODD(i) THEN clients[i].host := "localhost" ELSE clients[i].host := "127.0.0.1" END;
    Tasks.Start(clients[i], Stack)
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
  Check.Check(ok, "20 clients at once each get back the 300000 bytes they sent");
  Check.Check((echoes = Clients) & (echoFailures = 0),
    "20 connections accepted and echoed, with no error");

  (* A wait is counted in waiters; a peer's write ends it. *)
  ok := SocketTasks.ConnectTo(a, c, err) & SocketTasks.Accept(l, s, a, err);
  Check.Check(ok & c.nonBlocking & s.nonBlocking,
    "ConnectTo and Accept give non-blocking sockets");
  NEW(reader); reader.s := s; Tasks.Start(reader, Stack);
  Tasks.Yield;
  Check.Check(~Tasks.Done(reader) & (s.waiters = 1), "a waiting Read is counted in waiters");
  buf := "ping";
  ok := SocketTasks.Write(c, buf, 0, 4, got, err);
  Tasks.Join(reader);
  Check.Check(ok & (reader.n = 4) & (s.waiters = 0),
    "a write from the peer wakes it, and it is no longer counted");

  (* Shutdown from another task wakes a waiting Read with end of stream. *)
  NEW(reader); reader.s := s; Tasks.Start(reader, Stack);
  Tasks.Yield;
  Check.Check(~Tasks.Done(reader), "a second Read waits");
  ok := Sockets.Shutdown(s, Sockets.shutBoth, err);
  Tasks.Join(reader);
  Check.Check(ok & (reader.n = -1) & (reader.err.kind = Sockets.closed),
    "Shutdown from another task wakes it with closed");
  Sockets.Close(s); Sockets.Close(c);

  (* Connecting where nothing listens, and to a name that doesn't
     resolve: errors, saying where. The port was this test's listener's
     until now, so another program taking it at once is unlikely. *)
  Sockets.Close(l);
  ok := Sockets.Resolve("127.0.0.1", port, addrs, n, err);
  ok := ok & ~SocketTasks.ConnectTo(addrs[0], c, err);
  Check.Check(ok & (c = NIL) & (err.kind = Sockets.system)
    & (err.code = Sockets.ECONNREFUSED), "ConnectTo where nothing listens is ECONNREFUSED");
  label := "connect to 127.0.0.1 port "; i := 0;
  WHILE label[i] # 0X DO INC(i) END;
  n := port; j := 10000; WHILE j > n DO j := j DIV 10 END;
  WHILE j > 0 DO label[i] := CHR(ORD("0") + n DIV j MOD 10); INC(i); j := j DIV 10 END;
  label[i] := ":"; label[i + 1] := 0X;
  Check.Check(StartsWith(err.text, label), "its text says where it was connecting");
  ok := SocketTasks.Connect("nonexistent.invalid", 1, c, err);
  Check.Check(~ok & (c = NIL) & (err.kind = Sockets.name)
    & StartsWith(err.text, "resolve nonexistent.invalid port 1: "),
    "Connect to a name that doesn't resolve is a name error");

  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again");
  Check.Summary
END TestTasks.
