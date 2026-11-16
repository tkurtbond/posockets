MODULE Sockets; (* TCP and Unix-domain sockets for poc *)

(* A Socket wraps a descriptor, so a closed one is visible (fd = -1) and
   an operation on it halts instead of acting on a descriptor number the
   kernel may since have given to something else. Anything the network
   or the system does comes back as a BOOLEAN result and an Error, never
   a halt; only a programmer's error halts, with one of the Assert codes
   below (PLAN.md, "Halt codes").

   Phase 1 (PLAN.md, "Roadmap"): the types and constants only; the
   operations come in later phases. *)

CONST
  (* Address families, Socket.family *)
  inet* = 1; inet6* = 2; unix* = 3;

  (* Codes of the ASSERTs that catch a programmer's error. poc's ASSERT
     exits with status 10 and prints "assertion failed (n)". *)
  AssertClosed* = 80;      (* a closed socket used, other than by Close *)
  AssertRange* = 81;       (* a buffer range outside its array *)
  AssertBlocking* = 82;    (* a blocking socket given to SocketTasks *)
  AssertPath* = 83;        (* a Unix-domain path too long for sun_path *)
  AssertArgument* = 84;    (* an argument out of range *)
  AssertListening* = 85;   (* Accept on a socket that isn't listening, or
                              I/O on one that is *)
  AssertWaiting* = 86;     (* Close while a SocketTasks call waits on it *)

TYPE
  Socket* = POINTER TO SocketDesc;
  SocketDesc* = RECORD
    fd-: LONGINT;          (* -1 once closed *)
    family-: INTEGER;      (* inet, inet6 or unix *)
    listening-: BOOLEAN;   (* made by Listen, or SO_ACCEPTCONN on Adopt *)
    nonBlocking-: BOOLEAN;
    deadline-: LONGINT;    (* monotonic ms, 0 for none *)
    waiters-: INTEGER      (* SocketTasks calls waiting on it now *)
  END;

END Sockets.
