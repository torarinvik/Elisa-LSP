/* One-shot POSIX process boundary for isolated Elisa analysis. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif

/* Supplied by transport_posix.c in the LSP executable. */
extern int elisa_lsp_pending_termination_signal(void);

enum { WORKER_POLL_SLICE_MS = 25, WORKER_PIPE_FD = 3 };
enum {
    ELISA_LSP_EVENT_INPUT = 1,
    ELISA_LSP_EVENT_WORKER = 2,
    ELISA_LSP_EVENT_TERMINATION = 4,
    ELISA_LSP_EVENT_WORKER_DEADLINE = 8,
    /* read_available() returned EOF; wait_event() now watches child exit. */
    ELISA_LSP_EVENT_WORKER_EOF = 16
};

static int worker_active = 0;
static int worker_is_child = 0;
static pid_t worker_pid = -1;
static int worker_read_fd = -1;
static int worker_write_fd = -1;
static int worker_eof_seen = 0;
static int worker_reaped = 0;
static int worker_status = 0;
static struct timespec worker_deadline;

void elisa_lsp_analysis_worker_abort(void);
static int termination_is_pending(void);

static int make_deadline(struct timespec *deadline, int64_t timeout_ms) {
    if (clock_gettime(CLOCK_MONOTONIC, deadline) != 0) return -1;
    deadline->tv_sec += (time_t)(timeout_ms / 1000);
    deadline->tv_nsec += (long)((timeout_ms % 1000) * 1000000);
    if (deadline->tv_nsec >= 1000000000L) {
        deadline->tv_sec += 1;
        deadline->tv_nsec -= 1000000000L;
    }
    return 0;
}

/* Return 1 with a remaining time, 0 after the deadline, and -1 on clock error. */
static int deadline_remaining(const struct timespec *deadline,
                              struct timespec *remaining) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    remaining->tv_sec = deadline->tv_sec - now.tv_sec;
    remaining->tv_nsec = deadline->tv_nsec - now.tv_nsec;
    if (remaining->tv_nsec < 0) {
        remaining->tv_sec -= 1;
        remaining->tv_nsec += 1000000000L;
    }
    if (remaining->tv_sec < 0 ||
        (remaining->tv_sec == 0 && remaining->tv_nsec == 0)) {
        errno = ETIMEDOUT;
        return 0;
    }
    return 1;
}

static int timeout_until_deadline(const struct timespec *deadline,
                                  int *timeout_ms) {
    struct timespec remaining;
    int result = deadline_remaining(deadline, &remaining);
    if (result <= 0) return result;

    int64_t rounded_ms = (int64_t)remaining.tv_sec * 1000 +
                         ((int64_t)remaining.tv_nsec + 999999) / 1000000;
    if (rounded_ms < 1) rounded_ms = 1;
    if (rounded_ms > INT_MAX) rounded_ms = INT_MAX;
    *timeout_ms = (int)rounded_ms;
    return 1;
}

static int poll_timeout_for(const struct timespec *deadline, int *timeout_ms) {
    int result = timeout_until_deadline(deadline, timeout_ms);
    if (result <= 0) return result;
    if (*timeout_ms > WORKER_POLL_SLICE_MS) {
        *timeout_ms = WORKER_POLL_SLICE_MS;
    }
    return 1;
}

static void reset_worker_state(void) {
    worker_active = 0;
    worker_is_child = 0;
    worker_pid = -1;
    worker_read_fd = -1;
    worker_write_fd = -1;
    worker_eof_seen = 0;
    worker_reaped = 0;
    worker_status = 0;
    worker_deadline.tv_sec = 0;
    worker_deadline.tv_nsec = 0;
}

static void close_fd_once(int *fd) {
    if (*fd < 0) return;
    int closing = *fd;
    *fd = -1;
    (void)close(closing);
}

static void close_pipe_pair(int pipe_fds[2]) {
    close_fd_once(&pipe_fds[0]);
    close_fd_once(&pipe_fds[1]);
}

/* Reap an already-exited child, or force-stop a live one before reaping it. */
static void kill_and_reap(pid_t child) {
    if (child <= 0) return;

    int status = 0;
    for (;;) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno == ECHILD)) return;
        if (waited < 0 && errno == EINTR) continue;
        if (waited < 0) return;
        break;
    }

    if (kill(child, SIGKILL) != 0 && errno != ESRCH) {
        /* The subsequent wait still handles a child that exited meanwhile. */
    }
    for (;;) {
        pid_t waited = waitpid(child, &status, 0);
        if (waited == child || (waited < 0 && errno == ECHILD)) return;
        if (waited < 0 && errno == EINTR) continue;
        return;
    }
}

