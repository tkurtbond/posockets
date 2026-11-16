# posockets - TCP and Unix-domain sockets for poc

This project is developed with the use of AI.

An Oberon-2 library of TCP and Unix-domain sockets for poc, the
[Peaseblossom](https://github.com/tkurtbond/peaseblossom) Oberon
compiler, whose runtime has none. It works with poc's cooperative
`Tasks`, so one OS thread can serve many connections, and it hands out
plain descriptors, so other libraries (such as polibtls, a binding to
libtls) can run over its sockets without importing it.

It is planned to offer:

- TCP over IPv4 and IPv6: listen, accept, connect, read, write,
  shutdown and close, with local and peer addresses as text;
- host names resolved with `getaddrinfo`;
- Unix-domain stream sockets and socket pairs;
- blocking calls for simple programs, and non-blocking calls that wait
  through `Tasks` (module `SocketTasks`), with deadlines;
- errors from the network or the system returned as a result, never a
  halt.

**Status: early.** Phases 1 to 6 of [PLAN.md](PLAN.md) are done:
the build and tests, errors, addresses as text, resolving names, socket
pairs, and blocking TCP over IPv4 and IPv6 (`Listen`, `Accept`,
`Connect`, `Read`, `Write`, `WriteAll`, `Shutdown`, `Close`), with
non-blocking sockets, and `SocketTasks`, which waits through poc's
`Tasks` so one thread serves many connections, with deadlines on its
waits, time limits on connecting, and a lingering close; and
Unix-domain stream sockets (`ListenUnix`, `ConnectUnix`). Socket
options come next. PLAN.md has the design and the
roadmap; [AGENTS.md](AGENTS.md) has the working notes.

## Requirements

- A poc newer than 0.12.0, on Linux: the deadlines need
  `Tasks.AwaitReadableFor`, which is in Peaseblossom's source but in
  no poc release yet, so for now build poc from that source and pass
  it to make (`make test POC=/path/to/poc`). poc 0.12.0 builds the
  Phase 4 version (commit 72e218a). The BSDs that poc supports are to
  follow (PLAN.md, Phase 9).
- valgrind, for `make valgrind`.

The library links nothing beyond the C library, so a program using it
needs no extra flags.

Two things a program using `SocketTasks` meets that come from poc's
`Tasks`, not from posockets:

- valgrind's memcheck can't follow poc's coroutines (as of poc 0.12.0)
  and reports thousands of errors that aren't the program's. Use
  `valgrind --tool=none --track-fds=yes` to check for descriptors left
  open.
- `Tasks` keeps two descriptors of its own (a self-pipe) open until the
  program ends, so a check for leaked descriptors should allow for
  them.

## Unix-domain sockets

- **The socket file stays.** `ListenUnix` creates a file at its path,
  and closing the listener leaves it there. posockets never removes a
  file: the program removes it (`Files.Delete`, `Platform.Unlink`),
  and a server that knows a leftover file is its own removes it before
  `ListenUnix`, which otherwise fails with `EADDRINUSE`.
- **A connect doesn't wait for the accept.** It is queued at once.
  Only a full listen queue holds it back. Then, on Linux, a blocking
  `Sockets.ConnectUnix` waits for room, and a non-blocking one fails
  with `EAGAIN` and no socket, with nothing to wait on.
  `SocketTasks.ConnectUnix` retries for you, sleeping from 1 ms
  doubling to 64 ms, until there is room or its time limit passes.
- **Other failures come back at once:** `ENOENT` when there is no file
  at the path, `ECONNREFUSED` when the file is a stale socket with no
  listener.
- **A path is at most 107 bytes on Linux** (103 on the BSDs). A longer
  one, or an empty one, is a programmer error and halts.
- **The peer of an accepted connection is usually unnamed**: its
  address has family `unix` and an empty host.

The comments in `src/Sockets.Mod` and `src/SocketTasks.Mod` are the
reference for each procedure.

## Building

```sh
make              # build the library in build/lib and the tests
make test         # run the tests and the halt tests
make valgrind     # run the tests under valgrind, checking for leaked
                  #   memory and descriptors left open
make install      # install into ~/.local/lib/poc (POCLIBDIR=... to change)
make uninstall
make clean
```

A program then compiles against the installed library with
`poc -OC -library-path ~/.local/lib/poc Program.Mod`. The library is
built for poc's `-OC` size model only.

## License

BSD 3-Clause; see [LICENSE](LICENSE).
