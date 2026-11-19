MODULE TestResolve; (* names looked up while other tasks run *)

(* PLAN.md, Phase 11: Sockets.StartResolve, FinishResolve and
   AbandonResolve, a name looked up in a thread of the C part, and
   SocketTasks.Resolve and Sockets.ResolveWithin waiting for it with a
   time limit, which SocketTasks.Connect and Sockets.ConnectWithin now
   count in theirs. A numeric or empty host is done at once, with no
   thread. A ticker task shows that other tasks run while a lookup
   waits. The only name is localhost, from /etc/hosts, and
   nonexistent.invalid, which no name server knows; a lookup slow enough
   to time out comes from TestHelp.SetResolveDelay. Every abandoned
   lookup's thread is waited for, so descriptors are back to their count
   and nothing is left unfreed at exit. *)

IMPORT Sockets, SocketTasks, Tasks, GarbageCollectedHeap, Check, TestHelp;

CONST
  Stack = 65536;
  Slack = 500;             (* ms a timed wait may run late on a busy machine *)
  Delay = 300;             (* ms a slow lookup waits before getaddrinfo *)

TYPE
  Ticker = POINTER TO TickerDesc;
  TickerDesc = RECORD (Tasks.TaskDesc) END;

VAR
  ticker: Ticker;
  ticks: LONGINT;
  stop: BOOLEAN;
  r: Sockets.Resolution;
  addrs: ARRAY 16 OF Sockets.Address;
  ls: ARRAY 2 OF Sockets.Socket;
  c: Sockets.Socket;
  err: Sockets.Error;
  n, nl, i, fds0, port: INTEGER;
  t0, el, ticks0: LONGINT;
  ok: BOOLEAN;

PROCEDURE (t: Ticker) Run*;
BEGIN
  WHILE ~stop DO INC(ticks); Tasks.Sleep(5) END
END Run;

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

