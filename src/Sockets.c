/* Sockets.c -- the C part of module Sockets (posockets).

   Everything that touches struct sockaddr, getaddrinfo, getnameinfo and
   errno is here; Oberon sees only integers and text (AGENTS.md, "The C
   part"). Each function returns 0 on success or an error code as its
   value, never leaving it in errno for Oberon to fetch, since anything
   Oberon runs in between (the collector, Out) may change errno.

   Text crosses as an address and a length: an open array reaches C as
   its first element's address alone, so Oberon passes LEN(a) beside
   it, and the C side stops at a 0X or at the length, whichever comes
   first, and always terminates what it writes.

   Results: a function returns 0 for success; a positive errno value
   for a system error; WOULD_BLOCK (-1) when a non-blocking socket needs
   a wait (EAGAIN, EWOULDBLOCK, EINPROGRESS), which no errno value can
   be. The functions that resolve names return a kind instead (KIND_*)
   with the code beside it, since a name error's code is getaddrinfo's,
   not an errno value.

   The functions are labelled Sockets.-<name>, so they can't collide with
   C names. */

/* No _POSIX_C_SOURCE: it would hide SOCK_CLOEXEC and accept4 on the
   BSDs, which give them by default. Linux's C libraries declare accept4
   only under _GNU_SOURCE, which also makes glibc's strerror_r the GNU
   one; error_text handles both. */
#ifdef __linux__
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define NAME(n) __asm__("Sockets.-" n)

typedef intptr_t address;

/* Families as Oberon numbers them (Sockets.inet, inet6, unix). */
enum { FAM_INET = 1, FAM_INET6 = 2, FAM_UNIX = 3 };

/* Error kinds as Oberon numbers them (Sockets.system, name). */
enum { KIND_SYSTEM = 1, KIND_NAME = 2 };

/* Not an error kind: Listen found more addresses than Oberon's array
   holds, and *count says how many (Oberon halts). */
enum { TOO_MANY = 99 };

#define WOULD_BLOCK (-1)

static int would_block(int e)
{
	return e == EAGAIN || e == EWOULDBLOCK || e == EINPROGRESS;
}

/* The errno values a caller acts on, by Oberon's index. Their numbers
   differ between systems, so Oberon never writes them down. */
int32_t errno_value(int32_t which) NAME("errno-value");
int32_t errno_value(int32_t which)
{
	switch (which) {
	case 0: return ECONNREFUSED;
	case 1: return ECONNRESET;
	case 2: return EPIPE;
	case 3: return EADDRINUSE;
	case 4: return EMFILE;
	case 5: return ENFILE;
	case 6: return EAFNOSUPPORT;
	case 7: return EADDRNOTAVAIL;
	default: return -1;
	}
}

static size_t bounded_length(const char *s, address len)
{
	return len <= 0 ? 0 : strnlen(s, (size_t)len);
}

/* Writes "<what>: <message>" into text (textlen bytes, terminator
   included), truncating, never overflowing. A system error's message is
   strerror_r's, a name error's gai_strerror's. */
void error_text(int32_t kind, int32_t code, address what, address whatlen,
		address text, address textlen) NAME("error-text");
void error_text(int32_t kind, int32_t code, address what, address whatlen,
		address text, address textlen)
{
	char buf[256];
	const char *msg;

	if (textlen <= 0)
		return;
	if (kind == KIND_NAME) {
		msg = gai_strerror(code);
	} else {
#if defined(__GLIBC__) && defined(_GNU_SOURCE)
		/* glibc's GNU strerror_r returns the message, which need
		   not be in buf. */
		msg = strerror_r(code, buf, sizeof buf);
#else
		/* POSIX's (XSI) strerror_r, which glibc gives without
		   _GNU_SOURCE and the BSDs always give. */
		if (strerror_r(code, buf, sizeof buf) != 0)
			snprintf(buf, sizeof buf, "error %d", (int)code);
		msg = buf;
#endif
	}
	snprintf((char *)text, (size_t)textlen, "%.*s: %s",
		 (int)bounded_length((const char *)what, whatlen),
		 (const char *)what, msg);
}

