#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "../src/transport_posix.c"

static int check(int ok, const char *message) {
    if (!ok) fprintf(stderr, "FAIL: %s\n", message);
    return ok;
}

static double monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static pid_t start_term_sender(pid_t target) {
    pid_t child = fork();
    if (child != 0) return child;
    struct timespec delay = {0, 80000000L};
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
    if (kill(target, SIGTERM) != 0) _exit(10);
    _exit(0);
}

static int make_stalled_stdout(int read_pipe[2], int *original_flags) {
    int write_pipe[2];
    if (pipe(write_pipe) != 0) return -1;
    read_pipe[0] = write_pipe[0];
    if (dup2(write_pipe[1], STDOUT_FILENO) < 0) return -1;
    close(write_pipe[1]);
    *original_flags = fcntl(STDOUT_FILENO, F_GETFL);
    return *original_flags < 0 ? -1 : 0;
}

static int check_timeout_configuration(void) {
    unsetenv("ELISA_LSP_WRITE_TIMEOUT_MS");
    if (!check(elisa_lsp_write_timeout_millis() == 15000,
               "output deadline has a 15-second default")) return 0;
    if (setenv("ELISA_LSP_WRITE_TIMEOUT_MS", "100", 1) != 0 ||
        !check(elisa_lsp_write_timeout_millis() == 100,
               "output deadline accepts its minimum")) return 0;
    if (setenv("ELISA_LSP_WRITE_TIMEOUT_MS", "120000", 1) != 0 ||
        !check(elisa_lsp_write_timeout_millis() == 120000,
               "output deadline accepts its maximum")) return 0;
    const char *invalid[] = {"", "99", "120001", "-1", "1x"};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        if (setenv("ELISA_LSP_WRITE_TIMEOUT_MS", invalid[i], 1) != 0 ||
            !check(elisa_lsp_write_timeout_millis() < 0,
                   "invalid output deadline settings are rejected")) return 0;
    }
    unsetenv("ELISA_LSP_WRITE_TIMEOUT_MS");
    return 1;
}

int main(void) {
    if (!check_timeout_configuration()) return 1;
    int read_pipe[2];
    int original_flags = -1;
    if (!check(make_stalled_stdout(read_pipe, &original_flags) == 0,
               "create a stalled stdout pipe")) return 1;
    if (!check(elisa_lsp_install_termination_handlers() == 0,
               "install signal adapter before output")) return 1;

    size_t payload_size = 8u * 1024u * 1024u;
    unsigned char *payload = malloc(payload_size);
    if (!check(payload != NULL, "allocate output payload")) return 1;
    memset(payload, 'x', payload_size);
    int begin_result = elisa_lsp_output_begin(STDOUT_FILENO, 200);
    if (!check(begin_result == 0, "begin one bounded output frame")) return 1;
    double started = monotonic_seconds();
    ssize_t result = elisa_lsp_write_all(STDOUT_FILENO, payload, payload_size, 200);
    int timeout_errno = errno;
    double elapsed = monotonic_seconds() - started;
    if (!check((fcntl(STDOUT_FILENO, F_GETFL) & O_NONBLOCK) != 0,
               "stdout becomes nonblocking for the output frame")) return 1;
    if (!check(result < 0 && timeout_errno == ETIMEDOUT,
               "a stalled output pipe must end with ETIMEDOUT")) return 1;
    if (!check(elapsed >= 0.15 && elapsed < 2.0,
               "the configured output deadline must be honored")) return 1;
    if (!check(elisa_lsp_output_end(STDOUT_FILENO) == 0,
               "end the timed-out frame and restore descriptor state")) return 1;
    int restored_flags = fcntl(STDOUT_FILENO, F_GETFL);
    if (!check(restored_flags >= 0 &&
               (restored_flags & O_NONBLOCK) == (original_flags & O_NONBLOCK),
               "output frame restores the original blocking mode")) return 1;

    if (!check(elisa_lsp_restore_termination_handlers() == 0,
               "restore signal state after timeout")) return 1;

    if (!check(elisa_lsp_install_termination_handlers() == 0,
               "reinstall adapter for signal interruption")) return 1;
    pid_t sender = start_term_sender(getpid());
    if (!check(sender > 0, "start termination sender")) return 1;
    started = monotonic_seconds();
    result = elisa_lsp_write_all(STDOUT_FILENO, payload, payload_size, 10000);
    int signal_errno = errno;
    elapsed = monotonic_seconds() - started;
    restored_flags = fcntl(STDOUT_FILENO, F_GETFL);
    if (!check(restored_flags >= 0 &&
               (restored_flags & O_NONBLOCK) == (original_flags & O_NONBLOCK),
               "signal-interrupted write restores original blocking mode")) return 1;
    int child_status = 0;
    if (!check(waitpid(sender, &child_status, 0) == sender &&
               WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0,
               "termination sender exits cleanly")) return 1;
    if (!check(result < 0 && signal_errno == EINTR && elapsed < 2.0,
               "a termination signal must interrupt stalled output promptly")) return 1;
    if (!check(elisa_lsp_pending_termination_signal() == SIGTERM,
               "stalled-write termination signal remains observable")) return 1;
    if (!check(elisa_lsp_restore_termination_handlers() == 0,
               "restore signal state after interrupted output")) return 1;

    close(read_pipe[0]);
    free(payload);
    fprintf(stderr, "POSIX output backpressure OK: deadline, SIGTERM, and stdout flag restoration\n");
    return 0;
}
