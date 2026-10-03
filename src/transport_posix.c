/* Small POSIX transport boundary for the synchronous LSP process. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

enum { TERMINATION_SIGNAL_COUNT = 3 };

static const int termination_signals[TERMINATION_SIGNAL_COUNT] = {
    SIGINT, SIGTERM, SIGHUP
};
static volatile sig_atomic_t pending_termination_signal = 0;
static struct sigaction previous_termination_actions[TERMINATION_SIGNAL_COUNT];
static unsigned char termination_handler_installed[TERMINATION_SIGNAL_COUNT];
static sigset_t previous_termination_mask;
static int termination_mask_saved = 0;
static int termination_read_fd = -1;
static int termination_read_flags = -1;
static int output_frame_fd = -1;
static int output_frame_flags = -1;
static struct timespec output_frame_deadline;

/* Signal context: only update the sig_atomic_t state. */
static void record_termination_signal(int signal_number) {
    if (pending_termination_signal == 0) {
        pending_termination_signal = (sig_atomic_t)signal_number;
    }
}

static int any_termination_handler_installed(void) {
    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; ++i) {
        if (termination_handler_installed[i]) return 1;
    }
    return 0;
}

static int make_termination_signal_set(sigset_t *set) {
    if (sigemptyset(set) != 0) return -1;
    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; ++i) {
        if (sigaddset(set, termination_signals[i]) != 0) return -1;
    }
    return 0;
}

static int has_pending_termination_signal(void) {
    sigset_t pending;
    if (sigpending(&pending) != 0) return -1;
    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; ++i) {
        int member = sigismember(&pending, termination_signals[i]);
        if (member < 0) return -1;
        if (member != 0) return 1;
    }
    return 0;
}

/*
 * Install cooperative termination handlers for common POSIX termination
 * signals. While installed, these signals are unblocked even if the process
 * inherited them blocked; the original mask and handlers are restored by
 * elisa_lsp_restore_termination_handlers(). Repeated installation is safe.
 */
int elisa_lsp_install_termination_handlers(void) {
    sigset_t termination_set;
    sigset_t original_mask;
    if (make_termination_signal_set(&termination_set) != 0) return -1;

    int first_install = !any_termination_handler_installed();
    if (sigprocmask(SIG_BLOCK, &termination_set, &original_mask) != 0) return -1;

    if (first_install) pending_termination_signal = 0;

    struct sigaction action = {0};
    action.sa_handler = record_termination_signal;
    action.sa_flags = 0; /* Do not restart blocking I/O after termination. */
    if (sigemptyset(&action.sa_mask) != 0) {
        int saved_errno = errno;
        (void)sigprocmask(SIG_SETMASK, &original_mask, NULL);
        errno = saved_errno;
        return -1;
    }

    int installed_now[TERMINATION_SIGNAL_COUNT] = {0};
    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; ++i) {
        if (termination_handler_installed[i]) continue;
        if (sigaction(termination_signals[i], &action,
                      &previous_termination_actions[i]) != 0) {
            int saved_errno = errno;
            for (size_t j = i; j > 0; --j) {
                size_t rollback = j - 1;
                if (!installed_now[rollback]) continue;
                if (sigaction(termination_signals[rollback],
                              &previous_termination_actions[rollback], NULL) == 0) {
                    termination_handler_installed[rollback] = 0;
                }
            }
            (void)sigprocmask(SIG_SETMASK, &original_mask, NULL);
            errno = saved_errno;
            return -1;
        }
        termination_handler_installed[i] = 1;
        installed_now[i] = 1;
    }

    if (first_install) {
        previous_termination_mask = original_mask;
        termination_mask_saved = 1;
    }

    /* Keep termination signals deliverable for the duration of the server. */
    sigset_t active_mask = original_mask;
    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; ++i) {
        (void)sigdelset(&active_mask, termination_signals[i]);
    }
    if (sigprocmask(SIG_SETMASK, &active_mask, NULL) != 0) {
        int saved_errno = errno;
        for (size_t j = TERMINATION_SIGNAL_COUNT; j > 0; --j) {
            size_t index = j - 1;
            if (!installed_now[index]) continue;
            if (sigaction(termination_signals[index],
                          &previous_termination_actions[index], NULL) == 0) {
                termination_handler_installed[index] = 0;
            }
        }
        if (!any_termination_handler_installed()) termination_mask_saved = 0;
        (void)sigprocmask(SIG_SETMASK, &original_mask, NULL);
        errno = saved_errno;
        return -1;
    }
    return 0;
}

