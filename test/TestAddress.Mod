MODULE TestAddress; (* Errors, addresses, Resolve, Pair and Listen *)

(* PLAN.md, "Testing": Resolve's text for both families and its errors,
   Pair, LocalAddress and PeerAddress on a pair, Close; Listen on
   127.0.0.1, ::1, localhost and the empty host with port 0. No name
   server is needed: the hosts are numeric, localhost, the empty host,
   and nonexistent.invalid, which RFC 6761 guarantees never resolves. *)

IMPORT SYSTEM, Platform, Sockets, Check, TestHelp;

VAR
  addrs: ARRAY 8 OF Sockets.Address;
  a: Sockets.Address;
  err: Sockets.Error;
  s, t: Sockets.Socket;
  n, i: INTEGER;
  ok, loopback: BOOLEAN;
  long: ARRAY 600 OF CHAR;
  buf: ARRAY 8 OF CHAR;
  got: LONGINT;
  ls: ARRAY 8 OF Sockets.Socket;
  fds0: INTEGER;

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

PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
  VAR i: LONGINT;
BEGIN
  i := 0; WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  RETURN i
END Length;

PROCEDURE CloseAll(VAR ls: ARRAY OF Sockets.Socket; n: INTEGER);
  VAR i: INTEGER;
BEGIN
  FOR i := 0 TO n - 1 DO Sockets.Close(ls[i]) END
END CloseAll;

(* Whether ls[0..n-1] are listening, blocking, of distinct families, all
   on one nonzero port, with their local addresses' hosts among
   hosts4/hosts6 (by family). *)
PROCEDURE Listening(VAR ls: ARRAY OF Sockets.Socket; n: INTEGER;
    host4, host6: ARRAY OF CHAR): BOOLEAN;
  VAR i, port: INTEGER; a: Sockets.Address; err: Sockets.Error;
    ok: BOOLEAN; seen: SET;
BEGIN
  ok := n >= 1; port := -1; seen := {};
  FOR i := 0 TO n - 1 DO
    ok := ok & ls[i].listening & ~ls[i].nonBlocking & (ls[i].fd >= 0)
      & ~(ls[i].family IN seen) & Sockets.LocalAddress(ls[i], a, err)
      & (a.family = ls[i].family) & (a.port > 0)
      & ((port = -1) OR (a.port = port))
      & ((a.family = Sockets.inet) & (a.host = host4)
         OR (a.family = Sockets.inet6) & (a.host = host6));
    INCL(seen, ls[i].family); port := a.port
  END;
  RETURN ok
END Listening;

