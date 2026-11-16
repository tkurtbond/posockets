MODULE HaltRange; (* Write past the end of its buffer halts with AssertRange (81) *)

IMPORT Sockets;

VAR s, t: Sockets.Socket; err: Sockets.Error; buf: ARRAY 8 OF CHAR;
  n: LONGINT; ok: BOOLEAN;

BEGIN
  ok := Sockets.Pair(s, t, err);
  ok := Sockets.Write(s, buf, 4, 5, n, err)
END HaltRange.
