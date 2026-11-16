MODULE EchoClient; (* A blocking TCP client: sends a line, prints the reply *)

(* Usage: EchoClient host port word...

   Connects to host and port, sends the words with spaces between and a
   line end after, ends its side (Shutdown), and copies what comes back
   to standard output until the server ends its side. Against
   EchoServer, it prints the line it sent.

   The smallest complete client: blocking calls only, no tasks. *)

IMPORT SYSTEM, Platform, Err, Args, Sockets;

PROCEDURE Fail(err: Sockets.Error);
BEGIN
  Err.String(err.text); Err.Ln; Platform.Exit(1)
END Fail;

PROCEDURE Main;
  VAR s: Sockets.Socket; err: Sockets.Error; line: ARRAY 1024 OF CHAR;
    word, host: ARRAY 256 OF CHAR; buf: ARRAY 4096 OF CHAR;
    port, n, k: LONGINT; i, j, len: INTEGER;
BEGIN
  IF Args.argc < 4 THEN
    Err.String("usage: EchoClient host port word..."); Err.Ln; Platform.Exit(2)
  END;
  Args.Get(1, host);
  port := -1; Args.GetInt(2, port);
  IF (port < 1) OR (port > 65535) THEN
    Err.String("EchoClient: a bad port"); Err.Ln; Platform.Exit(2)
  END;
  (* the words, cut short at line's size *)
  len := 0;
  FOR i := 3 TO Args.argc - 1 DO
    Args.Get(i, word);
    IF (i > 3) & (len < LEN(line) - 2) THEN line[len] := " "; INC(len) END;
    j := 0;
    WHILE (word[j] # 0X) & (len < LEN(line) - 2) DO
      line[len] := word[j]; INC(len); INC(j)
    END
  END;
  line[len] := 0AX; INC(len);

  IF ~Sockets.Connect(host, SHORT(port), s, err) THEN Fail(err) END;
  IF ~Sockets.WriteAll(s, line, 0, len, k, err)
    OR ~Sockets.Shutdown(s, Sockets.shutWrite, err) THEN Fail(err)
  END;
  WHILE Sockets.Read(s, buf, 0, LEN(buf), n, err) DO
    IF Platform.Write(Platform.StdOut, SYSTEM.ADR(buf), n) # 0 THEN Platform.Exit(1) END
  END;
  IF err.kind # Sockets.closed THEN Fail(err) END;
  Sockets.Close(s)
END Main;

BEGIN
  Main
END EchoClient.
