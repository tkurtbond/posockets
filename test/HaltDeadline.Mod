MODULE HaltDeadline; (* SetDeadline with a negative ms halts (84) *)

IMPORT Sockets;

VAR a, b: Sockets.Socket; err: Sockets.Error; ms: LONGINT;

BEGIN
  IF Sockets.Pair(a, b, err) THEN
    ms := -1;
    Sockets.SetDeadline(a, ms)
  END
END HaltDeadline.
