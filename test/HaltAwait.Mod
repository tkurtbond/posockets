MODULE HaltAwait; (* Await for neither reading nor writing halts (84) *)

IMPORT Sockets;

VAR a, b: Sockets.Socket; err: Sockets.Error; ok: BOOLEAN; want: INTEGER;

BEGIN
  IF Sockets.Pair(a, b, err) THEN
    want := 0;
    ok := Sockets.Await(a, want, "recv", err)
  END
END HaltAwait.
