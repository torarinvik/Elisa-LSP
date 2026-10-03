#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>

ssize_t test_write(int fd, const void *buffer, size_t count);
ssize_t test_read(int fd, void *buffer, size_t count);
#define read test_read
#define write test_write
#include "../src/transport_posix.c"
#undef write
#undef read

static int mode;
static int calls;
static unsigned char sink[64];
static size_t sink_length;
static int read_mode;
static int read_calls;

enum { MODE_SHORT_WITH_EINTR = 1, MODE_ZERO = 2, MODE_ERROR = 3 };
enum { READ_MODE_DATA_WITH_EINTR = 1, READ_MODE_EOF = 2, READ_MODE_ERROR = 3 };

ssize_t test_read(int fd, void *buffer, size_t count) {
    (void)fd;
    read_calls += 1;
    if (read_mode == READ_MODE_DATA_WITH_EINTR) {
        if (read_calls == 1) {
            errno = EINTR;
            return -1;
        }
        const char data[] = "input";
        size_t take = count < sizeof(data) - 1 ? count : sizeof(data) - 1;
        memcpy(buffer, data, take);
        return (ssize_t)take;
    }
    if (read_mode == READ_MODE_EOF) return 0;
    errno = EIO;
    return -1;
}

ssize_t test_write(int fd, const void *buffer, size_t count) {
    (void)fd;
    calls += 1;
    if (mode == MODE_SHORT_WITH_EINTR) {
        if (calls == 1) {
            errno = EINTR;
            return -1;
        }
        size_t take = count;
        if (calls == 2 && take > 1) take = 1;
        if (calls == 3 && take > 2) take = 2;
        if (take > sizeof(sink) - sink_length) take = sizeof(sink) - sink_length;
        memcpy(sink + sink_length, buffer, take);
        sink_length += take;
        return (ssize_t)take;
    }
    if (mode == MODE_ZERO) return 0;
    errno = EPIPE;
    return -1;
}

static int check(int ok, const char *message) {
    if (!ok) fprintf(stderr, "FAIL: %s\n", message);
    return ok;
}

int main(void) {
    unsigned char input[8] = {0};
    read_mode = READ_MODE_DATA_WITH_EINTR;
    read_calls = 0;
    ssize_t read_result = elisa_lsp_read_retry(0, input, sizeof(input));
    if (!check(read_result == 5 && read_calls == 2, "EINTR must be retried before input")) return 1;
    if (!check(memcmp(input, "input", 5) == 0, "retried input bytes must be preserved")) return 1;
    read_mode = READ_MODE_EOF;
    read_calls = 0;
    read_result = elisa_lsp_read_retry(0, input, sizeof(input));
    if (!check(read_result == 0 && read_calls == 1, "EOF must remain distinct from an error")) return 1;
    read_mode = READ_MODE_ERROR;
    read_calls = 0;
    read_result = elisa_lsp_read_retry(0, input, sizeof(input));
    if (!check(read_result < 0 && errno == EIO && read_calls == 1,
               "terminal read errors must not be retried as EOF")) return 1;

    const unsigned char payload[] = "Content-Length: 5\r\n\r\nhello";
    mode = MODE_SHORT_WITH_EINTR;
    calls = 0;
    sink_length = 0;
    ssize_t result = elisa_lsp_write_retry(1, payload, sizeof(payload) - 1);
    if (!check(result == 1, "EINTR must be retried before a short write")) return 1;
    if (!check(calls == 2, "one helper call retries EINTR then returns the short write")) return 1;
    size_t written = (size_t)result;
    while (written < sizeof(payload) - 1) {
        result = elisa_lsp_write_retry(1, payload + written, sizeof(payload) - 1 - written);
        if (!check(result > 0, "short writes must make forward progress")) return 1;
        written += (size_t)result;
    }
    if (!check(sink_length == sizeof(payload) - 1, "all bytes must be reconstructed")) return 1;
    if (!check(memcmp(sink, payload, sink_length) == 0, "reconstructed frame bytes must match")) return 1;

    mode = MODE_SHORT_WITH_EINTR;
    calls = 0;
    sink_length = 0;
    ssize_t complete = elisa_lsp_write_all(1, payload, sizeof(payload) - 1, 100);
    if (!check(complete == (ssize_t)(sizeof(payload) - 1),
               "complete-write helper must finish across EINTR and short writes")) return 1;
    if (!check(sink_length == sizeof(payload) - 1 &&
               memcmp(sink, payload, sink_length) == 0,
               "complete-write helper must preserve the exact byte stream")) return 1;

    mode = MODE_ZERO;
    calls = 0;
    result = elisa_lsp_write_retry(1, payload, sizeof(payload) - 1);
    if (!check(result == 0 && calls == 1, "zero progress must return without looping")) return 1;

    mode = MODE_ERROR;
    calls = 0;
    result = elisa_lsp_write_retry(1, payload, sizeof(payload) - 1);
    if (!check(result < 0 && errno == EPIPE && calls == 1,
               "terminal pipe errors must return without retrying")) return 1;
    puts("POSIX I/O helpers OK: read/write EINTR, EOF/error, short writes, zero progress, and EPIPE");
    return 0;
}