/* Converts a socket address to a family, numeric host text and port,
   never with a reverse lookup. A Unix-domain address with no name (an
   unbound client) gives an empty host. */
static int32_t from_sockaddr(const struct sockaddr *sa, socklen_t salen,
			     int32_t *family, char *host, size_t hostlen,
			     int32_t *port)
{
	char serv[16];
	int r;

	*port = 0;
	host[0] = '\0';
	switch (sa->sa_family) {
	case AF_UNIX: {
		const struct sockaddr_un *un = (const struct sockaddr_un *)sa;
		size_t off = offsetof(struct sockaddr_un, sun_path);
		size_t n = salen > off ? salen - off : 0;

		*family = FAM_UNIX;
		if (n > sizeof un->sun_path)
			n = sizeof un->sun_path;
		n = strnlen(un->sun_path, n);
		if (n >= hostlen)
			n = hostlen - 1;
		memcpy(host, un->sun_path, n);
		host[n] = '\0';
		return 0;
	}
	case AF_INET:
		*family = FAM_INET;
		break;
	case AF_INET6:
		*family = FAM_INET6;
		break;
	default:
		*family = 0;
		return EAFNOSUPPORT;
	}
	r = getnameinfo(sa, salen, host, (socklen_t)hostlen, serv, sizeof serv,
			NI_NUMERICHOST | NI_NUMERICSERV);
	if (r != 0)
		return r == EAI_SYSTEM ? errno : EAFNOSUPPORT;
	*port = 0;
	for (const char *p = serv; *p >= '0' && *p <= '9'; p++)
		*port = *port * 10 + (*p - '0');
	return 0;
}

/* The socket's own address (which = 0, getsockname) or its peer's
   (which = 1, getpeername). Returns 0, or the errno value. */
int32_t sock_address(int64_t fd, int32_t which, int32_t *family,
		     address host, address hostlen, int32_t *port)
	NAME("sock-address");
int32_t sock_address(int64_t fd, int32_t which, int32_t *family,
		     address host, address hostlen, int32_t *port)
{
	struct sockaddr_storage ss;
	socklen_t len = sizeof ss;
	int r;

	memset(&ss, 0, sizeof ss);
	r = which == 0 ? getsockname((int)fd, (struct sockaddr *)&ss, &len)
		       : getpeername((int)fd, (struct sockaddr *)&ss, &len);
	if (r != 0)
		return errno;
	return from_sockaddr((struct sockaddr *)&ss, len, family, (char *)host,
			     (size_t)hostlen, port);
}

/* socketpair(AF_UNIX, SOCK_STREAM), close-on-exec. fds receives the two
   descriptors. Returns 0, or the errno value. */
int32_t pair(int64_t *fds) NAME("pair");
int32_t pair(int64_t *fds)
{
	int sv[2];

	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0)
		return errno;
	fds[0] = sv[0];
	fds[1] = sv[1];
	return 0;
}

/* Closes fd. Never retried on EINTR: on Linux the descriptor is gone
   either way, and retrying could close one another thread just got.
   Returns 0, or the errno value. */
int32_t close_fd(int64_t fd) NAME("close");
int32_t close_fd(int64_t fd)
{
	return close((int)fd) == 0 ? 0 : errno;
}

/* getaddrinfo(host, port) for a TCP socket into *res. An empty host is
   NULL to getaddrinfo: the wildcard addresses when passive (AI_PASSIVE),
   the loopback ones otherwise. A numeric host is tried first with
   AI_NUMERICHOST, so it never consults a name server. Returns 0, or the
   kind with *code: EAI_SYSTEM is reported as a system error with its
   errno, any other failure as a name error with getaddrinfo's code. */
