#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int elisa_lsp_install_termination_handlers(void);
int elisa_lsp_pending_termination_signal(void);
int elisa_lsp_restore_termination_handlers(void);
ssize_t elisa_lsp_read_retry(int fd, void *buffer, size_t count);

static volatile sig_atomic_t prior_term_signal = 0;
static volatile sig_atomic_t unrelated_signal_count = 0;

static void prior_term_handler(int signal_number) {
    prior_term_signal = (sig_atomic_t)signal_number;
}

static void unrelated_signal_handler(int signal_number) {
    (void)signal_number;
    unrelated_signal_count += 1;
}

static int check(int ok, const char *message) {
    if (!ok) fprintf(stderr, "FAIL: %s (errno=%d)\n", message, errno);
    return ok;
}

static int pause_for_ms(long milliseconds) {
    struct timespec remaining = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000000L,
    };
    while (nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR) return -1;
    }
    return 0;
}

/* Send one signal while the parent is blocked, then write a fallback byte.
 * The fallback keeps a broken retry loop bounded and distinguishes a prompt
 * termination interruption from a read that incorrectly resumed. */
static pid_t start_signal_sender(pid_t parent, int read_fd, int write_fd,
                                int signal_number) {
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        (void)close(read_fd);
        if (pause_for_ms(60) != 0 || kill(parent, signal_number) != 0) _exit(10);
        if (pause_for_ms(140) != 0) _exit(11);
        const unsigned char byte = 'x';
        ssize_t written;
        do {
            written = write(write_fd, &byte, 1);
        } while (written < 0 && errno == EINTR);
        (void)close(write_fd);
        _exit(written == 1 ? 0 : 12);
    }
    (void)close(write_fd);
    return child;
}

static int wait_for_child(pid_t child) {
    int status = 0;
    pid_t result;
    do {
        result = waitpid(child, &status, 0);
    } while (result < 0 && errno == EINTR);
    return result == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int check_mask_restored(const sigset_t *expected) {
    sigset_t actual;
    if (sigprocmask(SIG_SETMASK, NULL, &actual) != 0) return 0;
    const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGUSR1};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        int want = sigismember(expected, signals[i]);
        int got = sigismember(&actual, signals[i]);
        if (want < 0 || got < 0 || want != got) return 0;
    }
    return 1;
}

