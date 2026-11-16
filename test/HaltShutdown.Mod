MODULE HaltShutdown; (* Shutdown with an unknown how halts with AssertArgument (84) *)

IMPORT Sockets;

VAR s, t: Sockets.Socket; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.Pair(s, t, err);
  ok := Sockets.Shutdown(s, 3, err)
END HaltShutdown.