static int32_t lookup(address host, address hostlen, int32_t port,
		      int passive, struct addrinfo **res, int32_t *code)
{
	char name[NI_MAXHOST], serv[16];
	struct addrinfo hints;
	size_t n = bounded_length((const char *)host, hostlen);
	int r;

	*res = NULL;
	*code = 0;
	if (n >= sizeof name) {
		*code = EAI_NONAME;
		return KIND_NAME;
	}
	memcpy(name, (const char *)host, n);
	name[n] = '\0';
	snprintf(serv, sizeof serv, "%d", (int)port);

	memset(&hints, 0, sizeof hints);
	hints.ai_family = AF_UNSPEC;
	/* Without a socket type each address comes back once per type. */
	hints.ai_socktype = SOCK_STREAM;
	/* No AI_ADDRCONFIG: glibc's ignores loopback addresses, so ::1
	   would vanish on a machine with no other IPv6 address. */
	hints.ai_flags = AI_NUMERICSERV | AI_NUMERICHOST
		| (passive ? AI_PASSIVE : 0);
	r = getaddrinfo(n > 0 ? name : NULL, serv, &hints, res);
	if (r == EAI_NONAME && n > 0) {
		hints.ai_flags &= ~AI_NUMERICHOST;
		r = getaddrinfo(name, serv, &hints, res);
	}
	if (r == 0)
		return 0;
	*res = NULL;
	if (r == EAI_SYSTEM) {
		*code = errno;
		return KIND_SYSTEM;
	}
	*code = r;
	return KIND_NAME;
}

static int inet_family(const struct addrinfo *ai)
{
	return ai->ai_family == AF_INET || ai->ai_family == AF_INET6;
}

/* Writes "<verb> <numeric address> port <port>" into what, for an
   error's text. */
static void describe(const char *verb, const struct sockaddr *sa,
		     socklen_t salen, address what, address whatlen)
{
	char host[NI_MAXHOST];
	int32_t family, port;

	if (whatlen <= 0)
		return;
	if (from_sockaddr(sa, salen, &family, host, sizeof host, &port) != 0)
		snprintf(host, sizeof host, "?");
	snprintf((char *)what, (size_t)whatlen, "%s %s port %d", verb, host,
		 (int)port);
}

/* Resolve: getaddrinfo's TCP addresses for host and port, each written
   as family, numeric host text and port: hosts is max rows of stride
   bytes each. *count receives how many there are, which may be more
   than max (Oberon halts then). Returns 0, or the kind with *code. */
int32_t resolve(address host, address hostlen, int32_t port, int32_t passive,
		int32_t *families, address hosts, address stride,
		int32_t *ports, int32_t max, int32_t *count, int32_t *code)
	NAME("resolve");
int32_t resolve(address host, address hostlen, int32_t port, int32_t passive,
		int32_t *families, address hosts, address stride,
		int32_t *ports, int32_t max, int32_t *count, int32_t *code)
{
	struct addrinfo *res, *ai;
	int32_t kind;
	int i;

	*count = 0;
	kind = lookup(host, hostlen, port, passive, &res, code);
	if (kind != 0)
		return kind;
	i = 0;
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		if (!inet_family(ai))
			continue;
		if (i < max) {
			int e = from_sockaddr(ai->ai_addr, ai->ai_addrlen,
					      &families[i],
					      (char *)hosts + i * stride,
					      (size_t)stride, &ports[i]);
			if (e != 0) {
				freeaddrinfo(res);
				*code = e;
				return KIND_SYSTEM;
			}
		}
		i++;
	}
	freeaddrinfo(res);
	*count = i;
	return 0;
}

static void set_port(struct sockaddr *sa, int port)
{
	if (sa->sa_family == AF_INET)
		((struct sockaddr_in *)sa)->sin_port = htons((uint16_t)port);
	else if (sa->sa_family == AF_INET6)
		((struct sockaddr_in6 *)sa)->sin6_port = htons((uint16_t)port);
}

static int get_port(int fd, int *port)
{
	struct sockaddr_storage ss;
	socklen_t len = sizeof ss;
	int32_t family, p;
	char host[NI_MAXHOST];
	int e;

	if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0)
		return errno;
	e = from_sockaddr((struct sockaddr *)&ss, len, &family, host,
			  sizeof host, &p);
	if (e == 0)
		*port = p;
	return e;
}

