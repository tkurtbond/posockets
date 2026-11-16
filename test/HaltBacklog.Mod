MODULE HaltBacklog; (* Listen with a negative backlog halts with AssertArgument (84) *)

IMPORT Sockets;

VAR ls: ARRAY 2 OF Sockets.Socket; n: INTEGER; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.Listen("127.0.0.1", 0, -1, FALSE, ls, n, err)
END HaltBacklog.
