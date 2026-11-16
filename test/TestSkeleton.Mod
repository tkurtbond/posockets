MODULE TestSkeleton; (* Phase 1: the library builds and a program links it *)

(* Replaced by the real tests as the phases add them (PLAN.md,
   "Testing"). *)

IMPORT Sockets, Check;

BEGIN
  Check.Check((Sockets.inet # Sockets.inet6) & (Sockets.inet6 # Sockets.unix)
    & (Sockets.inet # Sockets.unix), "the families are distinct");
  Check.Check((Sockets.AssertClosed = 80) & (Sockets.AssertWaiting = 86),
    "the halt codes are posockets' 80..89");
  Check.Summary
END TestSkeleton.