static int stream_socket(int family, int nonblock)
{
	return socket(family, SOCK_STREAM | SOCK_CLOEXEC
		      | (nonblock ? SOCK_NONBLOCK : 0), 0);
}

#define MAX_LISTEN 64	/* addresses Listen considers; far more than any host has */
#define LISTEN_TRIES 5	/* fresh starts when port 0's port is taken on a later bind */

/* Listen: one listening socket per TCP address of host (AI_PASSIVE),
   into fds and families, *count of them. Each has SO_REUSEADDR, an IPv6
   one IPV6_V6ONLY, so the families never share a socket (OpenBSD has no
   dual-stack sockets, and the same code then runs everywhere).

   Port 0 gives every socket the same port: the first bind takes the
   kernel's choice, and the rest bind to it. If a later bind finds that
   port taken, everything made is closed and it starts again with port
   0, up to LISTEN_TRIES times.

   For the empty host only, a family that can't be had (EAFNOSUPPORT
   from socket, EADDRNOTAVAIL from bind) is skipped, so a host with IPv6
   disabled still serves IPv4; if every family is skipped, the last
   such error is reported. Any other failure closes what was made.

   Returns 0; TOO_MANY with *count the addresses found, when more than
   max; or the kind with *code, and what saying what failed
   ("bind ::1 port 1965"). */
int32_t listen_on(address host, address hostlen, int32_t port,
		  int32_t backlog, int32_t nonblock, int64_t *fds,
		  int32_t *families, int32_t max, int32_t *count,
		  int32_t *code, address what, address whatlen)
	NAME("listen");
int32_t listen_on(address host, address hostlen, int32_t port,
		  int32_t backlog, int32_t nonblock, int64_t *fds,
		  int32_t *families, int32_t max, int32_t *count,
		  int32_t *code, address what, address whatlen)
{
	struct addrinfo *res, *ai;
	struct addrinfo *addrs[MAX_LISTEN];
	int any = bounded_length((const char *)host, hostlen) == 0;
	int n = 0, made, tries, i, j, one = 1;
	int32_t kind;

	*count = 0;
	kind = lookup(host, hostlen, port, 1, &res, code);
	if (kind != 0)
		return kind;
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		if (!inet_family(ai))
			continue;
		if (n < MAX_LISTEN)
			addrs[n] = ai;
		n++;
	}
	if (n > max || n > MAX_LISTEN) {
		freeaddrinfo(res);
		*count = n;
		return TOO_MANY;
	}
	if (n == 0) {
		freeaddrinfo(res);
		*code = EAFNOSUPPORT;
		snprintf((char *)what, (size_t)whatlen, "listen");
		return KIND_SYSTEM;
	}

	for (tries = 0; tries < LISTEN_TRIES; tries++) {
		int chosen = port, skipped = 0, retry = 0, e = 0;

		made = 0;
		for (i = 0; i < n; i++) {
			struct sockaddr_storage ss;
			const char *verb = "socket";
			int fd;

			ai = addrs[i];
			memcpy(&ss, ai->ai_addr, ai->ai_addrlen);
			set_port((struct sockaddr *)&ss, chosen);
			fd = stream_socket(ai->ai_family, nonblock);
			if (fd < 0) {
				e = errno;
				goto failed;
			}
			verb = "setsockopt";
			if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one,
				       sizeof one) != 0)
				goto failed_fd;
			if (ai->ai_family == AF_INET6
			    && setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one,
					  sizeof one) != 0)
				goto failed_fd;
			verb = "bind";
			if (bind(fd, (struct sockaddr *)&ss, ai->ai_addrlen) != 0)
				goto failed_fd;
			verb = "listen on";
			if (listen(fd, backlog) != 0)
				goto failed_fd;
			if (chosen == 0) {
				verb = "getsockname";
				e = get_port(fd, &chosen);
				if (e != 0) {
					close(fd);
					goto failed;
				}
			}
			fds[made] = fd;
			families[made] = ai->ai_family == AF_INET ? FAM_INET
								  : FAM_INET6;
			made++;
			continue;
		failed_fd:
			e = errno;
			close(fd);
		failed:
			describe(verb, (struct sockaddr *)&ss, ai->ai_addrlen,
				 what, whatlen);
			if (any && (e == EAFNOSUPPORT || e == EADDRNOTAVAIL)) {
				skipped = e;
				continue;
			}
			if (e == EADDRINUSE && port == 0 && made > 0)
				retry = 1;
			break;
		}
		if (i == n && made > 0) {
			freeaddrinfo(res);
			*count = made;
			return 0;
		}
		for (j = 0; j < made; j++)
			close((int)fds[j]);
		if (i == n) {		/* every family skipped */
			e = skipped;
		}
		if (!retry) {
			freeaddrinfo(res);
			*code = e;
			return KIND_SYSTEM;
		}
	}
	freeaddrinfo(res);
	*code = EADDRINUSE;
	return KIND_SYSTEM;
}