BEGIN
  (* The errno values come from the C part, so they are the system's. *)
  Check.Check((Sockets.ECONNREFUSED > 0) & (Sockets.ECONNRESET > 0)
    & (Sockets.EPIPE > 0) & (Sockets.EADDRINUSE > 0) & (Sockets.EMFILE > 0)
    & (Sockets.ENFILE > 0) & (Sockets.EMFILE # Sockets.ENFILE)
    & (Sockets.ECONNREFUSED # Sockets.ECONNRESET),
    "errno constants are set and distinct");

  (* Numeric hosts, both families *)
  ok := Sockets.Resolve("127.0.0.1", 80, addrs, n, err);
  Check.Check(ok & (n = 1) & (err.kind = Sockets.none), "Resolve 127.0.0.1");
  Check.Check((addrs[0].family = Sockets.inet) & (addrs[0].host = "127.0.0.1")
    & (addrs[0].port = 80), "127.0.0.1 comes back as inet, its text, port 80");
  ok := Sockets.Resolve("::1", 1965, addrs, n, err);
  Check.Check(ok & (n = 1), "Resolve ::1");
  Check.Check((addrs[0].family = Sockets.inet6) & (addrs[0].host = "::1")
    & (addrs[0].port = 1965), "::1 comes back as inet6, its text, port 1965");
  ok := Sockets.Resolve("2001:DB8:0:0::1", 65535, addrs, n, err);
  Check.Check(ok & (n = 1) & (addrs[0].host = "2001:db8::1")
    & (addrs[0].port = 65535), "an IPv6 address comes back in canonical text");
  (* The loopback interface: lo on Linux, lo0 on the BSDs *)
  ok := Sockets.Resolve("fe80::1%lo", 1, addrs, n, err);
  IF ok THEN
    ok := (n = 1) & (addrs[0].host = "fe80::1%lo")
  ELSE
    ok := Sockets.Resolve("fe80::1%lo0", 1, addrs, n, err)
      & (n = 1) & (addrs[0].host = "fe80::1%lo0")
  END;
  Check.Check(ok, "a scope id comes back as getnameinfo writes it");

  (* localhost and the empty host: loopback addresses only *)
  ok := Sockets.Resolve("localhost", 0, addrs, n, err);
  loopback := ok & (n >= 1);
  FOR i := 0 TO n - 1 DO
    loopback := loopback & (addrs[i].port = 0)
      & ((addrs[i].family = Sockets.inet) & StartsWith(addrs[i].host, "127.")
         OR (addrs[i].family = Sockets.inet6) & (addrs[i].host = "::1"))
  END;
  Check.Check(loopback, "localhost resolves to loopback addresses only");
  ok := Sockets.Resolve("", 7, addrs, n, err);
  loopback := ok & (n >= 1);
  FOR i := 0 TO n - 1 DO
    loopback := loopback & ((addrs[i].host = "127.0.0.1") OR (addrs[i].host = "::1"))
  END;
  Check.Check(loopback, "the empty host resolves to the loopback addresses");

  (* A name that doesn't resolve is an error, not a halt. *)
  ok := Sockets.Resolve("nonexistent.invalid", 80, addrs, n, err);
  Check.Check(~ok & (n = 0) & (err.kind = Sockets.name) & (err.code # 0),
    "nonexistent.invalid is a name error");
  Check.Check(StartsWith(err.text, "resolve nonexistent.invalid port 80: ")
    & (Length(err.text) > 38), "its text says what was resolved, and why not");

  (* A host far longer than Error.text: the text is truncated. *)
  FOR i := 0 TO 598 DO long[i] := "a" END; long[599] := 0X;
  ok := Sockets.Resolve(long, 80, addrs, n, err);
  Check.Check(~ok & (err.kind = Sockets.name), "a 599-character host is a name error");
  Check.Check(StartsWith(err.text, "resolve aaaa") & (Length(err.text) = LEN(err.text) - 1),
    "its text is truncated to Error.text, and terminated");
  ok := Sockets.Resolve("127.0.0.1", 80, addrs, n, err);
  Check.Check(ok & (err.kind = Sockets.none) & (err.code = 0) & (err.text = ""),
    "a success clears the error");

  (* Pair *)
  ok := Sockets.Pair(s, t, err);
  Check.Check(ok & (s # NIL) & (t # NIL) & (s.fd >= 0) & (t.fd >= 0)
    & (s.fd # t.fd), "Pair gives two descriptors");
  Check.Check((s.family = Sockets.unix) & (t.family = Sockets.unix)
    & ~s.listening & ~s.nonBlocking & (s.waiters = 0), "both are unix, blocking");
  buf := "ping";
  Check.Check((Platform.Write(s.fd, SYSTEM.ADR(buf[0]), 4) = 0)
    & (Platform.Read(t.fd, SYSTEM.ADR(buf[4]), 3, got) = 0) & (got = 3),
    "bytes written to one end are read from the other");
  buf[7] := 0X;
  Check.Check(buf = "pingpin", "and they are the bytes written");
  ok := Sockets.LocalAddress(s, a, err);
  Check.Check(ok & (a.family = Sockets.unix) & (a.host = "") & (a.port = 0),
    "a pair's local address is unix and unnamed");
  ok := Sockets.PeerAddress(t, a, err);
  Check.Check(ok & (a.family = Sockets.unix) & (a.host = "") & (a.port = 0),
    "a pair's peer address is unix and unnamed");

  (* Close, twice *)
  Sockets.Close(s);
  Check.Check(s.fd = -1, "Close sets fd to -1");
  Sockets.Close(s);
  Check.Check(s.fd = -1, "Close on a closed socket does nothing");
  Sockets.Close(t);

  (* Listen, port 0: the kernel's port, the same for every listener *)
  fds0 := TestHelp.OpenFds();
  ok := Sockets.Listen("127.0.0.1", 0, 5, FALSE, ls, n, err);
  Check.Check(ok & (n = 1) & (ls[0].family = Sockets.inet)
    & Listening(ls, n, "127.0.0.1", ""), "Listen on 127.0.0.1, port 0");
  CloseAll(ls, n);
  ok := Sockets.Listen("::1", 0, 5, FALSE, ls, n, err);
  IF ~ok & (err.kind = Sockets.system) & ((err.code = Sockets.EADDRNOTAVAIL)
      OR (err.code = Sockets.EAFNOSUPPORT)) THEN
    Check.Check(TRUE, "Listen on ::1 skipped: no IPv6 here")
  ELSE
    Check.Check(ok & (n = 1) & (ls[0].family = Sockets.inet6)
      & Listening(ls, n, "", "::1"), "Listen on ::1, port 0");
    CloseAll(ls, n)
  END;
  ok := Sockets.Listen("localhost", 0, 5, FALSE, ls, n, err);
  Check.Check(ok & Listening(ls, n, "127.0.0.1", "::1"),
    "Listen on localhost: one listener per address, one port");
  CloseAll(ls, n);
  ok := Sockets.Listen("", 0, 5, FALSE, ls, n, err);
  Check.Check(ok & (n >= 1) & Listening(ls, n, "0.0.0.0", "::"),
    "Listen on the empty host: the wildcard addresses, one port");
  CloseAll(ls, n);
  ok := Sockets.Listen("127.0.0.1", 0, 0, TRUE, ls, n, err);
  Check.Check(ok & (n = 1) & ls[0].nonBlocking & ls[0].listening,
    "a non-blocking listener says so");
  CloseAll(ls, n);
  ok := Sockets.Listen("nonexistent.invalid", 0, 5, FALSE, ls, n, err);
  Check.Check(~ok & (n = 0) & (err.kind = Sockets.name)
    & StartsWith(err.text, "listen on nonexistent.invalid port 0: "),
    "Listen on a name that doesn't resolve is a name error");
  ok := Sockets.Listen("192.0.2.1", 0, 5, FALSE, ls, n, err);
  Check.Check(~ok & (n = 0) & (err.kind = Sockets.system)
    & (err.code = Sockets.EADDRNOTAVAIL)
    & StartsWith(err.text, "bind 192.0.2.1 port 0: "),
    "Listen on an address not this machine's is EADDRNOTAVAIL, saying where");
  Check.Check(TestHelp.OpenFds() = fds0, "every listener is closed again");

  Check.Summary
END TestAddress.
