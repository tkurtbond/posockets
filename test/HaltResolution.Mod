MODULE HaltResolution; (* FinishResolve on a Resolution already finished halts with AssertResolution (87) *)

IMPORT Sockets;

VAR r: Sockets.Resolution; addrs: ARRAY 4 OF Sockets.Address; n: INTEGER;
  err: Sockets.Error; ok: BOOLEAN;

BEGIN
  ok := Sockets.StartResolve("127.0.0.1", 80, r, err);
  ok := Sockets.FinishResolve(r, addrs, n, err);
  ok := Sockets.FinishResolve(r, addrs, n, err)
END HaltResolution.
