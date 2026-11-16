MODULE BlockingPeer; (* TestBlocking's peer, run as a separate process *)

(* BlockingPeer <host> <port>: connects (blocking Connect), sends
   "hello" and a newline, then reads until the other side shuts down its
   writing, checking every byte against TestBlocking's pattern
   (CHR(i MOD 251)), and replies "ok <count>" or "bad <count>" and a
   newline. A blocking call stops the whole program, so the two sides of
   a blocking exchange can't be tasks in one program (AGENTS.md, "Test").
   Errors go to standard error, and the exit status is 1. *)

IMPORT Args, Err, Platform, Sockets;

CONST Size = 65536;

VAR
  host: ARRAY 64 OF CHAR;
  port, n, count, i: LONGINT;
  s: Sockets.Socket;
  err: Sockets.Error;
  buf: ARRAY Size OF CHAR;
  reply: ARRAY 32 OF CHAR;
  good: BOOLEAN;

PROCEDURE Fail(what: ARRAY OF CHAR);
BEGIN
  Err.String("BlockingPeer: "); Err.String(what); Err.String(": ");
  Err.String(err.text); Err.Ln; Err.Flush;
  Platform.Exit(1)
END Fail;

PROCEDURE AppendInt(VAR s: ARRAY OF CHAR; n: LONGINT);
  VAR d: ARRAY 24 OF CHAR; i, j: INTEGER;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  j := 0; WHILE s[j] # 0X DO INC(j) END;
  WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END;
  s[j] := 0X
END AppendInt;

BEGIN
  Args.Get(1, host); Args.GetInt(2, port);
  IF ~Sockets.Connect(host, SHORT(port), s, err) THEN Fail("connect") END;
  buf := "hello"; buf[5] := 0AX;
  IF ~Sockets.WriteAll(s, buf, 0, 6, n, err) THEN Fail("write hello") END;
  count := 0; good := TRUE;
  WHILE Sockets.Read(s, buf, 0, Size, n, err) DO
    FOR i := 0 TO n - 1 DO
      good := good & (buf[i] = CHR((count + i) MOD 251))
    END;
    count := count + n
  END;
  IF err.kind # Sockets.closed THEN Fail("read") END;
  IF good THEN reply := "ok " ELSE reply := "bad " END;
  AppendInt(reply, count);
  i := 0; WHILE reply[i] # 0X DO INC(i) END;
  reply[i] := 0AX;
  IF ~Sockets.WriteAll(s, reply, 0, i + 1, n, err) THEN Fail("write reply") END;
  Sockets.Close(s)
END BlockingPeer.