static int move_pipe_fd_above_stdio(int *fd) {
    if (*fd >= 3) return 0;
    int moved = fcntl(*fd, F_DUPFD, 3);
    if (moved < 0) return -1;

    int original = *fd;
    if (close(original) != 0) {
        int saved_errno = errno;
        (void)close(moved);
        errno = saved_errno;
        return -1;
    }
    *fd = moved;
    return 0;
}

static int set_close_on_exec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int reset_child_termination_signals(void) {
    const int signals[] = {SIGINT, SIGTERM, SIGHUP};
    sigset_t unblocked;
    if (sigemptyset(&unblocked) != 0) return -1;

    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    action.sa_flags = 0;
    if (sigemptyset(&action.sa_mask) != 0) return -1;

    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        if (sigaction(signals[i], &action, NULL) != 0) return -1;
        if (sigaddset(&unblocked, signals[i]) != 0) return -1;
    }
    return sigprocmask(SIG_UNBLOCK, &unblocked, NULL);
}

static int descriptor_number(const char *name, int *number) {
    if (*name == '\0') return 0;
    int value = 0;
    for (const unsigned char *p = (const unsigned char *)name; *p != '\0'; ++p) {
        if (*p < '0' || *p > '9') return 0;
        int digit = (int)(*p - '0');
        if (value > INT_MAX / 10 ||
            (value == INT_MAX / 10 && digit > INT_MAX % 10)) return 0;
        value = value * 10 + digit;
    }
    *number = value;
    return 1;
}

/* /dev/fd lists open descriptors on Darwin and Linux, avoiding a million
 * close(2) calls when the process descriptor limit is unusually high. */
static int close_descriptors_from_directory(const char *path) {
    DIR *directory = opendir(path);
    if (directory == NULL) return -1;
    int directory_fd = dirfd(directory);
    if (directory_fd < 0) {
        int saved_errno = errno;
        (void)closedir(directory);
        errno = saved_errno;
        return -1;
    }

    int first_error = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) first_error = errno;
            break;
        }
        int fd = -1;
        if (!descriptor_number(entry->d_name, &fd) ||
            fd < WORKER_PIPE_FD + 1 || fd == directory_fd) continue;
        if (close(fd) != 0 && errno != EBADF) {
            first_error = errno;
            break;
        }
    }

    if (closedir(directory) != 0 && first_error == 0) first_error = errno;
    if (first_error != 0) {
        errno = first_error;
        return -1;
    }
    return 0;
}

static int close_inherited_descriptors(void) {
#if defined(__linux__) && defined(SYS_close_range)
    if (syscall(SYS_close_range, (unsigned int)(WORKER_PIPE_FD + 1),
                UINT_MAX, 0u) == 0) return 0;
#endif

    if (close_descriptors_from_directory("/dev/fd") == 0) return 0;
#if defined(__linux__)
    if (close_descriptors_from_directory("/proc/self/fd") == 0) return 0;
#endif

    errno = 0;
    long open_max = sysconf(_SC_OPEN_MAX);
    if (open_max < 0) {
        if (errno != 0) return -1;
        errno = EMFILE; /* An unknown limit cannot satisfy the retain-only contract. */
        return -1;
    }
    if (open_max > (long)INT_MAX) open_max = (long)INT_MAX;
    for (long fd = WORKER_PIPE_FD + 1; fd < open_max; ++fd) {
        if (close((int)fd) != 0 && errno != EBADF) return -1;
    }
    return 0;
}

static int prepare_worker_child(int read_fd, int write_fd) {
    if (reset_child_termination_signals() != 0) return -1;

    struct rlimit no_core;
    no_core.rlim_cur = 0;
    no_core.rlim_max = 0;
    if (setrlimit(RLIMIT_CORE, &no_core) != 0) return -1;

    if (write_fd != WORKER_PIPE_FD) {
        if (dup2(write_fd, WORKER_PIPE_FD) < 0) return -1;
        if (close(write_fd) != 0) return -1;
    }

    /* dup2 may already have closed read_fd when it occupied descriptor 3. */
    if (read_fd != WORKER_PIPE_FD && close(read_fd) != 0) return -1;
    for (int fd = STDIN_FILENO; fd <= STDERR_FILENO; ++fd) {
        if (close(fd) != 0 && errno != EBADF) return -1;
    }
    if (close_inherited_descriptors() != 0) return -1;
    if (set_close_on_exec(WORKER_PIPE_FD) != 0) return -1;
    return 0;
}