/* Return 0 while no termination signal has been observed, else its signal number. */
int elisa_lsp_pending_termination_signal(void) {
    return (int)pending_termination_signal;
}

/* Restore the exact dispositions and signal mask observed at first install. */
int elisa_lsp_restore_termination_handlers(void) {
    if (!any_termination_handler_installed() && !termination_mask_saved &&
        output_frame_fd < 0) return 0;

    sigset_t termination_set;
    sigset_t current_mask;
    if (make_termination_signal_set(&termination_set) != 0) return -1;
    if (sigprocmask(SIG_BLOCK, &termination_set, &current_mask) != 0) return -1;

    int first_errno = 0;
    for (size_t j = TERMINATION_SIGNAL_COUNT; j > 0; --j) {
        size_t i = j - 1;
        if (!termination_handler_installed[i]) continue;
        if (sigaction(termination_signals[i],
                      &previous_termination_actions[i], NULL) == 0) {
            termination_handler_installed[i] = 0;
        } else if (first_errno == 0) {
            first_errno = errno;
        }
    }

    const sigset_t *restore_mask = termination_mask_saved
        ? &previous_termination_mask : &current_mask;
    if (sigprocmask(SIG_SETMASK, restore_mask, NULL) != 0 && first_errno == 0) {
        first_errno = errno;
    }
    if (termination_read_fd >= 0 && termination_read_flags >= 0) {
        int current_flags = fcntl(termination_read_fd, F_GETFL);
        if (current_flags < 0) {
            if (first_errno == 0) first_errno = errno;
        } else {
            int restored_flags = (current_flags & ~O_NONBLOCK) |
                                 (termination_read_flags & O_NONBLOCK);
            if (fcntl(termination_read_fd, F_SETFL, restored_flags) != 0) {
                if (first_errno == 0) first_errno = errno;
            } else {
                termination_read_fd = -1;
                termination_read_flags = -1;
            }
        }
    }
    if (output_frame_fd >= 0 && output_frame_flags >= 0) {
        int current_flags = fcntl(output_frame_fd, F_GETFL);
        if (current_flags < 0) {
            if (first_errno == 0) first_errno = errno;
        } else {
            int restored_flags = (current_flags & ~O_NONBLOCK) |
                                 (output_frame_flags & O_NONBLOCK);
            if (fcntl(output_frame_fd, F_SETFL, restored_flags) != 0) {
                if (first_errno == 0) first_errno = errno;
            } else {
                output_frame_fd = -1;
                output_frame_flags = -1;
            }
        }
    }
    if (first_errno != 0) {
        errno = first_errno;
        return -1;
    }
    termination_mask_saved = 0;
    return 0;
}

/* These limits are also enforced in Elisa before each allocation. The C
 * boundary reads environment configuration because the current stage0 runtime
 * has no stable getenv binding. Negative values mean invalid configuration. */
static int64_t configured_limit(const char *name, int64_t fallback,
                                int64_t minimum, int64_t maximum) {
    const char *raw = getenv(name);
    if (raw == NULL) return fallback;
    if (*raw == '\0') return -1;

    uint64_t value = 0;
    for (const unsigned char *p = (const unsigned char *)raw; *p != '\0'; ++p) {
        if (*p < '0' || *p > '9') return -1;
        const uint64_t digit = (uint64_t)(*p - '0');
        if (value > (uint64_t)maximum / 10 ||
            (value == (uint64_t)maximum / 10 && digit > (uint64_t)maximum % 10)) {
            return -1;
        }
        value = value * 10 + digit;
    }
    if (value < (uint64_t)minimum || value > (uint64_t)maximum) return -1;
    return (int64_t)value;
}

int64_t elisa_lsp_max_header_bytes(void) {
    return configured_limit("ELISA_LSP_MAX_HEADER_BYTES", 16384, 256, 1048576);
}

int64_t elisa_lsp_max_header_lines(void) {
    return configured_limit("ELISA_LSP_MAX_HEADER_LINES", 64, 2, 1024);
}

int64_t elisa_lsp_max_body_bytes(void) {
    return configured_limit("ELISA_LSP_MAX_BODY_BYTES", 16777216, 1, 268435456);
}

int64_t elisa_lsp_max_open_source_bytes(void) {
    return configured_limit("ELISA_LSP_MAX_OPEN_SOURCE_BYTES", 268435456,
                            1, 1073741824);
}

int64_t elisa_lsp_max_open_documents(void) {
    return configured_limit("ELISA_LSP_MAX_OPEN_DOCUMENTS", 1024, 1, 16384);
}

