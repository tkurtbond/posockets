/* TestHelp.c -- the C part of TestHelp: what the tests need from the
   system that posockets doesn't offer (PLAN.md, "Testing"). */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define NAME(n) __asm__("TestHelp.-" n)

/* 1 if fd becomes readable (write = 0) or writable (write = 1) within
   ms, 0 if not, -1 on error. */
int32_t wait_fd(int64_t fd, int32_t write, int32_t ms) NAME("wait");
int32_t wait_fd(int64_t fd, int32_t write, int32_t ms)
{
	struct pollfd p;
	int r;

	p.fd = (int)fd;
	p.events = write ? POLLOUT : POLLIN;
	do
		r = poll(&p, 1, ms);
	while (r < 0 && errno == EINTR);
	return r < 0 ? -1 : r > 0;
}

/* A close-on-exec duplicate of fd, or -1. */
int64_t dup_fd(int64_t fd) NAME("dup");
int64_t dup_fd(int64_t fd)
{
	return fcntl((int)fd, F_DUPFD_CLOEXEC, 3);
}

/* SO_LINGER on with a zero timeout: closing fd then sends RST, not FIN. */
int32_t reset_on_close(int64_t fd) NAME("reset-on-close");
int32_t reset_on_close(int64_t fd)
{
	struct linger l;

	l.l_onoff = 1;
	l.l_linger = 0;
	return setsockopt((int)fd, SOL_SOCKET, SO_LINGER, &l, sizeof l);
}

/* Asks for a buffer of bytes on fd: the send buffer if receive is 0,
   otherwise the receive buffer. The kernel may round up (Linux doubles
   it, and has a minimum). */
int32_t small_buffer(int64_t fd, int32_t bytes, int32_t receive) NAME("small-buffer");
int32_t small_buffer(int64_t fd, int32_t bytes, int32_t receive)
{
	int b = bytes;

	return setsockopt((int)fd, SOL_SOCKET, receive ? SO_RCVBUF : SO_SNDBUF,
	    &b, sizeof b);
}

/* sun_path's size, its terminator included: 108 on Linux, 104 on the
   BSDs. */
int32_t unix_path_max(void) NAME("unix-path-max");
int32_t unix_path_max(void)
{
	return (int32_t)sizeof ((struct sockaddr_un *)0)->sun_path;
}

/* RLIMIT_NOFILE's soft limit, or -1. */
int64_t file_limit(void) NAME("file-limit");
int64_t file_limit(void)
{
	struct rlimit r;

	if (getrlimit(RLIMIT_NOFILE, &r) != 0)
		return -1;
	return r.rlim_cur == RLIM_INFINITY ? INT64_MAX : (int64_t)r.rlim_cur;
}

/* Sets RLIMIT_NOFILE's soft limit; 0, or -1. */
int32_t set_file_limit(int64_t n) NAME("set-file-limit");
int32_t set_file_limit(int64_t n)
{
	struct rlimit r;

	if (getrlimit(RLIMIT_NOFILE, &r) != 0)
		return -1;
	r.rlim_cur = (rlim_t)n;
	return setrlimit(RLIMIT_NOFILE, &r);
}

/* The number of descriptors open: those below the soft RLIMIT_NOFILE
   (at most MAX_FDS) that fcntl knows. Portable, unlike /proc/self/fd,
   which FreeBSD and OpenBSD don't have. A test's descriptors are the
   lowest free numbers, far below the cap. */
#define MAX_FDS 65536
int32_t open_fds(void) NAME("open-fds");
int32_t open_fds(void)
{
	struct rlimit r;
	long fd, top = MAX_FDS;
	int32_t n = 0;

	if (getrlimit(RLIMIT_NOFILE, &r) == 0 && r.rlim_cur != RLIM_INFINITY
	    && r.rlim_cur < (rlim_t)top)
		top = (long)r.rlim_cur;
	for (fd = 0; fd < top; fd++)
		if (fcntl((int)fd, F_GETFD) != -1)
			n++;
	return n;
}

/* /dev/null opened for reading, close-on-exec: a descriptor that isn't
   a socket. -1 on error. */
int64_t open_null(void) NAME("open-null");
int64_t open_null(void)
{
	return open("/dev/null", O_RDONLY | O_CLOEXEC);
}

int32_t close_fd(int64_t fd) NAME("close");
int32_t close_fd(int64_t fd)
{
	return close((int)fd);
}
