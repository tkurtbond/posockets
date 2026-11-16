MODULE HaltPort; (* Resolve with a port above 65535 halts with AssertArgument (84) *)

IMPORT Sockets;

VAR addrs: ARRAY 4 OF Sockets.Address; n: INTEGER; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.Resolve("127.0.0.1", 65536, addrs, n, err)
END HaltPort.