int64_t elisa_lsp_max_open_uri_bytes(void) {
    return configured_limit("ELISA_LSP_MAX_OPEN_URI_BYTES", 8388608,
                            1, 67108864);
}

/* Bound retained derived semantic/provider payloads across all open
 * documents. This is separate from the per-analysis worker packet limit:
 * the LSP may retain several completed snapshots at once, so the parent
 * enforces this aggregate budget with recency-based whole-snapshot eviction. */
int64_t elisa_lsp_max_derived_cache_bytes(void) {
    return configured_limit("ELISA_LSP_MAX_DERIVED_CACHE_BYTES", 67108864,
                            1024, 1073741824);
}

/* Bound a single complete stdout buffer, including time spent making partial
 * progress. This is deliberately independent from the input body limit. */
int64_t elisa_lsp_write_timeout_millis(void) {
    return configured_limit("ELISA_LSP_WRITE_TIMEOUT_MS", 15000, 100, 120000);
}

/* Runtime observability configuration. Logging is intentionally opt-in at
 * the informational level: ordinary editor sessions keep stderr quiet apart
 * from existing bounded warnings/errors. Level names are stable and strict so
 * a typo cannot silently turn on verbose output. */
int64_t elisa_lsp_log_level(void) {
    const char *raw = getenv("ELISA_LSP_LOG_LEVEL");
    if (raw == NULL || strcmp(raw, "off") == 0 || strcmp(raw, "0") == 0) return 0;
    if (strcmp(raw, "error") == 0 || strcmp(raw, "1") == 0) return 1;
    if (strcmp(raw, "warn") == 0 || strcmp(raw, "warning") == 0 || strcmp(raw, "2") == 0) return 2;
    if (strcmp(raw, "info") == 0 || strcmp(raw, "3") == 0) return 3;
    if (strcmp(raw, "debug") == 0 || strcmp(raw, "4") == 0) return 4;
    return -1;
}

/* A process-wide byte budget bounds all server stderr writes, including
 * verbose diagnostics. The minimum leaves room for at least one useful line;
 * the upper bound avoids an accidental multi-gigabyte debug log. */
int64_t elisa_lsp_log_max_bytes(void) {
    return configured_limit("ELISA_LSP_LOG_MAX_BYTES", 65536, 1024, 4194304);
}

/* Stage timing is opt-in because even a clock read has a measurable cost on
 * very small requests. When enabled, the LSP reports bounded per-message
 * stage observations on stderr and through its private stats probe. Keep the
 * truthy vocabulary identical to the other opt-in diagnostics switches. */
int elisa_lsp_timing_enabled(void) {
    const char *raw = getenv("ELISA_LSP_TIMINGS");
    if (raw == NULL) return 0;
    return strcmp(raw, "1") == 0 || strcmp(raw, "true") == 0 ||
           strcmp(raw, "TRUE") == 0 || strcmp(raw, "yes") == 0 ||
           strcmp(raw, "on") == 0;
}

/* Monotonic milliseconds are used only for observational timing. A negative
 * result means the host clock was unavailable; callers retain protocol
 * behavior and omit precision rather than failing a request. */
int64_t elisa_lsp_monotonic_millis(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    if (now.tv_sec > (time_t)(INT64_MAX / 1000)) return INT64_MAX;
    int64_t seconds = (int64_t)now.tv_sec;
    if (seconds > INT64_MAX / 1000) return INT64_MAX;
    int64_t millis = seconds * 1000;
    int64_t nanos = (int64_t)now.tv_nsec / 1000000;
    if (millis > INT64_MAX - nanos) return INT64_MAX;
    return millis + nanos;
}

/* Optional response-boundary assertions. Keep the default disabled for
 * production latency; debug and protocol-regression runs opt in explicitly.
 * Only a small, stable truthy vocabulary is accepted so a typo cannot
 * accidentally enable a potentially expensive source scan. */
int elisa_lsp_validate_provider_ranges(void) {
    const char *raw = getenv("ELISA_LSP_VALIDATE_RANGES");
    if (raw == NULL) return 0;
    return strcmp(raw, "1") == 0 || strcmp(raw, "true") == 0 ||
           strcmp(raw, "TRUE") == 0 || strcmp(raw, "yes") == 0 ||
           strcmp(raw, "on") == 0;
}

