MODULE TestFileServer; (* examples/FileServer, with requests from here *)

(* PLAN.md, Phase 8: FileServer is started in the background on port 0
   serving ../build, for a fixed number of connections with a 500 ms
   timeout, and sent requests by tasks here, each on a connection of its
   own: a GET of this test's binary (a large file of every byte value),
   over IPv4 and (when ::1 can be bound) IPv6, must give 200 and the
   whole file; a HEAD, the same header and no body; a missing file, 404;
   a ".." path, 400; a POST, 405 with Allow; a line that isn't HTTP, 400.
   A client that sends nothing is closed with no answer once the timeout
   passes, and one that sends a large body after its request still gets
   the whole answer (the server's lingering close). The server must then
   exit 0 by itself. *)

IMPORT Platform, Out, Coroutines, Tasks, Sockets, SocketTasks, Check, TestHelp, Run;

CONST
  Buffers = 4096;
  Timeout = 500;            (* the server's, ms *)
  Junk = 100000;            (* bytes sent after a request *)
  Stack = Coroutines.DefaultStackSize;
  Patience = 60000;
  Self = "/TestFileServer"; (* this test's binary, under ../build *)

TYPE
  Request = POINTER TO RECORD (Tasks.TaskDesc)
    host: ARRAY 16 OF CHAR;
    text: ARRAY 256 OF CHAR;  (* "" sends nothing *)
    junk: BOOLEAN;          (* Junk bytes after text *)
    ok: BOOLEAN;            (* read to the end of stream *)
    why: ARRAY 256 OF CHAR;
    reply: Run.Bytes;
    n, took: LONGINT        (* bytes in reply; ms from connect to the end *)
  END;
  Writer = POINTER TO RECORD (Tasks.TaskDesc)
    r: Request;
    s: Sockets.Socket;
    ok: BOOLEAN
  END;
  Watchdog = POINTER TO RECORD (Tasks.TaskDesc) END;

VAR
  port: LONGINT;
  watchdog: Watchdog;
  crlf: ARRAY 3 OF CHAR;

PROCEDURE (w: Watchdog) Run*;
BEGIN
  Tasks.Sleep(Patience);
  Out.String("FAIL - the test took longer than "); Out.Int(Patience DIV 1000, 0);
  Out.String(" s"); Out.Ln;
  Run.Stop("FileServer");
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

PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
  VAR i: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  RETURN i
END Length;

PROCEDURE HaveIPv6(): BOOLEAN;
  VAR ls: ARRAY 2 OF Sockets.Socket; n: INTEGER; err: Sockets.Error;
BEGIN
  IF Sockets.Listen("::1", 0, 1, FALSE, ls, n, err) THEN
    Sockets.Close(ls[0]); RETURN TRUE
  END;
  RETURN FALSE
END HaveIPv6;

(* The request's text, then Junk bytes if it has them; then end of
   stream. *)
PROCEDURE (w: Writer) Run*;
  VAR buf: ARRAY 5000 OF CHAR; sent, k, i: LONGINT; err: Sockets.Error;
BEGIN
  w.ok := SocketTasks.WriteAll(w.s, w.r.text, 0, Length(w.r.text), k, err);
  IF w.r.junk THEN
    FOR i := 0 TO LEN(buf) - 1 DO buf[i] := "j" END;
    sent := 0;
    WHILE w.ok & (sent < Junk) DO
      w.ok := SocketTasks.WriteAll(w.s, buf, 0, LEN(buf), k, err);
      sent := sent + LEN(buf)
    END
  END;
  w.ok := w.ok & Sockets.Shutdown(w.s, Sockets.shutWrite, err)
END Run;

(* Sends the request from a Writer (unless it is ""), reading the reply
   here to the end. *)
PROCEDURE (r: Request) Run*;
  VAR s: Sockets.Socket; w: Writer; err: Sockets.Error; more: Run.Bytes;
    k, i, t0: LONGINT;
BEGIN
  r.ok := FALSE; r.n := 0; w := NIL;
  IF ~SocketTasks.Connect(r.host, SHORT(port), 10000, s, err) THEN
    COPY(err.text, r.why); RETURN
  END;
  t0 := Sockets.Now();
  IF ~TestHelp.SmallBuffers(s.fd, Buffers) THEN
    r.why := "SO_SNDBUF"; Sockets.Close(s); RETURN
  END;
  IF r.text # "" THEN NEW(w); w.r := r; w.s := s; Tasks.Start(w, Stack) END;
  NEW(r.reply, 65536);
  Sockets.SetDeadline(s, 20000);
  LOOP
    IF r.n = LEN(r.reply^) - 1 THEN
      NEW(more, 2 * LEN(r.reply^));
      FOR i := 0 TO r.n - 1 DO more[i] := r.reply[i] END;
      r.reply := more
    END;
    IF ~SocketTasks.Read(s, r.reply^, r.n, LEN(r.reply^) - 1 - r.n, k, err) THEN EXIT END;
    r.n := r.n + k
  END;
  r.reply[r.n] := 0X;
  r.took := Sockets.Now() - t0;
  r.ok := err.kind = Sockets.closed;
  IF ~r.ok THEN COPY(err.text, r.why) END;
  IF w # NIL THEN
    Tasks.Join(w);
    IF ~w.ok THEN r.ok := FALSE; r.why := "the writer failed" END
  END;
  Sockets.Close(s)
END Run;

PROCEDURE Start(host, text: ARRAY OF CHAR; junk: BOOLEAN): Request;
  VAR r: Request;
BEGIN
  NEW(r); COPY(host, r.host); COPY(text, r.text); r.junk := junk;
  Tasks.Start(r, Stack);
  RETURN r
END Start;

(* "<method> <target> HTTP/1.0", then the blank line. *)
PROCEDURE Get(method, target: ARRAY OF CHAR; VAR text: ARRAY OF CHAR);
BEGIN
  COPY(method, text); Append(text, " "); Append(text, target);
  Append(text, " HTTP/1.0"); Append(text, crlf);
  Append(text, "Host: localhost"); Append(text, crlf); Append(text, crlf)
END Get;

(* Where in r's reply the body starts, after the blank line; -1 if there
   is none. *)
PROCEDURE Body(r: Request): LONGINT;
  VAR i: LONGINT;
BEGIN
  FOR i := 3 TO r.n - 1 DO
    IF (r.reply[i - 3] = 0DX) & (r.reply[i - 2] = 0AX) & (r.reply[i - 1] = 0DX)
      & (r.reply[i] = 0AX) THEN RETURN i + 1
    END
  END;
  RETURN -1
END Body;

(* Whether r's reply has text in its head (its status line, or a header
   with its line end). *)
PROCEDURE Has(r: Request; text: ARRAY OF CHAR): BOOLEAN;
  VAR i, j, end: LONGINT;
BEGIN
  end := Body(r); IF end < 0 THEN RETURN FALSE END;
  FOR i := 0 TO end - 1 DO
    j := 0;
    WHILE (text[j] # 0X) & (i + j < end) & (r.reply[i + j] = text[j]) DO INC(j) END;
    IF text[j] = 0X THEN RETURN TRUE END
  END;
  RETURN FALSE
END Has;

(* Whether r's reply starts with status, and is ok. *)
PROCEDURE Status(r: Request; status: ARRAY OF CHAR): BOOLEAN;
  VAR line: ARRAY 64 OF CHAR; i: LONGINT;
BEGIN
  Tasks.Join(r);
  IF ~r.ok THEN
    Out.String("# "); Out.String(r.text); Out.String(": "); Out.String(r.why); Out.Ln;
    RETURN FALSE
  END;
  line := "HTTP/1.0 "; Append(line, status); Append(line, crlf);
  i := 0;
  WHILE (line[i] # 0X) & (i < r.n) & (r.reply[i] = line[i]) DO INC(i) END;
  RETURN line[i] = 0X
END Status;

(* Whether r's reply is a 200 with the whole of file as its body. *)
PROCEDURE Whole(r: Request; file: Run.Bytes): BOOLEAN;
  VAR h: ARRAY 64 OF CHAR; size, b, i: LONGINT;
BEGIN
  size := LEN(file^) - 1;
  h := "Content-Length: "; AppendInt(h, size); Append(h, crlf);
  IF ~Status(r, "200 OK") OR ~Has(r, h)
    OR ~Has(r, "Content-Type: application/octet-stream") THEN RETURN FALSE
  END;
  b := Body(r);
  IF r.n - b # size THEN RETURN FALSE END;
  i := 0; WHILE (i < size) & (r.reply[b + i] = file[i]) DO INC(i) END;
  RETURN i = size
END Whole;

PROCEDURE Main;
  VAR fds0, count, status: INTEGER; ipv6, ok: BOOLEAN; cmd: ARRAY 256 OF CHAR;
    path: ARRAY 64 OF CHAR; text: ARRAY 256 OF CHAR; h: ARRAY 64 OF CHAR;
    file: Run.Bytes;
    get4, get6, head, missing, dotdot, post, garbage, silent, junk: Request;
BEGIN
  IF Tasks.WakeDescriptor() < 0 THEN Check.Check(FALSE, "Tasks has its self-pipe") END;
  fds0 := TestHelp.OpenFds();
  crlf[0] := 0DX; crlf[1] := 0AX; crlf[2] := 0X;
  ipv6 := HaveIPv6();
  file := Run.Read("../build/TestFileServer");
  Check.Check((file # NIL) & (LEN(file^) > 100000), "the file to serve, this test's binary");
  IF file = NIL THEN RETURN END;

  count := 8; IF ipv6 THEN INC(count) END;
  cmd := "../build/FileServer 0 ../build "; AppendInt(cmd, count); Append(cmd, " ");
  AppendInt(cmd, Timeout); Append(cmd, " < /dev/null");
  Run.Start(cmd, "FileServer");
  Run.File("FileServer", ".out", path);
  ok := Run.Number(path, "port ", 10000, port);
  Check.Check(ok & (port > 0), "FileServer says its port first");
  IF ~ok THEN Run.Stop("FileServer"); RETURN END;

  Get("GET", Self, text); get4 := Start("127.0.0.1", text, FALSE);
  IF ipv6 THEN get6 := Start("::1", text, FALSE) END;
  Get("HEAD", Self, text); head := Start("127.0.0.1", text, FALSE);
  Get("GET", "/nothing-here", text); missing := Start("127.0.0.1", text, FALSE);
  Get("GET", "/../GNUmakefile", text); dotdot := Start("127.0.0.1", text, FALSE);
  Get("POST", Self, text); post := Start("127.0.0.1", text, FALSE);
  text := "hello"; Append(text, crlf); Append(text, crlf);
  garbage := Start("127.0.0.1", text, FALSE);
  silent := Start("127.0.0.1", "", FALSE);
  Get("GET", "/nothing-here", text); junk := Start("127.0.0.1", text, TRUE);

  Check.Check(Whole(get4, file), "GET over IPv4 gives 200 and the whole file");
  IF ipv6 THEN Check.Check(Whole(get6, file), "GET over IPv6 gives 200 and the whole file")
  ELSE Check.Check(TRUE, "IPv6 skipped: ::1 can't be bound")
  END;
  h := "Content-Length: "; AppendInt(h, LEN(file^) - 1); Append(h, crlf);
  Check.Check(Status(head, "200 OK") & Has(head, h) & (Body(head) = head.n),
    "HEAD gives the same header and no body");
  Check.Check(Status(missing, "404 Not Found"), "a missing file gives 404");
  Check.Check(Status(dotdot, "400 Bad Request"), "a path with .. gives 400");
  Check.Check(Status(post, "405 Method Not Allowed") & Has(post, "Allow: GET, HEAD"),
    "POST gives 405, with Allow");
  Check.Check(Status(garbage, "400 Bad Request"), "a request that isn't HTTP gives 400");
  Tasks.Join(silent);
  Check.Check(silent.ok & (silent.n = 0) & (silent.took >= Timeout - 50)
    & (silent.took < Timeout + 2000),
    "a client that sends nothing is closed after the timeout, unanswered");
  Check.Check(Status(junk, "404 Not Found") & (Body(junk) > 0)
    & (junk.n - Body(junk) = Length("404 Not Found") + 1),
    "a client that sends more than its request gets the whole answer");

  ok := Run.Wait("FileServer", 10000, status);
  Check.Check(ok & (status = 0), "FileServer exits 0 once it has served them all");
  Run.Stop("FileServer");
  Check.Check(TestHelp.OpenFds() = fds0, "every socket is closed again")
END Main;

BEGIN
  NEW(watchdog); Tasks.Start(watchdog, Stack);
  Main;
  Check.Summary
END TestFileServer.