/* Errors that belong to the connection being accepted, not to the
   listener: accept(2) on Linux says to treat the network errors like
   EAGAIN and retry, and ECONNABORTED is a client that gave up while
   queued, on every system. */
static int connection_error(int e)
{
	switch (e) {
	case ECONNABORTED:
	case EPROTO:
	case ENETDOWN:
	case ENOPROTOOPT:
	case EHOSTDOWN:
	case EHOSTUNREACH:
	case EOPNOTSUPP:
	case ENETUNREACH:
#ifdef ENONET	/* Linux only */
	case ENONET:
#endif
		return 1;
	default:
		return 0;
	}
}

/* Accept: a connection on listener fd, its descriptor in *newfd and its
   peer's address. accept4 always gets the flags explicitly, since a
   plain accept copies O_NONBLOCK from the listener on the BSDs but not
   on Linux. Retries EINTR and the connection's own errors, so an accept
   loop never stops because one client gave up. EMFILE and ENFILE are
   reported, never retried (PLAN.md, I/O). */
int32_t accept_conn(int64_t fd, int32_t nonblock, int64_t *newfd,
		    int32_t *family, address host, address hostlen,
		    int32_t *port) NAME("accept");
int32_t accept_conn(int64_t fd, int32_t nonblock, int64_t *newfd,
		    int32_t *family, address host, address hostlen,
		    int32_t *port)
{
	struct sockaddr_storage ss;
	socklen_t len;
	int s, e;

	*newfd = -1;
	for (;;) {
		len = sizeof ss;
		memset(&ss, 0, sizeof ss);
		s = accept4((int)fd, (struct sockaddr *)&ss, &len,
			    SOCK_CLOEXEC | (nonblock ? SOCK_NONBLOCK : 0));
		if (s >= 0)
			break;
		e = errno;
		if (e == EINTR || connection_error(e))
			continue;
		return would_block(e) ? WOULD_BLOCK : e;
	}
	e = from_sockaddr((struct sockaddr *)&ss, len, family, (char *)host,
			  (size_t)hostlen, port);
	if (e != 0) {
		close(s);
		return e;
	}
	*newfd = s;
	return 0;
}

/* Waits for a connect that was interrupted or is in progress, and
   gives its outcome: a connect interrupted by a signal goes on in the
   background, and calling it again gives EALREADY or EISCONN. */
static int connect_outcome(int fd)
{
	struct pollfd p;
	int e;
	socklen_t len = sizeof e;

	p.fd = fd;
	p.events = POLLOUT;
	while (poll(&p, 1, -1) < 0)
		if (errno != EINTR)
			return errno;
	if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &len) != 0)
		return errno;
	return e;
}

/* A new socket for ai, connected; blocking unless nonblock, when it
   may come back WOULD_BLOCK with the connection in progress. */
static int connect_one(const struct sockaddr *sa, socklen_t salen,
		       int nonblock, int *fdp)
{
	int fd, e;

	*fdp = -1;
	fd = stream_socket(sa->sa_family, nonblock);
	if (fd < 0)
		return errno;
	if (connect(fd, sa, salen) == 0) {
		*fdp = fd;
		return 0;
	}
	e = errno;
	if (nonblock && (would_block(e) || e == EINTR)) {
		*fdp = fd;
		return WOULD_BLOCK;
	}
	if (e == EINTR)
		e = connect_outcome(fd);
	if (e != 0) {
		close(fd);
		return e;
	}
	*fdp = fd;
	return 0;
}

