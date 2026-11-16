MODULE HaltWaiting; (* Close while a SocketTasks Read waits halts with 86 *)

IMPORT Coroutines, Tasks, Sockets, SocketTasks;

TYPE
  Reader = POINTER TO RECORD (Tasks.TaskDesc) s: Sockets.Socket END;

VAR
  s, t: Sockets.Socket;
  err: Sockets.Error;
  r: Reader;

PROCEDURE (r: Reader) Run*;
  VAR buf: ARRAY 4 OF CHAR; n: LONGINT; err: Sockets.Error;
BEGIN
  IF SocketTasks.Read(r.s, buf, 0, LEN(buf), n, err) THEN END
END Run;

BEGIN
  IF Sockets.Pair(s, t, err) & Sockets.SetNonBlocking(s, TRUE, err) THEN
    NEW(r); r.s := s; Tasks.Start(r, Coroutines.DefaultStackSize);
    Tasks.Yield;
    Sockets.Close(s)
  END
END HaltWaiting.
