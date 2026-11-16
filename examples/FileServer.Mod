MODULE FileServer; (* A minimal static-file server over HTTP/1.0 *)

(* Usage: FileServer port dir [count [timeout]]

   Serves the files under dir over HTTP/1.0, on every local address,
   IPv6 and IPv4, at port (0: one the kernel chooses), printing "port
   <n>" as its first line, and a line per request on standard error.
   Try it with curl:

     FileServer 8080 . &
     curl -i http://localhost:8080/README.md

   GET and HEAD only (405 for anything else). A path ending in "/" means
   its index.html. A few content types are known by extension; anything
   else is application/octet-stream. A request that is malformed, too
   long, or has a ".." segment gets 400, a file that can't be read 404.
   Percent-escapes are not decoded, so "%2e%2e" is a name, not "..". A
   client must send its request within timeout ms (default 10000), and
   each write of the answer must make progress within that too. With
   count, it serves that many connections, waits for them to end, and
   exits; without, it serves until killed.

   NOT for the open internet: it follows symbolic links out of dir, has
   no limit on connections, and knows only as much HTTP as curl and a
   browser need. It is here to show a server's shape: a task per
   connection, a deadline on reading the request, and LingeringClose,
   so a client that sent more than was read still gets the whole
   answer instead of a reset. Reading the file is a blocking read, as
   files are always ready; a file on a slow disk holds every task. *)

IMPORT SYSTEM, Platform, Out, Err, Args, Coroutines, Tasks, Sockets, SocketTasks;

CONST
  Stack = Coroutines.DefaultStackSize;
  Tick = 200;               (* ms an accept waits before looking at stop *)
  HeadMax = 8192;           (* the most of a request read *)
  Linger = 2000;            (* ms LingeringClose waits *)
  CR = 0DX; LF = 0AX;

TYPE
  Client = POINTER TO RECORD (Tasks.TaskDesc)
    s: Sockets.Socket;
    next: Client
  END;
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    l: Sockets.Socket
  END;
  Text = ARRAY 512 OF CHAR;

