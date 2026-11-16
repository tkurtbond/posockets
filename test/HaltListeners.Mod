MODULE HaltListeners; (* Listen with too small an array halts with AssertArgument (84) *)

(* The empty host is two addresses, 0.0.0.0 and ::, wherever
   getaddrinfo is asked without AI_ADDRCONFIG. *)

IMPORT Sockets;

VAR ls: ARRAY 1 OF Sockets.Socket; n: INTEGER; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.Listen("", 0, 1, FALSE, ls, n, err)
END HaltListeners.