int64_t elisa_lsp_analysis_timeout_millis(void) {
    const char *raw = getenv("ELISA_LSP_ANALYSIS_TIMEOUT_MS");
    if (raw == NULL) return 30000;
    if (*raw == '\0') {
        errno = EINVAL;
        return -1;
    }

    uint64_t value = 0;
    for (const unsigned char *p = (const unsigned char *)raw; *p != '\0'; ++p) {
        if (*p < '0' || *p > '9') {
            errno = EINVAL;
            return -1;
        }
        uint64_t digit = (uint64_t)(*p - '0');
        if (value > 300000u / 10u ||
            (value == 300000u / 10u && digit > 300000u % 10u)) {
            errno = EINVAL;
            return -1;
        }
        value = value * 10u + digit;
    }
    if (value < 100u || value > 300000u) {
        errno = EINVAL;
        return -1;
    }
    return (int64_t)value;
}

int elisa_lsp_analysis_worker_begin(int64_t timeout_ms) {
    if (worker_active) {
        errno = EBUSY;
        return -1;
    }
    if (timeout_ms < 1 || timeout_ms > 300000) {
        errno = EINVAL;
        return -1;
    }

    struct timespec deadline;
    if (make_deadline(&deadline, timeout_ms) != 0) return -1;

    int pipe_fds[2] = {-1, -1};
    if (pipe(pipe_fds) != 0) return -1;
    if (move_pipe_fd_above_stdio(&pipe_fds[0]) != 0 ||
        move_pipe_fd_above_stdio(&pipe_fds[1]) != 0 ||
        set_close_on_exec(pipe_fds[0]) != 0 ||
        set_close_on_exec(pipe_fds[1]) != 0) {
        int saved_errno = errno;
        close_pipe_pair(pipe_fds);
        errno = saved_errno;
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        int saved_errno = errno;
        close_pipe_pair(pipe_fds);
        errno = saved_errno;
        return -1;
    }
    if (child == 0) {
        if (prepare_worker_child(pipe_fds[0], pipe_fds[1]) != 0) _exit(127);
        worker_active = 1;
        worker_is_child = 1;
        worker_pid = -1;
        worker_read_fd = -1;
        worker_write_fd = WORKER_PIPE_FD;
        worker_eof_seen = 0;
        worker_reaped = 0;
        worker_status = 0;
        worker_deadline = deadline;
        return 1;
    }

    if (close(pipe_fds[1]) != 0) {
        int saved_errno = errno;
        close_fd_once(&pipe_fds[1]);
        kill_and_reap(child);
        close_fd_once(&pipe_fds[0]);
        errno = saved_errno;
        return -1;
    }
    pipe_fds[1] = -1;

    worker_active = 1;
    worker_is_child = 0;
    worker_pid = child;
    worker_read_fd = pipe_fds[0];
    worker_write_fd = -1;
    worker_eof_seen = 0;
    worker_reaped = 0;
    worker_status = 0;
    worker_deadline = deadline;
    pipe_fds[0] = -1;
    return 0;
}

/*
 * Wait for either a client frame to become readable or the active worker to
 * make progress. This is the parent-side event primitive for Q01: callers may
 * service input without blocking on the worker pipe, and worker deadlines and
 * termination signals remain observable while the input stream is idle.
 * A worker-ready event means its pipe has bytes, EOF, or an error; packet
 * framing and child exit validation remain the caller's responsibility.
 */