/* Preserve EOF as zero and retry ordinary interrupted reads. When the
 * termination handlers are active, pselect atomically unblocks them while
 * waiting for input, so a signal between the state check and the wait cannot
 * be lost. The single input descriptor is made nonblocking while the adapter
 * is active as well: a signal after pselect returns but before read cannot
 * turn that final syscall into an unbounded wait. The original O_NONBLOCK bit
 * is restored with the termination handlers. */
ssize_t elisa_lsp_read_retry(int fd, void *buffer, size_t count) {
    for (;;) {
        if (pending_termination_signal != 0) {
            errno = EINTR;
            return -1;
        }

        if (any_termination_handler_installed()) {
            if (fd < 0 || fd >= FD_SETSIZE) {
                errno = EINVAL;
                return -1;
            }

            if (termination_read_fd != fd) {
                if (termination_read_fd >= 0) {
                    errno = EINVAL; /* This adapter supports one input stream. */
                    return -1;
                }
                int flags = fcntl(fd, F_GETFL);
                if (flags < 0) return -1;
                if ((flags & O_NONBLOCK) == 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return -1;
                termination_read_fd = fd;
                termination_read_flags = flags;
            }

            sigset_t termination_set;
            sigset_t original_mask;
            sigset_t wait_mask;
            if (make_termination_signal_set(&termination_set) != 0) return -1;
            if (sigprocmask(SIG_BLOCK, &termination_set, &original_mask) != 0) return -1;
            if (pending_termination_signal != 0) {
                int saved_errno = EINTR;
                (void)sigprocmask(SIG_SETMASK, &original_mask, NULL);
                errno = saved_errno;
                return -1;
            }

            wait_mask = original_mask;
            for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; ++i) {
                (void)sigdelset(&wait_mask, termination_signals[i]);
            }
            fd_set read_fds;
            FD_ZERO(&read_fds);
            FD_SET(fd, &read_fds);
            int ready = pselect(fd + 1, &read_fds, NULL, NULL, NULL, &wait_mask);
            int wait_errno = errno;
            int kernel_signal_pending = has_pending_termination_signal();
            int pending_errno = errno;

            /* Restore the pre-wait mask. Any termination signal delivered in
             * the pselect/read gap is either recorded here or remains visible
             * as a pending signal if the caller had it blocked. */
            int mask_result = sigprocmask(SIG_SETMASK, &original_mask, NULL);
            int mask_errno = errno;
            if (pending_termination_signal != 0) {
                errno = EINTR;
                return -1;
            }
            if (kernel_signal_pending > 0) {
                errno = EINTR;
                return -1;
            }
            if (kernel_signal_pending < 0) {
                errno = pending_errno;
                return -1;
            }
            if (mask_result != 0) {
                errno = mask_errno;
                return -1;
            }
            if (ready < 0) {
                if (wait_errno == EINTR) continue;
                errno = wait_errno;
                return -1;
            }
            if (ready == 0 || !FD_ISSET(fd, &read_fds)) continue;
        }

        if (pending_termination_signal != 0) {
            errno = EINTR;
            return -1;
        }
        ssize_t received = read(fd, buffer, count);
        if (pending_termination_signal != 0) {
            errno = EINTR;
            return -1;
        }
        if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) &&
            pending_termination_signal == 0 && any_termination_handler_installed()) {
            continue;
        }
        if (received < 0 && errno == EINTR && pending_termination_signal == 0) continue;
        if (pending_termination_signal != 0 && received < 0 && errno == EINTR) return -1;
        return received;
    }
}

/* Retry interrupted writes and prevent a closed client pipe from delivering
 * SIGPIPE. A recorded termination signal is returned to the caller instead
 * of being retried forever while stdout is stalled. */
ssize_t elisa_lsp_write_retry(int fd, const void *buffer, size_t count) {
    static int sigpipe_ignored = 0;
    if (!sigpipe_ignored) {
        if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
            return -1;
        }
        sigpipe_ignored = 1;
    }

    ssize_t written;
    do {
        if (pending_termination_signal != 0) {
            errno = EINTR;
            return -1;
        }
        written = write(fd, buffer, count);
    } while (written < 0 && errno == EINTR && pending_termination_signal == 0);
    return written;
}