/* Connect (blocking): tries each TCP address of host in getaddrinfo's
   order until one connects, and reports the last error. Returns 0 with
   *fd and *family; or the kind with *code and what. */
int32_t connect_host(address host, address hostlen, int32_t port,
		     int64_t *fd, int32_t *family, int32_t *code,
		     address what, address whatlen) NAME("connect");
int32_t connect_host(address host, address hostlen, int32_t port,
		     int64_t *fd, int32_t *family, int32_t *code,
		     address what, address whatlen)
{
	struct addrinfo *res, *ai;
	int32_t kind;
	int e = EAFNOSUPPORT, s;

	*fd = -1;
	kind = lookup(host, hostlen, port, 0, &res, code);
	if (kind != 0)
		return kind;
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		if (!inet_family(ai))
			continue;
		e = connect_one(ai->ai_addr, ai->ai_addrlen, 0, &s);
		if (e == 0) {
			*fd = s;
			*family = ai->ai_family == AF_INET ? FAM_INET
							   : FAM_INET6;
			freeaddrinfo(res);
			return 0;
		}
		describe("connect to", ai->ai_addr, ai->ai_addrlen, what,
			 whatlen);
	}
	freeaddrinfo(res);
	*code = e;
	return KIND_SYSTEM;
}

/* ConnectTo: one numeric address, as Resolve gives it. Returns 0 with
   *fd, WOULD_BLOCK with *fd when nonblock and the connection is in
   progress, or the errno value. */
int32_t connect_to(address host, address hostlen, int32_t port,
		   int32_t nonblock, int64_t *fd) NAME("connect-to");
int32_t connect_to(address host, address hostlen, int32_t port,
		   int32_t nonblock, int64_t *fd)
{
	char name[NI_MAXHOST], serv[16];
	struct addrinfo hints, *res;
	size_t n = bounded_length((const char *)host, hostlen);
	int r, s;

	*fd = -1;
	if (n >= sizeof name)
		return EINVAL;
	memcpy(name, (const char *)host, n);
	name[n] = '\0';
	snprintf(serv, sizeof serv, "%d", (int)port);
	memset(&hints, 0, sizeof hints);
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
	r = getaddrinfo(name, serv, &hints, &res);
	if (r != 0)
		return r == EAI_SYSTEM ? errno : EINVAL;
	r = connect_one(res->ai_addr, res->ai_addrlen, nonblock, &s);
	freeaddrinfo(res);
	*fd = s;
	return r;
}

/* FinishConnect: the outcome of a non-blocking connect once its socket
   is writable: 0, the errno value from SO_ERROR, or WOULD_BLOCK if it
   is still in progress (not yet connected, and no error). */
int32_t finish_connect(int64_t fd) NAME("finish-connect");
int32_t finish_connect(int64_t fd)
{
	struct sockaddr_storage ss;
	socklen_t len = sizeof ss;
	int e;
	socklen_t elen = sizeof e;

	if (getsockopt((int)fd, SOL_SOCKET, SO_ERROR, &e, &elen) != 0)
		return errno;
	if (e != 0)
		return e;
	if (getpeername((int)fd, (struct sockaddr *)&ss, &len) != 0)
		return errno == ENOTCONN ? WOULD_BLOCK : errno;
	return 0;
}

/* Read: recv up to len bytes into buf + pos, *n of them. */
int32_t recv_some(int64_t fd, address buf, int64_t pos, int64_t len,
		  int64_t *n) NAME("recv");
int32_t recv_some(int64_t fd, address buf, int64_t pos, int64_t len,
		  int64_t *n)
{
	ssize_t r;

	*n = 0;
	do
		r = recv((int)fd, (char *)buf + pos, (size_t)len, 0);
	while (r < 0 && errno == EINTR);
	if (r < 0)
		return would_block(errno) ? WOULD_BLOCK : errno;
	*n = r;
	return 0;
}