int elisa_lsp_analysis_worker_wait_event(int timeout_ms) {
    if (timeout_ms < -1 || timeout_ms > 300000) {
        errno = EINVAL;
        return -1;
    }
    if (worker_is_child) {
        errno = ECHILD;
        return -1;
    }
    struct timespec wait_deadline;
    int wait_deadline_active = timeout_ms >= 0;
    if (wait_deadline_active && make_deadline(&wait_deadline, timeout_ms) != 0) {
        return -1;
    }
    if (termination_is_pending()) return ELISA_LSP_EVENT_TERMINATION;

    for (;;) {
        int poll_timeout = -1;
        if (wait_deadline_active) {
            int caller_timeout = 0;
            int caller_time_left = timeout_until_deadline(&wait_deadline,
                                                         &caller_timeout);
            if (caller_time_left < 0) return -1;
            poll_timeout = caller_time_left == 0 ? 0 : caller_timeout;
        }
        if (worker_active) {
            struct timespec remaining;
            int deadline_state = deadline_remaining(&worker_deadline, &remaining);
            if (deadline_state == 0) return ELISA_LSP_EVENT_WORKER_DEADLINE;
            if (deadline_state < 0) return -1;

            int deadline_slice = 0;
            int slice_state = poll_timeout_for(&worker_deadline, &deadline_slice);
            if (slice_state == 0) return ELISA_LSP_EVENT_WORKER_DEADLINE;
            if (slice_state < 0) return -1;
            if (poll_timeout < 0 || deadline_slice < poll_timeout) {
                poll_timeout = deadline_slice;
            }
        }

        struct pollfd descriptors[2];
        nfds_t count = 0;
        descriptors[count].fd = STDIN_FILENO;
        descriptors[count].events = POLLIN | POLLHUP | POLLERR;
        descriptors[count].revents = 0;
        ++count;
        if (worker_active && !worker_eof_seen) {
            if (worker_read_fd < 0 || worker_pid <= 0) {
                errno = EINVAL;
                return -1;
            }
            descriptors[count].fd = worker_read_fd;
            descriptors[count].events = POLLIN | POLLHUP | POLLERR;
            descriptors[count].revents = 0;
            ++count;
        }

        int ready = poll(descriptors, count, poll_timeout);
        if (termination_is_pending()) return ELISA_LSP_EVENT_TERMINATION;
        if (ready < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (ready == 0) {
            if (worker_active) {
                struct timespec remaining;
                int deadline_state = deadline_remaining(&worker_deadline, &remaining);
                if (deadline_state == 0) return ELISA_LSP_EVENT_WORKER_DEADLINE;
                if (deadline_state < 0) return -1;
            }
            if (wait_deadline_active) {
                int caller_timeout = 0;
                int caller_time_left = timeout_until_deadline(&wait_deadline,
                                                             &caller_timeout);
                if (caller_time_left < 0) return -1;
                if (caller_time_left == 0) return 0;
            }
            if (worker_active && worker_eof_seen) return ELISA_LSP_EVENT_WORKER_EOF;
            if (worker_active) continue;
            return 0;
        }

        int events = 0;
        if (descriptors[0].revents & POLLNVAL) {
            errno = EBADF;
            return -1;
        }
        if (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            events |= ELISA_LSP_EVENT_INPUT;
        }
        if (worker_active && !worker_eof_seen) {
            if (descriptors[1].revents & POLLNVAL) {
                errno = EBADF;
                return -1;
            }
            if (descriptors[1].revents & (POLLIN | POLLHUP | POLLERR)) {
                events |= ELISA_LSP_EVENT_WORKER;
            }
        }
        if (events != 0) return events;
    }
}

ssize_t elisa_lsp_analysis_worker_write(const void *buffer, size_t count) {
    if (!worker_active || !worker_is_child || worker_write_fd < 0 ||
        (buffer == NULL && count != 0)) {
        errno = EINVAL;
        return -1;
    }
    if (count > (size_t)SSIZE_MAX) {
        errno = EINVAL;
        return -1;
    }

    size_t offset = 0;
    while (offset < count) {
        ssize_t written = write(worker_write_fd,
                               (const unsigned char *)buffer + offset,
                               count - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written == 0) errno = EIO;
        return -1;
    }
    return (ssize_t)offset;
}

void elisa_lsp_analysis_worker_child_exit(int status) {
    if (!worker_active || !worker_is_child) {
        errno = EINVAL;
        return;
    }
    close_fd_once(&worker_write_fd);
    _exit(status);
}

static int termination_is_pending(void) {
    return elisa_lsp_pending_termination_signal() > 0;
}

static ssize_t fail_and_abort(int error_number) {
    elisa_lsp_analysis_worker_abort();
    errno = error_number;
    return -1;
}

ssize_t elisa_lsp_analysis_worker_read(void *buffer, size_t count) {
    if (!worker_active || worker_is_child || worker_read_fd < 0 ||
        (buffer == NULL && count != 0)) {
        errno = EINVAL;
        return -1;
    }
    if (count == 0) return 0;

    size_t request_count = count;
    if (request_count > (size_t)SSIZE_MAX) request_count = (size_t)SSIZE_MAX;

    for (;;) {
        if (termination_is_pending()) return fail_and_abort(EINTR);

        int timeout_ms = 0;
        int time_left = poll_timeout_for(&worker_deadline, &timeout_ms);
        if (time_left == 0) return fail_and_abort(ETIMEDOUT);
        if (time_left < 0) {
            int saved_errno = errno;
            return fail_and_abort(saved_errno);
        }

        struct pollfd descriptor;
        descriptor.fd = worker_read_fd;
        descriptor.events = POLLIN | POLLHUP | POLLERR;
        descriptor.revents = 0;
        int ready = poll(&descriptor, 1, timeout_ms);
        if (ready < 0) {
            if (errno == EINTR) continue;
            int saved_errno = errno;
            return fail_and_abort(saved_errno);
        }
        if (termination_is_pending()) return fail_and_abort(EINTR);
        if (ready == 0) continue;
        if ((descriptor.revents & POLLNVAL) != 0) return fail_and_abort(EBADF);
        if ((descriptor.revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;

        ssize_t received = read(worker_read_fd, buffer, request_count);
        if (received > 0) {
            if (termination_is_pending()) return fail_and_abort(EINTR);
            return received;
        }
        if (received == 0) {
            worker_eof_seen = 1;
            return 0;
        }
        if (errno == EINTR) {
            if (termination_is_pending()) return fail_and_abort(EINTR);
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
        int saved_errno = errno;
        return fail_and_abort(saved_errno);
    }
}

/* Consume currently available pipe bytes without waiting for the child.
 * Returns a positive byte count, 0 on EOF, -2 when the pipe is not readable,
 * and -1 after aborting the worker on a deadline, signal, or I/O failure. */
ssize_t elisa_lsp_analysis_worker_read_available(void *buffer, size_t count) {
    if (!worker_active || worker_is_child || worker_pid <= 0 ||
        worker_read_fd < 0 || (buffer == NULL && count != 0) ||
        count > (size_t)SSIZE_MAX) {
        errno = EINVAL;
        return -1;
    }
    if (count == 0) return 0;
    if (worker_eof_seen) return 0;
    if (termination_is_pending()) return fail_and_abort(EINTR);
    int timeout_ms = 0;
    int time_left = poll_timeout_for(&worker_deadline, &timeout_ms);
    if (time_left == 0) return fail_and_abort(ETIMEDOUT);
    if (time_left < 0) {
        int saved_errno = errno;
        return fail_and_abort(saved_errno);
    }

    struct pollfd descriptor;
    descriptor.fd = worker_read_fd;
    descriptor.events = POLLIN | POLLHUP | POLLERR;
    descriptor.revents = 0;
    int ready = poll(&descriptor, 1, 0);
    if (ready < 0) {
        if (errno == EINTR) return -2;
        int saved_errno = errno;
        return fail_and_abort(saved_errno);
    }
    if (ready == 0) return -2;
    if ((descriptor.revents & POLLNVAL) != 0) return fail_and_abort(EBADF);
    if ((descriptor.revents & (POLLIN | POLLHUP | POLLERR)) == 0) return -2;

    ssize_t received = read(worker_read_fd, buffer, count);
    if (received > 0) {
        if (termination_is_pending()) return fail_and_abort(EINTR);
        return received;
    }
    if (received == 0) {
        worker_eof_seen = 1;
        return 0;
    }
    if (errno == EINTR) return -2;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
    int saved_errno = errno;
    return fail_and_abort(saved_errno);
}

/* Reap only after the parent has drained the packet through EOF.  A zero
 * result means that the child is still finishing; this call never waits. */
int elisa_lsp_analysis_worker_try_finish(void) {
    if (!worker_active || worker_is_child || worker_pid <= 0 ||
        worker_read_fd < 0 || !worker_eof_seen) {
        errno = EINVAL;
        return -1;
    }
    if (termination_is_pending()) {
        elisa_lsp_analysis_worker_abort();
        errno = EINTR;
        return -1;
    }
    int timeout_ms = 0;
    int time_left = poll_timeout_for(&worker_deadline, &timeout_ms);
    if (time_left == 0) {
        elisa_lsp_analysis_worker_abort();
        errno = ETIMEDOUT;
        return -1;
    }
    if (time_left < 0) {
        int saved_errno = errno;
        elisa_lsp_analysis_worker_abort();
        errno = saved_errno;
        return -1;
    }

    if (!worker_reaped) {
        int child_status = 0;
        pid_t waited = waitpid(worker_pid, &child_status, WNOHANG);
        if (waited == 0 || (waited < 0 && errno == EINTR)) return 0;
        if (waited < 0) {
            int saved_errno = errno;
            elisa_lsp_analysis_worker_abort();
            errno = saved_errno;
            return -1;
        }
        worker_reaped = 1;
        worker_status = child_status;
    }
    int final_status = worker_status;
    worker_pid = -1;
    int close_result = close(worker_read_fd);
    int close_errno = errno;
    worker_read_fd = -1;
    reset_worker_state();
    if (close_result != 0) {
        errno = close_errno;
        return -1;
    }
    if (!WIFEXITED(final_status) || WEXITSTATUS(final_status) != 0) {
        errno = ECHILD;
        return -1;
    }
    return 1;
}

void elisa_lsp_analysis_worker_abort(void) {
    if (!worker_active) return;
    if (worker_is_child) {
        close_fd_once(&worker_write_fd);
        reset_worker_state();
        return;
    }

    pid_t child = worker_pid;
    worker_pid = -1;
    if (!worker_reaped) kill_and_reap(child);
    close_fd_once(&worker_read_fd);
    reset_worker_state();
}

int elisa_lsp_analysis_worker_finish(void) {
    if (!worker_active || worker_is_child || worker_pid <= 0 ||
        worker_read_fd < 0) {
        errno = EINVAL;
        return -1;
    }

    unsigned char discard[8192];
    int child_status = 0;
    for (;;) {
        if (termination_is_pending()) {
            elisa_lsp_analysis_worker_abort();
            errno = EINTR;
            return -1;
        }

        int timeout_ms = 0;
        int time_left = poll_timeout_for(&worker_deadline, &timeout_ms);
        if (time_left == 0) {
            elisa_lsp_analysis_worker_abort();
            errno = ETIMEDOUT;
            return -1;
        }
        if (time_left < 0) {
            int saved_errno = errno;
            elisa_lsp_analysis_worker_abort();
            errno = saved_errno;
            return -1;
        }

        pid_t waited = waitpid(worker_pid, &child_status, WNOHANG);
        if (waited == worker_pid) {
            worker_pid = -1; /* Already reaped; cleanup must not signal a reused PID. */
            if (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0) {
                close_fd_once(&worker_read_fd);
                reset_worker_state();
                errno = ECHILD;
                return -1;
            }

            /* The worker is gone, so draining the remaining pipe cannot block. */
            for (;;) {
                ssize_t received = read(worker_read_fd, discard, sizeof(discard));
                if (received > 0) continue;
                if (received == 0) break;
                if (errno == EINTR) continue;
                int saved_errno = errno;
                close_fd_once(&worker_read_fd);
                reset_worker_state();
                errno = saved_errno;
                return -1;
            }
            int close_result = close(worker_read_fd);
            int close_errno = errno;
            worker_read_fd = -1;
            reset_worker_state();
            if (close_result != 0) {
                errno = close_errno;
                return -1;
            }
            return 0;
        }
        if (waited < 0 && errno != EINTR) {
            int saved_errno = errno;
            elisa_lsp_analysis_worker_abort();
            errno = saved_errno;
            return -1;
        }

        if (worker_eof_seen) {
            int slept = poll(NULL, 0, timeout_ms);
            if (slept < 0 && errno != EINTR) {
                int saved_errno = errno;
                elisa_lsp_analysis_worker_abort();
                errno = saved_errno;
                return -1;
            }
            continue;
        }

        struct pollfd descriptor;
        descriptor.fd = worker_read_fd;
        descriptor.events = POLLIN | POLLHUP | POLLERR;
        descriptor.revents = 0;
        int ready = poll(&descriptor, 1, timeout_ms);
        if (ready < 0) {
            if (errno == EINTR) continue;
            int saved_errno = errno;
            elisa_lsp_analysis_worker_abort();
            errno = saved_errno;
            return -1;
        }
        if (ready == 0) continue;
        if ((descriptor.revents & POLLNVAL) != 0) {
            elisa_lsp_analysis_worker_abort();
            errno = EBADF;
            return -1;
        }
        if ((descriptor.revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;

        ssize_t received = read(worker_read_fd, discard, sizeof(discard));
        if (received > 0) continue;
        if (received == 0) {
            worker_eof_seen = 1;
            continue;
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
        int saved_errno = errno;
        elisa_lsp_analysis_worker_abort();
        errno = saved_errno;
        return -1;
    }
}
