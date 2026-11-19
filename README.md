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

**Status: early.** Phases 1 to 6, 8, 9 and 10 of [PLAN.md](PLAN.md) are done:
the build and tests, errors, addresses as text, resolving names, socket
pairs, and blocking TCP over IPv4 and IPv6 (`Listen`, `Accept`,
`Connect`, `Read`, `Write`, `WriteAll`, `Shutdown`, `Close`), with
non-blocking sockets, and `SocketTasks`, which waits through poc's
`Tasks` so one thread serves many connections, with deadlines on its
waits, time limits on connecting, and a lingering close; and
Unix-domain stream sockets (`ListenUnix`, `ConnectUnix`); and
examples and a reference; and deadlines without tasks (`Await`,
`ConnectWithin`), for a blocking program that bounds each wait; on Linux, FreeBSD, OpenBSD and NetBSD.
Socket options wait for a program that needs them. PLAN.md has the design and the
roadmap; [AGENTS.md](AGENTS.md) has the working notes.

## Requirements

- poc 0.13.0 or later: the deadlines need `Tasks.AwaitReadableFor`.
  poc 0.12.0 builds the Phase 4 version (commit 72e218a).
- [poDateTime](https://github.com/tkurtbond/poDateTime), installed by
  the same poc, for its monotonic clock, which `Sockets.Now` and the
  deadlines read. make looks for it where it installs posockets, in
  `~/.local/lib/poc`; give `make PODATETIME=<dir>` if it is elsewhere.
  Without it, make stops, saying so.
- Linux, FreeBSD, OpenBSD or NetBSD, on amd64 or i386: tested on
  Fedora 44, FreeBSD 15.1, OpenBSD 7.9 and NetBSD 11.0 (PLAN.md,
  Phase 9). On the BSDs, build with GNU make (`gmake`).
- valgrind, for `make valgrind` (Linux).

The library links nothing beyond the C library and poDateTime, so a
program using it needs no extra flags.

Two things a program using `SocketTasks` meets that come from poc's
`Tasks`, not from posockets:

- `Tasks` keeps two descriptors of its own (a self-pipe) open until the
  program ends, so a check for leaked descriptors should allow for
  them.
- valgrind 3.27.1 counts each descriptor open at exit as an error
  under `--track-fds=yes`, so the self-pipe alone fails
  `--error-exitcode`; `test/vg-errors.sh` compares the errors with the
  descriptors instead. memcheck itself follows poc's coroutines (since
  Peaseblossom's bug 21 was fixed, 2026-11-15).

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
  On FreeBSD and NetBSD a full queue refuses the connect at once with
  `ECONNREFUSED`, which can't be told from a stale socket file, so
  nothing retries it there; give a listener a backlog to suit its
  clients. OpenBSD queued every connection tried, 150 with backlog 0.
- **Other failures come back at once:** `ENOENT` when there is no file
  at the path, `ECONNREFUSED` when the file is a stale socket with no
  listener.
- **A path is at most 107 bytes on Linux** (103 on the BSDs). A longer
  one, or an empty one, is a programmer error and halts.
- **The peer of an accepted connection is usually unnamed**: its
  address has family `unix` and an empty host.

## Differences between systems

Found in porting (PLAN.md, Phase 9); the library hides none of them,
since each is the system's own answer:

- **A TCP connect to a full listen queue** hangs on Linux, OpenBSD and
  NetBSD until its time limit (the SYN is dropped); on FreeBSD it fails
  at once with `ECONNRESET`. How many connections a backlog of 0
  queues differs too: one on Linux and NetBSD, two on FreeBSD, 81 on
  OpenBSD (`kern.sominconn`).
- **A Unix-domain connect to a full queue**: see above.
- **The BSDs' loopback delivers data a moment after `send` returns**;
  Linux's has it there already. A program that writes and then, with
  its deadline passed, reads at once on the other end may find nothing
  yet.
- **The NetBSD resolver keeps a descriptor** (a `kqueue`) after a
  lookup that asks a name server, as glibc keeps the NSS modules'
  memory.

## Reference

[doc/Sockets.md](doc/Sockets.md) and
[doc/SocketTasks.md](doc/SocketTasks.md) describe every exported
constant, type and procedure. They are made from the comments in
`src/Sockets.Mod` and `src/SocketTasks.Mod` by `make doc`, so the
source and the reference say the same thing.

## Examples

`make` builds these into `build/`, and `make test` runs each against
a peer of its own. A server prints `port <n>` as its first line, so
port 0 (one the kernel chooses) is easy to use; with a count, it serves
that many connections and exits, and without one it serves until
killed.

- **`EchoServer port [count [idle-ms]]`** sends back what each client
  sends, one task per connection, and closes a client silent for idle
  ms (default 30000). **`EchoClient host port word...`** is the
  smallest client: blocking calls only.

  ```sh
  build/EchoServer 7000 &
  build/EchoClient localhost 7000 hello there
  ```

- **`Netcat`** copies standard input to a connection and the
  connection to standard output, ending its side when standard input
  ends: `Netcat host port`, `Netcat -U path`, or listening for one
  connection, `Netcat -l host port` and `Netcat -l -U path`.

  ```sh
  build/Netcat -l -U /run/user/$UID/demo.sock > got &
  build/Netcat -U /run/user/$UID/demo.sock < some-file
  ```

- **`Forward port host target-port [count [idle-ms]]`** forwards each
  connection on port to host and target-port, two tasks per connection
  copying each way, and closes a connection that has been idle both
  ways for idle ms (default 300000).

  ```sh
  build/Forward 8080 example.org 80 &
  curl -H 'Host: example.org' http://localhost:8080/
  ```

- **`FileServer port dir [count [timeout-ms]]`** serves the files in
  dir over HTTP/1.0: `GET` and `HEAD`, a few content types by
  extension, a path ending in `/` giving its `index.html`, and 400,
  404 and 405 for the rest. It refuses `..`, and drops a client that
  sends no request within the timeout (default 10000 ms). It is a
  demonstration, not for the open internet: it follows symbolic links
  and has no limit on connections.

  ```sh
  build/FileServer 8000 ~/public_html &
  curl -i http://localhost:8000/index.html
  ```

The comment at the top of each example says what it shows.

## Building

```sh
make              # build the library in build/lib and the tests
make test         # run the tests and the halt tests
make valgrind     # run the tests under valgrind, checking for leaked
                  #   memory and descriptors left open
make doc          # remake doc/ from the comments in src/
make install      # install into ~/.local/lib/poc (POCLIBDIR=... to change)
make uninstall
make clean
```

A program then compiles against the installed library with
`poc -OC -library-path ~/.local/lib/poc Program.Mod`. poDateTime must
be on the library path too (it is, installed in the same place). The
library is built for poc's `-OC` size model only. A library works only
with the poc that built it, so install again after upgrading poc.

## License

BSD 3-Clause; see [LICENSE](LICENSE).
