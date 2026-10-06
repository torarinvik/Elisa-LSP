#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t pending_termination = 0;
static const int child_test_signals[] = {SIGINT, SIGTERM, SIGHUP};

int elisa_lsp_pending_termination_signal(void) {
    return (int)pending_termination;
}

#include "../src/analysis_worker_posix.c"

static int check(int condition, const char *message) {
    if (!condition) fprintf(stderr, "FAIL: %s\n", message);
    return condition;
}

static double monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static void ignored_test_handler(int signal_number) {
    (void)signal_number;
}

static int child_environment_is_isolated(int sentinel_fd) {
    for (int fd = STDIN_FILENO; fd <= STDERR_FILENO; ++fd) {
        errno = 0;
        if (fcntl(fd, F_GETFD) >= 0 || errno != EBADF) return 0;
    }

    if (fcntl(WORKER_PIPE_FD, F_GETFD) < 0) return 0;
    errno = 0;
    if (fcntl(WORKER_PIPE_FD + 1, F_GETFD) >= 0 || errno != EBADF) return 0;
    if (sentinel_fd >= WORKER_PIPE_FD + 1) {
        errno = 0;
        if (fcntl(sentinel_fd, F_GETFD) >= 0 || errno != EBADF) return 0;
    }

    const int signals[] = {SIGINT, SIGTERM, SIGHUP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        struct sigaction action;
        if (sigaction(signals[i], NULL, &action) != 0 ||
            action.sa_handler != SIG_DFL) return 0;
    }

    sigset_t current_mask;
    if (sigprocmask(SIG_SETMASK, NULL, &current_mask) != 0) return 0;
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        int member = sigismember(&current_mask, signals[i]);
        if (member != 0) return 0;
    }

    struct rlimit core_limit;
    if (getrlimit(RLIMIT_CORE, &core_limit) != 0 ||
        core_limit.rlim_cur != 0 || core_limit.rlim_max != 0) return 0;
    return 1;
}

static int check_timeout_configuration(void) {
    if (unsetenv("ELISA_LSP_ANALYSIS_TIMEOUT_MS") != 0 ||
        !check(elisa_lsp_analysis_timeout_millis() == 30000,
               "analysis timeout defaults to 30000 ms")) return 0;

    if (setenv("ELISA_LSP_ANALYSIS_TIMEOUT_MS", "100", 1) != 0 ||
        !check(elisa_lsp_analysis_timeout_millis() == 100,
               "analysis timeout accepts its minimum")) return 0;
    if (setenv("ELISA_LSP_ANALYSIS_TIMEOUT_MS", "300000", 1) != 0 ||
        !check(elisa_lsp_analysis_timeout_millis() == 300000,
               "analysis timeout accepts its maximum")) return 0;

    const char *invalid[] = {
        "", "0", "99", "300001", "-1", "1x", "999999999999999999999"
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        if (setenv("ELISA_LSP_ANALYSIS_TIMEOUT_MS", invalid[i], 1) != 0 ||
            !check(elisa_lsp_analysis_timeout_millis() == -1,
                   "invalid analysis timeout settings are rejected")) return 0;
    }
    return unsetenv("ELISA_LSP_ANALYSIS_TIMEOUT_MS") == 0;
}

