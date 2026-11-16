MODULE HaltListening; (* Read on a listening socket halts with AssertListening (85) *)

IMPORT Sockets;

VAR ls: ARRAY 2 OF Sockets.Socket; n: INTEGER; err: Sockets.Error;
  buf: ARRAY 8 OF CHAR; got: LONGINT; ok: BOOLEAN;

BEGIN
  ok := Sockets.Listen("127.0.0.1", 0, 1, FALSE, ls, n, err);
  ok := Sockets.Read(ls[0], buf, 0, 8, got, err)
END HaltListening.
