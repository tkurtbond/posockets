MODULE Run; (* Starting a program in the background, for a test to drive *)

(* A test starts an example with Start(cmd, name), from test/: the
   command runs in the background, its standard output in
   ../build/<name>.out, its standard error in ../build/<name>.err, and
   when it ends its exit status in ../build/<name>.status. The test
   meanwhile talks to it over a socket, and learns how it ended with
   Wait. Stop kills it if it is still running, so a failed check never
   leaves it behind. Waiting is by Tasks.Sleep, so other tasks run. *)

IMPORT SYSTEM, Platform, Tasks, Sockets;

CONST Poll = 10;            (* ms between looks at a file *)

TYPE Bytes* = POINTER TO ARRAY OF CHAR;

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  j := 0;
  WHILE (j < LEN(t)) & (t[j] # 0X) & (i < LEN(s) - 1) DO
    s[i] := t[j]; INC(i); INC(j)
  END;
  s[i] := 0X
END Append;

(* "../build/<name><suffix>" *)
PROCEDURE File*(name, suffix: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
BEGIN
  COPY("../build/", path); Append(path, name); Append(path, suffix)
END File;

PROCEDURE Remove(name, suffix: ARRAY OF CHAR);
  VAR path: ARRAY 256 OF CHAR; e: Platform.ErrorCode;
BEGIN
  File(name, suffix, path); e := Platform.Unlink(path)
END Remove;

(* The whole of the file at path, or NIL if it can't be read. *)
PROCEDURE Read*(path: ARRAY OF CHAR): Bytes;
  VAR h: Platform.FileHandle; size, n, got: LONGINT; b: Bytes;
    e: Platform.ErrorCode; name: ARRAY 256 OF CHAR;
BEGIN
  COPY(path, name);
  IF Platform.OldRO(name, h) # 0 THEN RETURN NIL END;
  IF Platform.Size(h, size) # 0 THEN e := Platform.Close(h); RETURN NIL END;
  NEW(b, size + 1); got := 0;
  WHILE (got < size)
    & (Platform.Read(h, SYSTEM.ADR(b[got]), size - got, n) = 0) & (n > 0) DO
    got := got + n
  END;
  e := Platform.Close(h);
  IF got # size THEN RETURN NIL END;
  b[size] := 0X;
  RETURN b
END Read;

(* Starts cmd (a shell command, with any redirection of its standard
   input) in the background as name. *)
PROCEDURE Start*(cmd, name: ARRAY OF CHAR);
  VAR line: ARRAY 1024 OF CHAR; path: ARRAY 256 OF CHAR; r: INTEGER;
BEGIN
  Remove(name, ".out"); Remove(name, ".err"); Remove(name, ".status");
  Remove(name, ".pid");
  (* The status is written to a temporary file and renamed, so Wait never
     reads half of it. *)
  line := "( "; Append(line, cmd); Append(line, " & echo $! > ");
  File(name, ".pid", path); Append(line, path);
  Append(line, "; wait $!; echo $? > "); File(name, ".tmp", path);
  Append(line, path); Append(line, "; mv "); Append(line, path);
  Append(line, " "); File(name, ".status", path); Append(line, path);
  Append(line, " ) > "); File(name, ".out", path); Append(line, path);
  Append(line, " 2> "); File(name, ".err", path); Append(line, path);
  Append(line, " &");
  r := Platform.System(line)
END Start;

(* Waits at most ms for name to end; status is its exit status. *)
PROCEDURE Wait*(name: ARRAY OF CHAR; ms: LONGINT; VAR status: INTEGER): BOOLEAN;
  VAR path: ARRAY 256 OF CHAR; b: Bytes; end: LONGINT; i: INTEGER;
BEGIN
  File(name, ".status", path); end := Sockets.Now() + ms;
  LOOP
    b := Read(path);
    IF (b # NIL) & (b[0] >= "0") & (b[0] <= "9") THEN EXIT END;
    IF Sockets.Now() > end THEN RETURN FALSE END;
    Tasks.Sleep(Poll)
  END;
  status := 0; i := 0;
  WHILE (b[i] >= "0") & (b[i] <= "9") DO
    status := status * 10 + ORD(b[i]) - ORD("0"); INC(i)
  END;
  RETURN TRUE
END Wait;

(* Waits at most ms for the file at path to hold prefix followed by a
   number and a line end; n is the number. *)
PROCEDURE Number*(path, prefix: ARRAY OF CHAR; ms: LONGINT; VAR n: LONGINT): BOOLEAN;
  VAR b: Bytes; end: LONGINT; i, j: LONGINT;
BEGIN
  end := Sockets.Now() + ms;
  LOOP
    b := Read(path);
    IF b # NIL THEN
      i := 0;
      WHILE (prefix[i] # 0X) & (b[i] = prefix[i]) DO INC(i) END;
      IF prefix[i] = 0X THEN
        j := i; n := 0;
        WHILE (b[j] >= "0") & (b[j] <= "9") DO
          n := n * 10 + ORD(b[j]) - ORD("0"); INC(j)
        END;
        IF (j > i) & (b[j] = 0AX) THEN RETURN TRUE END
      END
    END;
    IF Sockets.Now() > end THEN RETURN FALSE END;
    Tasks.Sleep(Poll)
  END
END Number;

(* Kills name if it has not ended. *)
PROCEDURE Stop*(name: ARRAY OF CHAR);
  VAR path, cmd: ARRAY 256 OF CHAR; b: Bytes; r: INTEGER;
BEGIN
  File(name, ".status", path);
  IF Read(path) # NIL THEN RETURN END;
  File(name, ".pid", path); b := Read(path);
  IF b # NIL THEN
    cmd := "kill $(cat "; Append(cmd, path); Append(cmd, ") 2>/dev/null");
    r := Platform.System(cmd)
  END
END Stop;

(* Whether the file at path holds exactly text. *)
PROCEDURE Holds*(path, text: ARRAY OF CHAR): BOOLEAN;
  VAR b: Bytes; i: LONGINT;
BEGIN
  b := Read(path);
  IF b = NIL THEN RETURN FALSE END;
  i := 0;
  WHILE (i < LEN(text)) & (text[i] # 0X) DO
    IF b[i] # text[i] THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN i = LEN(b^) - 1
END Holds;

END Run.