static int test_large_stream_success(void) {
    const size_t payload_size = 1024u * 1024u + 37u;
    int low_sentinel_fd = open("/dev/null", O_RDONLY);
    int sentinel_fd = low_sentinel_fd >= 0
        ? fcntl(low_sentinel_fd, F_DUPFD, 10)
        : -1;
    if (low_sentinel_fd >= 0) close(low_sentinel_fd);
    if (!check(sentinel_fd >= 3, "open an inherited-descriptor sentinel")) return 0;

    struct sigaction original_actions[3];
    struct sigaction custom_term = {0};
    custom_term.sa_handler = ignored_test_handler;
    sigset_t test_signal_set;
    sigset_t original_mask;
    if (sigemptyset(&custom_term.sa_mask) != 0 ||
        sigemptyset(&test_signal_set) != 0) {
        close(sentinel_fd);
        return check(0, "prepare inherited signal state for the child reset test");
    }
    for (size_t i = 0;
         i < sizeof(child_test_signals) / sizeof(child_test_signals[0]); ++i) {
        if (sigaddset(&test_signal_set, child_test_signals[i]) != 0) {
            close(sentinel_fd);
            return check(0, "build the inherited signal mask");
        }
    }
    if (sigprocmask(SIG_BLOCK, &test_signal_set, &original_mask) != 0) {
        close(sentinel_fd);
        return check(0, "block inherited termination signals for the child test");
    }
    size_t installed_actions = 0;
    for (; installed_actions < sizeof(child_test_signals) / sizeof(child_test_signals[0]);
         ++installed_actions) {
        int signal_number = child_test_signals[installed_actions];
        if (sigaction(signal_number, NULL, &original_actions[installed_actions]) != 0 ||
            sigaction(signal_number, &custom_term, NULL) != 0) break;
    }
    if (installed_actions != sizeof(child_test_signals) / sizeof(child_test_signals[0])) {
        while (installed_actions > 0) {
            --installed_actions;
            (void)sigaction(child_test_signals[installed_actions],
                            &original_actions[installed_actions], NULL);
        }
        (void)sigprocmask(SIG_SETMASK, &original_mask, NULL);
        close(sentinel_fd);
        return check(0, "install inherited termination handlers for the child reset test");
    }

    int started = elisa_lsp_analysis_worker_begin(5000);
    if (started == 1) {
        int isolated = child_environment_is_isolated(sentinel_fd);
        unsigned char *payload = malloc(payload_size);
        if (payload == NULL) elisa_lsp_analysis_worker_child_exit(21);
        for (size_t i = 0; i < payload_size; ++i) {
            payload[i] = (unsigned char)((i * 31u + 7u) & 0xffu);
        }
        ssize_t written = elisa_lsp_analysis_worker_write(payload, payload_size);
        free(payload);
        elisa_lsp_analysis_worker_child_exit(
            isolated && written == (ssize_t)payload_size ? 0 : 22);
    }
    if (!check(started == 0, "start the large-stream analysis worker")) {
        for (size_t i = 0;
             i < sizeof(child_test_signals) / sizeof(child_test_signals[0]); ++i) {
            (void)sigaction(child_test_signals[i], &original_actions[i], NULL);
        }
        (void)sigprocmask(SIG_SETMASK, &original_mask, NULL);
        close(sentinel_fd);
        return 0;
    }

    unsigned char *received = malloc(payload_size);
    if (!check(received != NULL, "allocate the parent receive buffer")) {
        elisa_lsp_analysis_worker_abort();
        for (size_t i = 0;
             i < sizeof(child_test_signals) / sizeof(child_test_signals[0]); ++i) {
            (void)sigaction(child_test_signals[i], &original_actions[i], NULL);
        }
        (void)sigprocmask(SIG_SETMASK, &original_mask, NULL);
        close(sentinel_fd);
        return 0;
    }

    size_t offset = 0;
    int stream_ok = 1;
    while (offset < payload_size) {
        size_t amount = payload_size - offset;
        if (amount > 32768u) amount = 32768u;
        ssize_t received_count = elisa_lsp_analysis_worker_read(
            received + offset, amount);
        if (received_count <= 0) {
            stream_ok = 0;
            break;
        }
        offset += (size_t)received_count;
    }
    unsigned char extra = 0;
    ssize_t eof = stream_ok
        ? elisa_lsp_analysis_worker_read(&extra, 1)
        : -1;

    int data_ok = stream_ok && offset == payload_size && eof == 0;
    for (size_t i = 0; data_ok && i < payload_size; ++i) {
        if (received[i] != (unsigned char)((i * 31u + 7u) & 0xffu)) data_ok = 0;
    }
    free(received);

    int finish = elisa_lsp_analysis_worker_finish();
    int restored = 1;
    for (size_t i = 0;
         i < sizeof(child_test_signals) / sizeof(child_test_signals[0]); ++i) {
        if (sigaction(child_test_signals[i], &original_actions[i], NULL) != 0) {
            restored = 0;
        }
    }
    if (sigprocmask(SIG_SETMASK, &original_mask, NULL) != 0) restored = 0;
    close(sentinel_fd);
    return check(data_ok, "stream more than pipe capacity without corruption") &&
           check(finish == 0, "finish and reap a successful worker") &&
           check(restored, "restore the parent SIGTERM handler") &&
           check(!worker_active, "successful finish clears the active-worker state");
}

