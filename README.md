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

**Status: early.** Phases 1 and 2 of [PLAN.md](PLAN.md) are done:
the build and tests, errors, addresses as text, resolving names
(`Resolve`), and socket pairs (`Pair`, `Close`, `LocalAddress`,
`PeerAddress`). Listening, accepting, connecting and I/O come next. PLAN.md has the design and the
roadmap; [AGENTS.md](AGENTS.md) has the working notes.

## Requirements

- poc 0.12.0 or later, on Linux. The BSDs that poc supports are to
  follow (PLAN.md, Phase 9).
- Deadlines (Phase 5) need `Tasks.AwaitReadableFor`, which is in
  Peaseblossom's source but in no poc release yet.
- valgrind, for `make valgrind`.

The library links nothing beyond the C library, so a program using it
needs no extra flags.

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
