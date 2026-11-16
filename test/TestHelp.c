/* TestHelp.c -- the C part of TestHelp: what the tests need from the
   system that posockets doesn't offer (PLAN.md, "Testing"). Linux only
   for now: OpenFds reads /proc/self/fd. */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <sys/resource.h>
#include <sys/socket.h>
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

/* The number of descriptors open, from /proc/self/fd, not counting the
   one opendir uses; -1 on error. */
int32_t open_fds(void) NAME("open-fds");
int32_t open_fds(void)
{
	DIR *d = opendir("/proc/self/fd");
	struct dirent *e;
	int n = 0;

	if (d == NULL)
		return -1;
	while ((e = readdir(d)) != NULL)
		if (e->d_name[0] != '.')
			n++;
	closedir(d);
	return n - 1;
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