static int test_abnormal_exit(void) {
    int started = elisa_lsp_analysis_worker_begin(2000);
    if (started == 1) elisa_lsp_analysis_worker_child_exit(23);
    if (!check(started == 0, "start abnormal-exit worker")) return 0;

    unsigned char byte = 0;
    ssize_t eof = elisa_lsp_analysis_worker_read(&byte, 1);
    int finish = elisa_lsp_analysis_worker_finish();
    return check(eof == 0, "abnormal child exit closes the result pipe") &&
           check(finish < 0 && errno == ECHILD,
                 "finish rejects a child with nonzero exit status") &&
           check(!worker_active, "abnormal finish clears worker state");
}

static int test_timeout_kills_and_reaps(void) {
    int started = elisa_lsp_analysis_worker_begin(150);
    if (started == 1) {
        for (;;) pause();
    }
    if (!check(started == 0, "start timeout worker")) return 0;

    pid_t child = worker_pid;
    unsigned char byte = 0;
    double started_at = monotonic_seconds();
    ssize_t result = elisa_lsp_analysis_worker_read(&byte, 1);
    int read_errno = errno;
    double elapsed = monotonic_seconds() - started_at;
    int status = 0;
    pid_t after_abort = waitpid(child, &status, WNOHANG);
    int wait_errno = errno;
    return check(result < 0 && read_errno == ETIMEDOUT,
                 "read reports the shared monotonic deadline") &&
           check(elapsed >= 0.10 && elapsed < 2.0,
                 "worker timeout is bounded near its configured deadline") &&
           check(after_abort < 0 && wait_errno == ECHILD,
                 "timeout kills and reaps the child") &&
           check(!worker_active, "timeout cleanup clears worker state");
}

static int test_pending_termination_kills_and_reaps(void) {
    int started = elisa_lsp_analysis_worker_begin(5000);
    if (started == 1) {
        for (;;) pause();
    }
    if (!check(started == 0, "start termination worker")) return 0;

    pid_t child = worker_pid;
    pending_termination = SIGTERM;
    unsigned char byte = 0;
    double started_at = monotonic_seconds();
    ssize_t result = elisa_lsp_analysis_worker_read(&byte, 1);
    int read_errno = errno;
    double elapsed = monotonic_seconds() - started_at;
    pending_termination = 0;
    int status = 0;
    pid_t after_abort = waitpid(child, &status, WNOHANG);
    int wait_errno = errno;
    return check(result < 0 && read_errno == EINTR,
                 "pending server termination interrupts the read") &&
           check(elapsed < 1.0, "pending termination is observed promptly") &&
           check(after_abort < 0 && wait_errno == ECHILD,
                 "termination cleanup kills and reaps the child") &&
           check(!worker_active, "termination cleanup clears worker state");
}

static int test_active_worker_guard_and_abort(void) {
    int started = elisa_lsp_analysis_worker_begin(2000);
    if (started == 1) {
        for (;;) pause();
    }
    if (!check(started == 0, "start active-worker guard case")) return 0;

    pid_t child = worker_pid;
    int second = elisa_lsp_analysis_worker_begin(2000);
    int second_errno = errno;
    elisa_lsp_analysis_worker_abort();
    int status = 0;
    pid_t after_abort = waitpid(child, &status, WNOHANG);
    int wait_errno = errno;
    return check(second < 0 && second_errno == EBUSY,
                 "only one worker can be active") &&
           check(after_abort < 0 && wait_errno == ECHILD,
                 "explicit abort kills and reaps the active child") &&
           check(!worker_active, "explicit abort clears worker state");
}

static int test_repeated_worker_cycles(void) {
    for (int cycle = 0; cycle < 6; ++cycle) {
        int started = elisa_lsp_analysis_worker_begin(2000);
        if (started == 1) {
            static const char payload[] = "worker-cycle";
            ssize_t written = elisa_lsp_analysis_worker_write(
                payload, sizeof(payload));
            elisa_lsp_analysis_worker_child_exit(
                written == (ssize_t)sizeof(payload) ? 0 : 31);
        }
        if (!check(started == 0, "start a repeated worker cycle")) return 0;

        char payload[sizeof("worker-cycle")];
        size_t offset = 0;
        for (;;) {
            ssize_t received = elisa_lsp_analysis_worker_read(
                payload + offset, sizeof(payload) - offset);
            if (received < 0) {
                elisa_lsp_analysis_worker_abort();
                return check(0, "read a repeated worker cycle");
            }
            if (received == 0) break;
            offset += (size_t)received;
            if (offset == sizeof(payload)) {
                char extra;
                if (elisa_lsp_analysis_worker_read(&extra, 1) != 0) {
                    elisa_lsp_analysis_worker_abort();
                    return check(0, "observe EOF in a repeated worker cycle");
                }
                break;
            }
        }
        int payload_ok = offset == sizeof(payload) &&
                         memcmp(payload, "worker-cycle", sizeof(payload)) == 0;
        int finish_result = elisa_lsp_analysis_worker_finish();
        if (!check(payload_ok,
                   "repeated worker cycle returns its complete payload") ||
            !check(finish_result == 0,
                   "repeated worker cycle finishes cleanly")) return 0;
    }
    return 1;
}

