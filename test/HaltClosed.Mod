MODULE HaltClosed; (* LocalAddress on a closed socket halts with AssertClosed (80) *)

IMPORT Sockets;

VAR s, t: Sockets.Socket; a: Sockets.Address; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.Pair(s, t, err);
  Sockets.Close(s); Sockets.Close(t);
  ok := Sockets.LocalAddress(s, a, err)
END HaltClosed.