int main(void) {
    struct sigaction original_int;
    struct sigaction original_term;
    struct sigaction original_hup;
    struct sigaction original_usr1;
    struct sigaction custom_term = {0};
    struct sigaction unrelated = {0};
    sigset_t original_mask;
    sigset_t adapter_mask;

    if (!check(sigaction(SIGINT, NULL, &original_int) == 0 &&
               sigaction(SIGTERM, NULL, &original_term) == 0 &&
               sigaction(SIGHUP, NULL, &original_hup) == 0 &&
               sigaction(SIGUSR1, NULL, &original_usr1) == 0 &&
               sigprocmask(SIG_SETMASK, NULL, &original_mask) == 0,
               "capture original signal state")) return 1;

    /* Keep the unrelated signal deliverable so its interruption exercises the
     * normal EINTR retry path even when the test runner supplied a mask. */
    adapter_mask = original_mask;
    if (!check(sigdelset(&adapter_mask, SIGUSR1) == 0 &&
               sigprocmask(SIG_SETMASK, &adapter_mask, NULL) == 0,
               "prepare test signal mask")) return 1;

    custom_term.sa_handler = prior_term_handler;
    unrelated.sa_handler = unrelated_signal_handler;
    if (!check(sigemptyset(&custom_term.sa_mask) == 0 &&
               sigemptyset(&unrelated.sa_mask) == 0 &&
               sigaction(SIGTERM, &custom_term, NULL) == 0 &&
               sigaction(SIGUSR1, &unrelated, NULL) == 0,
               "install test handlers before adapter setup")) return 1;

    if (!check(elisa_lsp_pending_termination_signal() == 0,
               "termination state starts clear")) return 1;
    if (!check(elisa_lsp_install_termination_handlers() == 0,
               "install termination handlers")) return 1;
    if (!check(elisa_lsp_install_termination_handlers() == 0,
               "installation is idempotent")) return 1;
    if (!check(elisa_lsp_pending_termination_signal() == 0,
               "installation does not invent a pending signal")) return 1;

    /* Ordinary EINTR remains retryable: SIGUSR1 wakes pselect, and the
     * eventual byte is still returned by the read helper. */
    int ordinary_pipe[2];
    if (!check(pipe(ordinary_pipe) == 0, "create ordinary-EINTR pipe")) return 1;
    pid_t sender = start_signal_sender(getpid(), ordinary_pipe[0],
                                       ordinary_pipe[1], SIGUSR1);
    if (!check(sender > 0, "start ordinary-EINTR signal sender")) return 1;
    unsigned char byte = 0;
    ssize_t received = elisa_lsp_read_retry(ordinary_pipe[0], &byte, 1);
    int read_errno = errno;
    int read_flags = fcntl(ordinary_pipe[0], F_GETFL);
    if (!check(read_flags >= 0 && (read_flags & O_NONBLOCK) != 0,
               "input fd is nonblocking across the pselect/read gap")) return 1;
    if (!check(received == 1 && byte == 'x',
               "ordinary EINTR retries until the pipe becomes readable")) return 1;
    if (!check(read_errno == EINTR && unrelated_signal_count == 1,
               "ordinary signal interrupted the wait before retry")) return 1;
    if (!check(elisa_lsp_pending_termination_signal() == 0,
               "unrelated signal does not set termination state")) return 1;
    if (!check(wait_for_child(sender), "ordinary-EINTR sender exits cleanly")) return 1;
    if (!check(elisa_lsp_restore_termination_handlers() == 0,
               "restore after ordinary interrupted read")) return 1;
    read_flags = fcntl(ordinary_pipe[0], F_GETFL);
    if (!check(read_flags >= 0 && (read_flags & O_NONBLOCK) == 0,
               "ordinary-read input blocking mode is restored")) return 1;
    (void)close(ordinary_pipe[0]);

    /* A termination signal must interrupt the blocked read promptly instead
     * of retrying until the fallback byte appears. */
    int termination_pipe[2];
    if (!check(pipe(termination_pipe) == 0, "create termination pipe")) return 1;
    if (!check(elisa_lsp_install_termination_handlers() == 0,
               "reinstall handlers for termination read")) return 1;
    sender = start_signal_sender(getpid(), termination_pipe[0],
                                 termination_pipe[1], SIGTERM);
    if (!check(sender > 0, "start termination signal sender")) return 1;
    byte = 0;
    errno = 0;
    received = elisa_lsp_read_retry(termination_pipe[0], &byte, 1);
    read_errno = errno;
    if (!check(received == -1 && read_errno == EINTR,
               "termination signal returns EINTR without waiting for fallback data")) return 1;
    if (!check(elisa_lsp_pending_termination_signal() == SIGTERM,
               "termination signal number is queryable")) return 1;
    if (!check(wait_for_child(sender), "termination sender exits cleanly")) return 1;
    if (!check(read(termination_pipe[0], &byte, 1) == 1 && byte == 'x',
               "termination test fallback byte remains unread")) return 1;

    if (!check(raise(SIGINT) == 0 &&
               elisa_lsp_pending_termination_signal() == SIGTERM,
               "first termination signal remains stable")) return 1;

    if (!check(elisa_lsp_restore_termination_handlers() == 0,
               "restore original signal handlers and mask")) return 1;
    if (!check(elisa_lsp_restore_termination_handlers() == 0,
               "restoration is idempotent")) return 1;
    if (!check(check_mask_restored(&adapter_mask),
               "termination signal mask was restored")) return 1;
    read_flags = fcntl(termination_pipe[0], F_GETFL);
    if (!check(read_flags >= 0 && (read_flags & O_NONBLOCK) == 0,
               "input fd blocking mode is restored")) return 1;
    (void)close(termination_pipe[0]);

    prior_term_signal = 0;
    sigset_t term_unblocked_mask = adapter_mask;
    if (!check(sigdelset(&term_unblocked_mask, SIGTERM) == 0 &&
               sigprocmask(SIG_SETMASK, &term_unblocked_mask, NULL) == 0,
               "make restored SIGTERM handler deliverable")) return 1;
    if (!check(raise(SIGTERM) == 0 && prior_term_signal == SIGTERM,
               "preexisting SIGTERM handler is restored")) return 1;

    /* Restore the test process's own state before exiting. */
    if (!check(sigaction(SIGINT, &original_int, NULL) == 0 &&
               sigaction(SIGTERM, &original_term, NULL) == 0 &&
               sigaction(SIGHUP, &original_hup, NULL) == 0 &&
               sigaction(SIGUSR1, &original_usr1, NULL) == 0 &&
               sigprocmask(SIG_SETMASK, &original_mask, NULL) == 0,
               "restore process signal state")) return 1;

    puts("POSIX termination adapter OK: sigaction setup, EINTR retry, prompt termination, query, and restoration");
    return 0;
}
