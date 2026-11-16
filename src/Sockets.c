/* Sockets.c -- the C part of module Sockets (posockets).

   Everything that touches struct sockaddr, getaddrinfo, getnameinfo and
   errno is here; Oberon sees only integers and text (AGENTS.md, "The C
   part"). Each function returns 0 on success or an error code as its
   value, never leaving it in errno for Oberon to fetch, since anything
   Oberon runs in between (the collector, Out) may change errno.

   Text crosses as an address and a length: Oberon passes
   SYSTEM.ADR(a[0]) and LEN(a), and the C side stops at a 0X or at the
   length, whichever comes first, and always terminates what it writes.

   The functions are labelled Sockets.-<name>, so they can't collide with
   C names. */

/* No feature macros: _POSIX_C_SOURCE would hide SOCK_CLOEXEC on the
   BSDs. strerror_r is then the XSI one on glibc unless the compiler
   defines _GNU_SOURCE, which error_text handles too. */

#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stddef.h>
#include <stdint.h>
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

/* getaddrinfo(host, port) for SOCK_STREAM, each result written as
   family, numeric host text and port: hosts is max rows of stride
   bytes each. *count receives how many results there are, which may be
   more than max (Oberon halts then). passive adds AI_PASSIVE. An empty
   host is NULL to getaddrinfo: the wildcard addresses when passive, the
   loopback ones otherwise. A numeric host is tried first with
   AI_NUMERICHOST, so it never consults a name server.

   Returns 0; or the kind (KIND_SYSTEM or KIND_NAME) with *code the
   errno value or EAI_ code. EAI_SYSTEM is reported as a system error
   with its errno. */
int32_t resolve(address host, address hostlen, int32_t port, int32_t passive,
		int32_t *families, address hosts, address stride,
		int32_t *ports, int32_t max, int32_t *count, int32_t *code)
	NAME("resolve");
int32_t resolve(address host, address hostlen, int32_t port, int32_t passive,
		int32_t *families, address hosts, address stride,
		int32_t *ports, int32_t max, int32_t *count, int32_t *code)
{
	char name[NI_MAXHOST], serv[16];
	struct addrinfo hints, *res, *ai;
	size_t n = bounded_length((const char *)host, hostlen);
	int r, i;

	*count = 0;
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
	hints.ai_flags = AI_NUMERICSERV | AI_NUMERICHOST
		| (passive ? AI_PASSIVE : 0);
	r = getaddrinfo(n > 0 ? name : NULL, serv, &hints, &res);
	if (r == EAI_NONAME && n > 0) {
		hints.ai_flags &= ~AI_NUMERICHOST;
		r = getaddrinfo(name, serv, &hints, &res);
	}
	if (r != 0) {
		if (r == EAI_SYSTEM) {
			*code = errno;
			return KIND_SYSTEM;
		}
		*code = r;
		return KIND_NAME;
	}
	i = 0;
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		int32_t fam;

		if (ai->ai_family != AF_INET && ai->ai_family != AF_INET6)
			continue;
		if (i < max) {
			int e = from_sockaddr(ai->ai_addr, ai->ai_addrlen, &fam,
					      (char *)hosts + i * stride,
					      (size_t)stride, &ports[i]);
			if (e != 0) {
				freeaddrinfo(res);
				*code = e;
				return KIND_SYSTEM;
			}
			families[i] = fam;
		}
		i++;
	}
	freeaddrinfo(res);
	*count = i;
	return 0;
}
