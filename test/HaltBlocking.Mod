MODULE HaltBlocking; (* SocketTasks on a blocking socket halts with 82 *)

IMPORT Sockets, SocketTasks;

VAR
  s, t: Sockets.Socket;
  err: Sockets.Error;
  buf: ARRAY 4 OF CHAR;
  n: LONGINT;

BEGIN
  IF Sockets.Pair(s, t, err) THEN
    IF SocketTasks.Read(s, buf, 0, LEN(buf), n, err) THEN END
  END
END HaltBlocking.
