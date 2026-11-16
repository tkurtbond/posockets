MODULE HaltAddrs; (* Resolve into too small an array halts with AssertArgument (84) *)

(* The empty host gives both loopback addresses, 127.0.0.1 and ::1,
   whatever the machine's interfaces, so one Address is too few. *)

IMPORT Sockets;

VAR addrs: ARRAY 1 OF Sockets.Address; n: INTEGER; err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.Resolve("", 80, addrs, n, err)
END HaltAddrs.
