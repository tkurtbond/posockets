MODULE HaltAccept; (* Accept on a socket that isn't listening halts with AssertListening (85) *)

IMPORT Sockets;

VAR s, t, u: Sockets.Socket; a: Sockets.Address; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.Pair(s, t, err);
  ok := Sockets.Accept(s, FALSE, u, a, err)
END HaltAccept.
