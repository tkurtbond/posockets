MODULE HaltPath; (* ListenUnix with a path of 108 bytes, too long for Linux's sun_path, halts with AssertPath (83) *)

IMPORT Sockets;

VAR path: ARRAY 200 OF CHAR; i: INTEGER; l: Sockets.Socket; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  FOR i := 0 TO 107 DO path[i] := "x" END; path[108] := 0X;
  ok := Sockets.ListenUnix(path, 1, FALSE, l, err)
END HaltPath.