VAR
  dir: ARRAY 256 OF CHAR;
  count, timeout: LONGINT;  (* connections to serve (0: no end), ms *)
  served: LONGINT;
  stop: BOOLEAN;
  clients: Client;          (* every connection's task, to join at the end *)

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

PROCEDURE AppendInt(VAR s: ARRAY OF CHAR; n: LONGINT);
  VAR d: ARRAY 24 OF CHAR; i: INTEGER; t: ARRAY 2 OF CHAR;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  t[1] := 0X;
  WHILE i > 0 DO DEC(i); t[0] := d[i]; Append(s, t) END
END AppendInt;

PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
  VAR i: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  RETURN i
END Length;

(* Whether s ends with suffix. *)
PROCEDURE Ends(s, suffix: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: LONGINT;
BEGIN
  i := Length(s); j := Length(suffix);
  IF j > i THEN RETURN FALSE END;
  WHILE (j > 0) & (s[i - 1] = suffix[j - 1]) DO DEC(i); DEC(j) END;
  RETURN j = 0
END Ends;

PROCEDURE ContentType(path: ARRAY OF CHAR; VAR type: ARRAY OF CHAR);
BEGIN
  IF Ends(path, ".html") OR Ends(path, ".htm") THEN COPY("text/html", type)
  ELSIF Ends(path, ".txt") OR Ends(path, ".md") OR Ends(path, ".Mod")
    OR Ends(path, ".c") THEN COPY("text/plain; charset=utf-8", type)
  ELSIF Ends(path, ".gmi") THEN COPY("text/gemini", type)
  ELSIF Ends(path, ".css") THEN COPY("text/css", type)
  ELSIF Ends(path, ".js") THEN COPY("text/javascript", type)
  ELSIF Ends(path, ".png") THEN COPY("image/png", type)
  ELSIF Ends(path, ".jpg") OR Ends(path, ".jpeg") THEN COPY("image/jpeg", type)
  ELSIF Ends(path, ".gif") THEN COPY("image/gif", type)
  ELSE COPY("application/octet-stream", type)
  END
END ContentType;

(* Sends all of buf[0..n-1], each wait at most timeout ms. *)
PROCEDURE Send(s: Sockets.Socket; buf-: ARRAY OF CHAR; n: LONGINT): BOOLEAN;
  VAR k: LONGINT; err: Sockets.Error;
BEGIN
  Sockets.SetDeadline(s, timeout);
  RETURN SocketTasks.WriteAll(s, buf, 0, n, k, err)
END Send;

(* The status line and headers, then the blank line. *)
PROCEDURE Header(s: Sockets.Socket; status: ARRAY OF CHAR; type: ARRAY OF CHAR;
    length: LONGINT; extra: ARRAY OF CHAR): BOOLEAN;
  VAR h: Text; crlf: ARRAY 3 OF CHAR;
BEGIN
  crlf[0] := CR; crlf[1] := LF; crlf[2] := 0X;
  h := "HTTP/1.0 "; Append(h, status); Append(h, crlf);
  Append(h, "Server: posockets FileServer"); Append(h, crlf);
  Append(h, "Content-Type: "); Append(h, type); Append(h, crlf);
  Append(h, "Content-Length: "); AppendInt(h, length); Append(h, crlf);
  IF extra # "" THEN Append(h, extra); Append(h, crlf) END;
  Append(h, "Connection: close"); Append(h, crlf); Append(h, crlf);
  RETURN Send(s, h, Length(h))
END Header;

(* An error answer, with its status line as the body. *)
PROCEDURE Refuse(s: Sockets.Socket; status, extra: ARRAY OF CHAR; head: BOOLEAN);
  VAR body: Text;
BEGIN
  body := ""; Append(body, status); Append(body, 0AX);
  IF Header(s, status, "text/plain", Length(body), extra) & ~head THEN
    IF Send(s, body, Length(body)) THEN END
  END
END Refuse;

(* Reads the request head, up to the blank line, into buf; n is its
   length. FALSE if the client ends, fails, times out, or sends more
   than HeadMax without one. *)
PROCEDURE ReadHead(s: Sockets.Socket; VAR buf: ARRAY OF CHAR; VAR n: LONGINT;
    VAR err: Sockets.Error): BOOLEAN;
  VAR k, i: LONGINT;
BEGIN
  n := 0;
  (* the whole request within timeout, not each read: a client sending
     a byte at a time can't hold the task for ever *)
  Sockets.SetDeadline(s, timeout);
  LOOP
    IF n = LEN(buf) - 1 THEN Sockets.ClearError(err); RETURN FALSE END;
    IF ~SocketTasks.Read(s, buf, n, LEN(buf) - 1 - n, k, err) THEN RETURN FALSE END;
    n := n + k; buf[n] := 0X;
    FOR i := 1 TO n - 1 DO
      IF (buf[i] = LF) & ((buf[i - 1] = LF)
          OR (i >= 3) & (buf[i - 1] = CR) & (buf[i - 2] = LF)) THEN
        RETURN TRUE
      END
    END
  END
END ReadHead;

(* Splits the request line "METHOD target HTTP/x.y" in buf. *)
PROCEDURE Parse(buf: ARRAY OF CHAR; VAR method, target: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: LONGINT;
BEGIN
  i := 0; j := 0;
  WHILE (buf[i] >= "A") & (buf[i] <= "Z") & (j < LEN(method) - 1) DO
    method[j] := buf[i]; INC(i); INC(j)
  END;
  method[j] := 0X;
  IF (j = 0) OR (buf[i] # " ") THEN RETURN FALSE END;
  INC(i); j := 0;
  WHILE (buf[i] > " ") & (buf[i] < 7FX) & (j < LEN(target) - 1) DO
    target[j] := buf[i]; INC(i); INC(j)
  END;
  target[j] := 0X;
  RETURN (j > 0) & (buf[i] = " ") & (buf[i + 1] = "H") & (buf[i + 2] = "T")
    & (buf[i + 3] = "T") & (buf[i + 4] = "P") & (buf[i + 5] = "/")
END Parse;

(* The file target names under dir, as path; FALSE unless target is a
   path ("/...") with no ".." segment. The query, if any, is dropped. *)
PROCEDURE Resolve(target: ARRAY OF CHAR; VAR path: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT; t: ARRAY 2 OF CHAR;
BEGIN
  IF target[0] # "/" THEN RETURN FALSE END;
  i := 0; WHILE (target[i] # 0X) & (target[i] # "?") DO INC(i) END;
  target[i] := 0X;
  i := 0;
  WHILE target[i] # 0X DO
    IF (target[i] = "/") & (target[i + 1] = ".") & (target[i + 2] = ".")
      & ((target[i + 3] = "/") OR (target[i + 3] = 0X)) THEN
      RETURN FALSE
    END;
    INC(i)
  END;
  COPY(dir, path); t[1] := 0X;
  i := 0; WHILE target[i] # 0X DO t[0] := target[i]; Append(path, t); INC(i) END;
  IF Ends(path, "/") THEN Append(path, "index.html") END;
  RETURN Length(path) < LEN(path) - 1
END Resolve;

(* Answers with the file at path, or 404. The first read comes before
   the header, so a directory (EISDIR) or an unreadable file is a 404,
   not a 200 with no body. *)
PROCEDURE SendFile(s: Sockets.Socket; path: ARRAY OF CHAR; head: BOOLEAN;
    VAR status: ARRAY OF CHAR);
  VAR h: Platform.FileHandle; e: Platform.ErrorCode; size, n, sent: LONGINT;
    buf: ARRAY 16384 OF CHAR; type: ARRAY 64 OF CHAR; ok: BOOLEAN;
BEGIN
  IF (Platform.OldRO(path, h) # 0) THEN
    COPY("404 Not Found", status); Refuse(s, status, "", head); RETURN
  END;
  ok := (Platform.Size(h, size) = 0)
    & (Platform.Read(h, SYSTEM.ADR(buf), LEN(buf), n) = 0);
  IF ~ok THEN
    e := Platform.Close(h);
    COPY("404 Not Found", status); Refuse(s, status, "", head); RETURN
  END;
  COPY("200 OK", status); ContentType(path, type);
  ok := Header(s, status, type, size, "");
  IF ~head THEN
    (* until size, in case the file grows meanwhile: the length sent is
       a promise *)
    sent := 0;
    WHILE ok & (n > 0) & (sent < size) DO
      IF n > size - sent THEN n := size - sent END;
      ok := Send(s, buf, n); sent := sent + n;
      ok := ok & (Platform.Read(h, SYSTEM.ADR(buf), LEN(buf), n) = 0)
    END
  END;
  e := Platform.Close(h)
END SendFile;

(* One request, one answer, then a lingering close. *)
PROCEDURE (c: Client) Run*;
  VAR buf: ARRAY HeadMax OF CHAR; n: LONGINT; err: Sockets.Error;
    method: ARRAY 16 OF CHAR; target: ARRAY 1024 OF CHAR;
    path: ARRAY 2048 OF CHAR; status: ARRAY 64 OF CHAR; head: BOOLEAN;
BEGIN
  method := ""; target := "";
  IF ~ReadHead(c.s, buf, n, err) THEN
    IF n # 0 THEN
      status := "400 Bad Request"; Refuse(c.s, status, "", FALSE)
    ELSE status := "-"   (* nothing came: no answer *)
    END
  ELSIF ~Parse(buf, method, target) THEN
    status := "400 Bad Request"; Refuse(c.s, status, "", FALSE)
  ELSIF (method # "GET") & (method # "HEAD") THEN
    status := "405 Method Not Allowed"; Refuse(c.s, status, "Allow: GET, HEAD", FALSE)
  ELSE
    head := method = "HEAD";
    IF ~Resolve(target, path) THEN
      status := "400 Bad Request"; Refuse(c.s, status, "", head)
    ELSE SendFile(c.s, path, head, status)
    END
  END;
  Err.String(method); Err.Char(" "); Err.String(target); Err.Char(" ");
  Err.String(status); Err.Ln;
  IF SocketTasks.LingeringClose(c.s, Linger) THEN END
END Run;

(* Accepts connections on l, starting a Client for each, until stop. *)
PROCEDURE (a: Acceptor) Run*;
  VAR c: Client; peer: Sockets.Address; err: Sockets.Error;
BEGIN
  WHILE ~stop DO
    NEW(c);
    Sockets.SetDeadline(a.l, Tick);
    IF SocketTasks.Accept(a.l, c.s, peer, err) THEN
      c.next := clients; clients := c; Tasks.Start(c, Stack);
      INC(served);
      IF served = count THEN stop := TRUE END
    ELSIF err.kind # Sockets.timedOut THEN
      (* EMFILE, a connection reset while queued: report, go on *)
      Err.String(err.text); Err.Ln; Tasks.Sleep(10)
    END
  END;
  Sockets.Close(a.l)
END Run;

PROCEDURE Usage;
BEGIN
  Err.String("usage: FileServer port dir [count [timeout-ms]]"); Err.Ln;
  Platform.Exit(2)
END Usage;

PROCEDURE Main;
  VAR ls: ARRAY 2 OF Sockets.Socket; as: ARRAY 2 OF Acceptor;
    a: Sockets.Address; err: Sockets.Error; port: LONGINT; n, i: INTEGER;
BEGIN
  IF (Args.argc < 3) OR (Args.argc > 5) THEN Usage END;
  port := -1; Args.GetInt(1, port);
  Args.Get(2, dir);
  count := 0; IF Args.argc > 3 THEN Args.GetInt(3, count) END;
  timeout := 10000; IF Args.argc > 4 THEN Args.GetInt(4, timeout) END;
  IF (port < 0) OR (port > 65535) OR (dir = "") OR (count < 0) OR (timeout < 1) THEN
    Usage
  END;
  (* the target's "/" joins it *)
  IF Ends(dir, "/") THEN dir[Length(dir) - 1] := 0X END;
  Sockets.IgnoreBrokenPipe;
  IF ~Sockets.Listen("", SHORT(port), 16, TRUE, ls, n, err)
    OR ~Sockets.LocalAddress(ls[0], a, err) THEN
    Err.String(err.text); Err.Ln; Platform.Exit(1)
  END;
  Out.String("port "); Out.Int(a.port, 0); Out.Ln;
  FOR i := 0 TO n - 1 DO NEW(as[i]); as[i].l := ls[i]; Tasks.Start(as[i], Stack) END;
  FOR i := 0 TO n - 1 DO Tasks.Join(as[i]) END;
  WHILE clients # NIL DO Tasks.Join(clients); clients := clients.next END
END Main;

BEGIN
  Main
END FileServer.