static int test_wait_event_multiplexes_input_and_worker(void) {
    int input_pipe[2] = {-1, -1};
    int saved_stdin = -1;
    int okay = 0;
    if (pipe(input_pipe) != 0) goto cleanup;
    saved_stdin = dup(STDIN_FILENO);
    if (saved_stdin < 0 || dup2(input_pipe[0], STDIN_FILENO) < 0) goto cleanup;
    close(input_pipe[0]);
    input_pipe[0] = -1;
    if (write(input_pipe[1], "I", 1) != 1) goto cleanup;

    int started = elisa_lsp_analysis_worker_begin(2000);
    if (started == 1) {
        static const char worker_byte[] = "W";
        ssize_t written = elisa_lsp_analysis_worker_write(worker_byte, 1);
        elisa_lsp_analysis_worker_child_exit(written == 1 ? 0 : 31);
    }
    if (started != 0) goto cleanup;

    struct pollfd worker_descriptor = {
        .fd = worker_read_fd,
        .events = POLLIN | POLLHUP | POLLERR,
        .revents = 0
    };
    if (poll(&worker_descriptor, 1, 2000) <= 0) goto cleanup;
    int events = elisa_lsp_analysis_worker_wait_event(0);
    if ((events & (ELISA_LSP_EVENT_INPUT | ELISA_LSP_EVENT_WORKER)) !=
        (ELISA_LSP_EVENT_INPUT | ELISA_LSP_EVENT_WORKER)) goto cleanup;

    char input_byte = 0;
    char worker_byte = 0;
    char extra = 0;
    if (read(STDIN_FILENO, &input_byte, 1) != 1 || input_byte != 'I') goto cleanup;
    if (elisa_lsp_analysis_worker_read(&worker_byte, 1) != 1 || worker_byte != 'W') goto cleanup;
    if (elisa_lsp_analysis_worker_read(&extra, 1) != 0) goto cleanup;
    if (elisa_lsp_analysis_worker_finish() != 0) goto cleanup;
    okay = 1;

cleanup:
    if (worker_active) elisa_lsp_analysis_worker_abort();
    if (saved_stdin >= 0) {
        if (dup2(saved_stdin, STDIN_FILENO) < 0) okay = 0;
        close(saved_stdin);
    }
    if (input_pipe[0] >= 0) close(input_pipe[0]);
    if (input_pipe[1] >= 0) close(input_pipe[1]);
    return check(okay,
                 "parent event wait reports client input and worker readiness together");
}

static int test_wait_event_reports_independent_readiness(void) {
    int input_pipe[2] = {-1, -1};
    int saved_stdin = -1;
    int okay = 0;
    if (pipe(input_pipe) != 0) goto cleanup;
    saved_stdin = dup(STDIN_FILENO);
    if (saved_stdin < 0 || dup2(input_pipe[0], STDIN_FILENO) < 0) goto cleanup;
    close(input_pipe[0]);
    input_pipe[0] = -1;

    if (write(input_pipe[1], "I", 1) != 1) goto cleanup;
    int input_events = elisa_lsp_analysis_worker_wait_event(0);
    if (input_events != ELISA_LSP_EVENT_INPUT) goto cleanup;
    char input_byte = 0;
    if (read(STDIN_FILENO, &input_byte, 1) != 1 || input_byte != 'I') goto cleanup;

    int started = elisa_lsp_analysis_worker_begin(2000);
    if (started == 1) {
        static const char worker_byte[] = "W";
        ssize_t written = elisa_lsp_analysis_worker_write(worker_byte, 1);
        elisa_lsp_analysis_worker_child_exit(written == 1 ? 0 : 32);
    }
    if (started != 0) goto cleanup;
    int worker_events = elisa_lsp_analysis_worker_wait_event(2000);
    if (worker_events != ELISA_LSP_EVENT_WORKER) goto cleanup;

    char worker_byte = 0;
    char extra = 0;
    if (elisa_lsp_analysis_worker_read(&worker_byte, 1) != 1 || worker_byte != 'W') goto cleanup;
    if (elisa_lsp_analysis_worker_read(&extra, 1) != 0) goto cleanup;
    if (elisa_lsp_analysis_worker_finish() != 0) goto cleanup;
    okay = 1;

cleanup:
    if (worker_active) elisa_lsp_analysis_worker_abort();
    if (saved_stdin >= 0) {
        if (dup2(saved_stdin, STDIN_FILENO) < 0) okay = 0;
        close(saved_stdin);
    }
    if (input_pipe[0] >= 0) close(input_pipe[0]);
    if (input_pipe[1] >= 0) close(input_pipe[1]);
    return check(okay,
                 "parent event wait reports input-only and worker-only readiness");
}