/* Write: send up to len bytes from buf + pos, *n of them. MSG_NOSIGNAL
   makes a write to a closed peer fail with EPIPE instead of raising
   SIGPIPE; Linux and the three BSDs have it. */
int32_t send_some(int64_t fd, address buf, int64_t pos, int64_t len,
		  int64_t *n) NAME("send");
int32_t send_some(int64_t fd, address buf, int64_t pos, int64_t len,
		  int64_t *n)
{
	ssize_t r;

	*n = 0;
	do
		r = send((int)fd, (const char *)buf + pos, (size_t)len,
			 MSG_NOSIGNAL);
	while (r < 0 && errno == EINTR);
	if (r < 0)
		return would_block(errno) ? WOULD_BLOCK : errno;
	*n = r;
	return 0;
}

/* Shutdown: how is 0 (read), 1 (write) or 2 (both). */
int32_t shutdown_fd(int64_t fd, int32_t how) NAME("shutdown");
int32_t shutdown_fd(int64_t fd, int32_t how)
{
	static const int hows[] = { SHUT_RD, SHUT_WR, SHUT_RDWR };

	return shutdown((int)fd, hows[how]) == 0 ? 0 : errno;
}

/* SetNonBlocking: sets or clears O_NONBLOCK. */
int32_t set_nonblocking(int64_t fd, int32_t on) NAME("set-nonblocking");
int32_t set_nonblocking(int64_t fd, int32_t on)
{
	int flags = fcntl((int)fd, F_GETFL);

	if (flags < 0)
		return errno;
	flags = on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK;
	return fcntl((int)fd, F_SETFL, flags) == 0 ? 0 : errno;
}

/* Adopt: what the kernel says of a descriptor made elsewhere: its family
   (getsockname), whether it is listening (SO_ACCEPTCONN) and whether it
   is non-blocking (O_NONBLOCK). ENOTSOCK for a descriptor that isn't a
   socket, EPROTOTYPE for one that isn't a stream socket, EAFNOSUPPORT
   for one of another family. */
int32_t adopt(int64_t fd, int32_t *family, int32_t *listening,
	      int32_t *nonblock) NAME("adopt");
int32_t adopt(int64_t fd, int32_t *family, int32_t *listening,
	      int32_t *nonblock)
{
	struct sockaddr_storage ss;
	socklen_t len = sizeof ss;
	int type, acc, flags;
	socklen_t olen;

	if (getsockname((int)fd, (struct sockaddr *)&ss, &len) != 0)
		return errno;
	switch (ss.ss_family) {
	case AF_INET: *family = FAM_INET; break;
	case AF_INET6: *family = FAM_INET6; break;
	case AF_UNIX: *family = FAM_UNIX; break;
	default: return EAFNOSUPPORT;
	}
	olen = sizeof type;
	if (getsockopt((int)fd, SOL_SOCKET, SO_TYPE, &type, &olen) != 0)
		return errno;
	if (type != SOCK_STREAM)
		return EPROTOTYPE;
	olen = sizeof acc;
	if (getsockopt((int)fd, SOL_SOCKET, SO_ACCEPTCONN, &acc, &olen) != 0)
		return errno;
	flags = fcntl((int)fd, F_GETFL);
	if (flags < 0)
		return errno;
	*listening = acc != 0;
	*nonblock = (flags & O_NONBLOCK) != 0;
	return 0;
}

/* IgnoreBrokenPipe: SIGPIPE ignored, process-wide. */
int32_t ignore_sigpipe(void) NAME("ignore-sigpipe");
int32_t ignore_sigpipe(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof sa);
	sa.sa_handler = SIG_IGN;
	sigemptyset(&sa.sa_mask);
	return sigaction(SIGPIPE, &sa, NULL) == 0 ? 0 : errno;
}

/* The monotonic clock in milliseconds, for deadlines: it never goes back
   when the time of day is set. */
int64_t now(void) NAME("now");
int64_t now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
