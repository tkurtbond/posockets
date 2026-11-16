MODULE HaltEmptyPath; (* ConnectUnix with an empty path halts with AssertArgument (84) *)

IMPORT Sockets;

VAR path: ARRAY 8 OF CHAR; s: Sockets.Socket; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  path[0] := 0X;
  ok := Sockets.ConnectUnix(path, FALSE, s, err)
END HaltEmptyPath.