static int test_wait_event_reports_worker_deadline(void) {
    int input_pipe[2] = {-1, -1};
    int saved_stdin = -1;
    int okay = 0;
    if (pipe(input_pipe) != 0) goto cleanup;
    saved_stdin = dup(STDIN_FILENO);
    if (saved_stdin < 0 || dup2(input_pipe[0], STDIN_FILENO) < 0) goto cleanup;
    close(input_pipe[0]);
    input_pipe[0] = -1;

    int started = elisa_lsp_analysis_worker_begin(150);
    if (started == 1) {
        for (;;) pause();
    }
    if (started != 0) goto cleanup;
    int idle_events = elisa_lsp_analysis_worker_wait_event(20);
    if (idle_events != 0 || !worker_active) goto cleanup;
    int events = elisa_lsp_analysis_worker_wait_event(-1);
    if (events != ELISA_LSP_EVENT_WORKER_DEADLINE) {
        fprintf(stderr, "worker deadline wait returned events=%d errno=%d\n", events, errno);
        goto cleanup;
    }
    elisa_lsp_analysis_worker_abort();
    okay = 1;

cleanup:
    if (worker_active) elisa_lsp_analysis_worker_abort();
    if (saved_stdin >= 0) {
        if (dup2(saved_stdin, STDIN_FILENO) < 0) okay = 0;
        close(saved_stdin);
    }
    if (input_pipe[0] >= 0) close(input_pipe[0]);
    if (input_pipe[1] >= 0) close(input_pipe[1]);
    return check(okay,
                 "parent event wait reports an expired active-worker deadline");
}

static int test_incremental_read_and_nonblocking_reap(void) {
    static const unsigned char message[] = "incremental-worker-packet";
    unsigned char received[sizeof(message)] = {0};
    size_t received_count = 0;
    int input_pipe[2] = {-1, -1};
    int saved_stdin = -1;
    if (pipe(input_pipe) != 0) return check(0, "create idle stdin for incremental worker test");
    saved_stdin = dup(STDIN_FILENO);
    if (saved_stdin < 0 || dup2(input_pipe[0], STDIN_FILENO) < 0) {
        if (saved_stdin >= 0) close(saved_stdin);
        close(input_pipe[0]);
        close(input_pipe[1]);
        return check(0, "install idle stdin for incremental worker test");
    }
    close(input_pipe[0]);
    input_pipe[0] = -1;
    int started = elisa_lsp_analysis_worker_begin(3000);
    if (started == 1) {
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000L};
        while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
        if (elisa_lsp_analysis_worker_write(message, sizeof(message)) < 0) {
            elisa_lsp_analysis_worker_child_exit(74);
        }
        elisa_lsp_analysis_worker_child_exit(0);
    }
    if (!check(started == 0, "start an incremental analysis worker")) goto cleanup;
    unsigned char byte = 0;
    ssize_t early = elisa_lsp_analysis_worker_read_available(&byte, 1);
    if (!check(early == -2 && worker_active,
               "incremental read returns immediately when no packet bytes are ready")) {
        goto cleanup;
    }

    int saw_eof = 0;
    while (!saw_eof) {
        int events = elisa_lsp_analysis_worker_wait_event(1000);
        if (events < 0 || (events & ELISA_LSP_EVENT_WORKER) == 0) {
            check(0, "incremental packet wait reports worker readiness");
            goto cleanup;
        }
        unsigned char chunk[5];
        ssize_t count = elisa_lsp_analysis_worker_read_available(chunk, sizeof(chunk));
        if (count == -2) continue;
        if (count < 0) {
            check(0, "incremental packet read remains healthy");
            goto cleanup;
        }
        if (count == 0) {
            saw_eof = 1;
            break;
        }
        if ((size_t)count > sizeof(received) - received_count) {
            check(0, "incremental packet remains within its receive buffer");
            goto cleanup;
        }
        memcpy(received + received_count, chunk, (size_t)count);
        received_count += (size_t)count;
    }

    int finish = 0;
    while (finish == 0) {
        finish = elisa_lsp_analysis_worker_try_finish();
        if (finish == 0) {
            int events = elisa_lsp_analysis_worker_wait_event(1000);
            if (events < 0 || (events & ELISA_LSP_EVENT_WORKER_EOF) == 0) {
                check(0, "EOF wait stays responsive while the child exits");
                goto cleanup;
            }
        }
    }
    int okay = check(finish == 1 && !worker_active &&
                     received_count == sizeof(message) &&
                     memcmp(received, message, sizeof(message)) == 0,
                     "incremental packet bytes are preserved and child reaping never blocks");
    if (saved_stdin >= 0) {
        if (dup2(saved_stdin, STDIN_FILENO) < 0) okay = 0;
        close(saved_stdin);
    }
    close(input_pipe[1]);
    return okay;