(* Whether el, a wait's length, is ms give or take *)
PROCEDURE Near(el, ms: LONGINT): BOOLEAN;
BEGIN
  RETURN (el >= ms - 5) & (el <= ms + Slack)
END Near;

(* Whether addrs[0..n-1] are all loopback addresses, with port *)
PROCEDURE Loopback(n, port: INTEGER): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  IF n < 1 THEN RETURN FALSE END;
  FOR i := 0 TO n - 1 DO
    IF ~((addrs[i].host = "127.0.0.1") OR (addrs[i].host = "::1"))
      OR (addrs[i].port # port) THEN RETURN FALSE
    END
  END;
  RETURN TRUE
END Loopback;

(* Waits long enough for every slow lookup's thread to be done *)
PROCEDURE Settle;
BEGIN
  Tasks.Sleep(Delay + 200)
END Settle;

BEGIN
  NEW(ticker); Tasks.Start(ticker, Stack);
  (* NetBSD's resolver keeps a kqueue from its first lookup that asks a
     name server (PLAN.md, Portability). *)
  ok := SocketTasks.Resolve("nonexistent.invalid", 80, 10000, addrs, n, err);
  fds0 := TestHelp.OpenFds();

  (* Numeric and empty hosts: done at once, no thread, no descriptor *)
  ok := Sockets.StartResolve("127.0.0.1", 80, r, err);
  Check.Check(ok & (r.fd = -1), "StartResolve 127.0.0.1: done at once (fd -1)");
  ok := Sockets.FinishResolve(r, addrs, n, err);
  Check.Check(ok & (n = 1) & (addrs[0].host = "127.0.0.1")
    & (addrs[0].port = 80) & (addrs[0].family = Sockets.inet),
    "FinishResolve 127.0.0.1: 127.0.0.1 port 80, inet");
  ok := Sockets.StartResolve("::1", 7, r, err)
    & (r.fd = -1) & Sockets.FinishResolve(r, addrs, n, err);
  Check.Check(ok & (n = 1) & (addrs[0].host = "::1")
    & (addrs[0].family = Sockets.inet6), "::1: done at once, inet6");
  ok := Sockets.StartResolve("", 7, r, err)
    & (r.fd = -1) & Sockets.FinishResolve(r, addrs, n, err);
  Check.Check(ok & Loopback(n, 7), "the empty host: done at once, the loopback addresses");
  Check.Check(TestHelp.OpenFds() = fds0, "no descriptor left by numeric lookups");

  (* A name: a thread, and a descriptor to wait on *)
  ok := Sockets.StartResolve("localhost", 80, r, err);
  Check.Check(ok & (r.fd >= 0), "StartResolve localhost: a descriptor to wait on");
  Tasks.AwaitReadable(r.fd);
  ok := Sockets.FinishResolve(r, addrs, n, err);
  Check.Check(ok & Loopback(n, 80), "FinishResolve localhost: loopback addresses, port 80");
  Check.Check(r.fd = -1, "r.fd is -1 once finished");

  ok := SocketTasks.Resolve("localhost", 80, 2000, addrs, n, err);
  Check.Check(ok & Loopback(n, 80), "SocketTasks.Resolve localhost");
  ok := Sockets.ResolveWithin("localhost", 80, 2000, addrs, n, err);
  Check.Check(ok & Loopback(n, 80), "Sockets.ResolveWithin localhost");
  ok := Sockets.ResolveWithin("localhost", 80, 0, addrs, n, err);
  Check.Check(ok & Loopback(n, 80), "Sockets.ResolveWithin localhost, no limit");

  ok := SocketTasks.Resolve("nonexistent.invalid", 80, 10000, addrs, n, err);
  Check.Check(~ok & (err.kind = Sockets.name) & (n = 0)
    & StartsWith(err.text, "resolve nonexistent.invalid port 80: "),
    "nonexistent.invalid: a name error, resolve nonexistent.invalid port 80");
  Check.Check(TestHelp.OpenFds() = fds0, "descriptors back to their count");

  (* Slow lookups *)
  TestHelp.SetResolveDelay(Delay);
  ticks0 := ticks; t0 := Sockets.Now();
  ok := SocketTasks.Resolve("localhost", 80, 0, addrs, n, err);
  el := Sockets.Now() - t0;
  Check.Check(ok & Loopback(n, 80) & Near(el, Delay),
    "a slow lookup, no limit: the addresses, after the delay");
  Check.Check(ticks - ticks0 >= 10, "another task ran while it waited");

  ok := Sockets.StartResolve("localhost", 80, r, err);
  ok := ~Sockets.FinishResolve(r, addrs, n, err);
  Check.Check(ok & (err.kind = Sockets.wouldBlock) & (err.want = Sockets.wantRead) & (r.fd >= 0),
    "FinishResolve before it is done: wouldBlock, wantRead, r kept");
  Sockets.AbandonResolve(r);
  Check.Check(r.fd = -1, "AbandonResolve: r.fd is -1 at once");
  Sockets.AbandonResolve(r);
  Check.Check(r.fd = -1, "AbandonResolve again does nothing");

  t0 := Sockets.Now();
  ok := SocketTasks.Resolve("localhost", 80, 100, addrs, n, err);
  el := Sockets.Now() - t0;
  Check.Check(~ok & (err.kind = Sockets.timedOut) & (n = 0)
    & (err.text = "resolve localhost port 80: timed out") & Near(el, 100),
    "SocketTasks.Resolve past its limit: timed out near 100 ms");
  t0 := Sockets.Now();
  ok := Sockets.ResolveWithin("localhost", 80, 100, addrs, n, err);
  el := Sockets.Now() - t0;
  Check.Check(~ok & (err.kind = Sockets.timedOut)
    & (err.text = "resolve localhost port 80: timed out") & Near(el, 100),
    "Sockets.ResolveWithin past its limit: timed out near 100 ms");

  (* Connecting: the lookup counts in the time limit *)
  ok := Sockets.Listen("127.0.0.1", 0, 4, FALSE, ls, nl, err)
    & Sockets.LocalAddress(ls[0], addrs[0], err);
  port := addrs[0].port;
  t0 := Sockets.Now();
  ok := ~SocketTasks.Connect("localhost", port, 100, c, err);
  el := Sockets.Now() - t0;
  Check.Check(ok & (c = NIL) & (err.kind = Sockets.timedOut)
    & StartsWith(err.text, "resolve localhost port ") & Near(el, 100),
    "SocketTasks.Connect: a slow lookup counts in its limit");
  t0 := Sockets.Now();
  ok := ~Sockets.ConnectWithin("localhost", port, 100, FALSE, c, err);
  el := Sockets.Now() - t0;
  Check.Check(ok & (c = NIL) & (err.kind = Sockets.timedOut)
    & StartsWith(err.text, "resolve localhost port ") & Near(el, 100),
    "Sockets.ConnectWithin: a slow lookup counts in its limit");
  ok := SocketTasks.Connect("127.0.0.1", port, 100, c, err);
  Check.Check(ok, "SocketTasks.Connect to 127.0.0.1 within 100 ms: no lookup to wait for");
  IF c # NIL THEN Sockets.Close(c) END;
  ok := SocketTasks.Connect("localhost", port, 2000, c, err);
  Check.Check(ok, "SocketTasks.Connect to localhost, a slow lookup within the limit");
  IF c # NIL THEN Sockets.Close(c) END;
  FOR i := 0 TO nl - 1 DO Sockets.Close(ls[i]) END;

  (* A Resolution dropped unfinished: its finalizer abandons it *)
  ok := Sockets.StartResolve("localhost", 80, r, err);
  r := NIL; GarbageCollectedHeap.Collect;
  TestHelp.SetResolveDelay(0);
  Settle;
  Check.Check(TestHelp.OpenFds() = fds0,
    "every abandoned lookup's thread done: descriptors back to their count");

  stop := TRUE; Tasks.Join(ticker);
  Check.Summary
END TestResolve.
