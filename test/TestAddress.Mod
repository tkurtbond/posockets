MODULE TestAddress; (* Errors, addresses, Resolve and Pair (Phase 2) *)

(* The parts of TestAddress that need no listening socket (PLAN.md,
   "Testing"): Resolve's text for both families and its errors, Pair,
   LocalAddress and PeerAddress on a pair, Close. Listening joins in
   Phase 3. No name server is needed: the hosts are numeric, localhost,
   the empty host, and nonexistent.invalid, which RFC 6761 guarantees
   never resolves. *)

IMPORT SYSTEM, Platform, Sockets, Check;

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
  ok := Sockets.Resolve("fe80::1%lo", 1, addrs, n, err);
  Check.Check(ok & (n = 1) & (addrs[0].host = "fe80::1%lo"),
    "a scope id comes back as getnameinfo writes it");

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

  Check.Summary
END TestAddress.