cleanup:
    if (worker_active) elisa_lsp_analysis_worker_abort();
    if (saved_stdin >= 0) {
        (void)dup2(saved_stdin, STDIN_FILENO);
        close(saved_stdin);
    }
    if (input_pipe[0] >= 0) close(input_pipe[0]);
    if (input_pipe[1] >= 0) close(input_pipe[1]);
    return 0;
}

static int test_incremental_reap_rejects_abnormal_exit(void) {
    int input_pipe[2] = {-1, -1};
    int saved_stdin = -1;
    int okay = 0;
    if (pipe(input_pipe) != 0) goto cleanup;
    saved_stdin = dup(STDIN_FILENO);
    if (saved_stdin < 0 || dup2(input_pipe[0], STDIN_FILENO) < 0) goto cleanup;
    close(input_pipe[0]);
    input_pipe[0] = -1;

    int started = elisa_lsp_analysis_worker_begin(3000);
    if (started == 1) elisa_lsp_analysis_worker_child_exit(74);
    if (started != 0) goto cleanup;

    int saw_eof = 0;
    while (!saw_eof) {
        int events = elisa_lsp_analysis_worker_wait_event(1000);
        if (events < 0 || (events & ELISA_LSP_EVENT_WORKER) == 0) goto cleanup;
        unsigned char byte = 0;
        ssize_t count = elisa_lsp_analysis_worker_read_available(&byte, 1);
        if (count == -2) continue;
        if (count < 0) goto cleanup;
        saw_eof = count == 0;
    }

    int finish = 0;
    while (finish == 0) {
        finish = elisa_lsp_analysis_worker_try_finish();
        if (finish == 0) {
            int events = elisa_lsp_analysis_worker_wait_event(1000);
            if (events < 0 || (events & ELISA_LSP_EVENT_WORKER_EOF) == 0) goto cleanup;
        }
    }
    okay = finish == -1 && errno == ECHILD && !worker_active;

cleanup:
    if (worker_active) elisa_lsp_analysis_worker_abort();
    if (saved_stdin >= 0) {
        if (dup2(saved_stdin, STDIN_FILENO) < 0) okay = 0;
        close(saved_stdin);
    }
    if (input_pipe[0] >= 0) close(input_pipe[0]);
    if (input_pipe[1] >= 0) close(input_pipe[1]);
    return check(okay,
                 "incremental child reap rejects nonzero worker exit status");
}

int main(void) {
    if (!check_timeout_configuration()) return 1;
    if (!test_large_stream_success()) return 1;
    if (!test_abnormal_exit()) return 1;
    if (!test_timeout_kills_and_reaps()) return 1;
    if (!test_pending_termination_kills_and_reaps()) return 1;
    if (!test_active_worker_guard_and_abort()) return 1;
    if (!test_repeated_worker_cycles()) return 1;
    if (!test_wait_event_multiplexes_input_and_worker()) return 1;
    if (!test_wait_event_reports_independent_readiness()) return 1;
    if (!test_wait_event_reports_worker_deadline()) return 1;
    if (!test_incremental_read_and_nonblocking_reap()) return 1;
    if (!test_incremental_reap_rejects_abnormal_exit()) return 1;
    puts("POSIX analysis worker OK: isolation, streamed output, incremental reads, nonblocking reap, independent and simultaneous event readiness, deadline, exit validation, termination, abort, and reuse");
    return 0;
}