static int make_remaining_timeout(const struct timespec *deadline,
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

static int make_deadline(struct timespec *deadline, int64_t timeout_millis) {
    if (clock_gettime(CLOCK_MONOTONIC, deadline) != 0) return -1;
    deadline->tv_sec += (time_t)(timeout_millis / 1000);
    deadline->tv_nsec += (long)((timeout_millis % 1000) * 1000000);
    if (deadline->tv_nsec >= 1000000000L) {
        deadline->tv_sec += 1;
        deadline->tv_nsec -= 1000000000L;
    }
    return 0;
}

/* Begin one complete LSP frame. The same absolute deadline covers both the
 * Content-Length header and body, and stdout is nonblocking until end/restore. */
int elisa_lsp_output_begin(int fd, int64_t timeout_millis) {
    if (fd != STDOUT_FILENO || fd >= FD_SETSIZE || timeout_millis < 1) {
        errno = EINVAL;
        return -1;
    }
    if (output_frame_fd >= 0) {
        errno = EBUSY;
        return -1;
    }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -1;
    if (make_deadline(&output_frame_deadline, timeout_millis) != 0) return -1;
    if ((flags & O_NONBLOCK) == 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return -1;
    output_frame_fd = fd;
    output_frame_flags = flags;
    return 0;
}

/* End a frame and restore the exact O_NONBLOCK state observed at begin. */
int elisa_lsp_output_end(int fd) {
    if (output_frame_fd < 0 || output_frame_fd != fd || output_frame_flags < 0) {
        errno = EINVAL;
        return -1;
    }
    int current_flags = fcntl(fd, F_GETFL);
    if (current_flags < 0) return -1;
    int restored_flags = (current_flags & ~O_NONBLOCK) |
                         (output_frame_flags & O_NONBLOCK);
    if (fcntl(fd, F_SETFL, restored_flags) != 0) return -1;
    output_frame_fd = -1;
    output_frame_flags = -1;
    return 0;
}

static int wait_stdout_writable(int fd, const struct timespec *deadline) {
    for (;;) {
        if (pending_termination_signal != 0) {
            errno = EINTR;
            return -1;
        }
        struct timespec remaining;
        int time_left = make_remaining_timeout(deadline, &remaining);
        if (time_left <= 0) return -1;
        fd_set write_fds;
        FD_ZERO(&write_fds);
        FD_SET(fd, &write_fds);
        int ready = pselect(fd + 1, NULL, &write_fds, NULL, &remaining, NULL);
        if (ready > 0) {
            if (pending_termination_signal != 0) {
                errno = EINTR;
                return -1;
            }
            return FD_ISSET(fd, &write_fds) ? 0 : -1;
        }
        if (ready == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        if (errno == EINTR && pending_termination_signal == 0) continue;
        return -1;
    }
}

/* Write a complete buffer with one monotonic deadline. Calls inside an output
 * frame share that frame's deadline; standalone calls get a local deadline. */
ssize_t elisa_lsp_write_all(int fd, const void *buffer, size_t count,
                            int64_t timeout_millis) {
    if (timeout_millis < 1 || fd < 0 || fd >= FD_SETSIZE) {
        errno = EINVAL;
        return -1;
    }
    int owns_frame = 0;
    if (output_frame_fd < 0 && fd == STDOUT_FILENO) {
        if (elisa_lsp_output_begin(fd, timeout_millis) != 0) return -1;
        owns_frame = 1;
    }
    struct timespec deadline;
    if (output_frame_fd >= 0) {
        if (fd != output_frame_fd) {
            if (owns_frame) (void)elisa_lsp_output_end(fd);
            errno = EINVAL;
            return -1;
        }
        deadline = output_frame_deadline;
    } else if (make_deadline(&deadline, timeout_millis) != 0) {
        if (owns_frame) (void)elisa_lsp_output_end(fd);
        return -1;
    }

    ssize_t result = 0;
    size_t offset = 0;
    while (offset < count) {
        if (pending_termination_signal != 0) {
            errno = EINTR;
            result = -1;
            break;
        }
        struct timespec remaining;
        int time_left = make_remaining_timeout(&deadline, &remaining);
        if (time_left <= 0) {
            result = -1;
            break;
        }
        ssize_t written = elisa_lsp_write_retry(fd,
                                                (const unsigned char *)buffer + offset,
                                                count - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written == 0) {
            errno = EIO;
            result = -1;
            break;
        }
        if ((errno == EAGAIN || errno == EWOULDBLOCK) &&
            output_frame_fd == fd) {
            if (wait_stdout_writable(fd, &deadline) == 0) continue;
        }
        result = -1;
        break;
    }
    if (result == 0) result = (ssize_t)offset;
    int saved_errno = errno;
    if (owns_frame && elisa_lsp_output_end(fd) != 0) {
        if (result >= 0) return -1;
    }
    if (result < 0) errno = saved_errno;
    return result;
}
