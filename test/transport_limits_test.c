#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/transport_posix.c"

static int check(long long actual, long long expected, const char *label) {
    if (actual == expected) return 1;
    fprintf(stderr, "FAIL: %s: got %lld expected %lld\n", label, actual, expected);
    return 0;
}

static int set_limit(const char *name, const char *value) {
    return value == NULL ? unsetenv(name) : setenv(name, value, 1);
}

int main(void) {
    if (set_limit("ELISA_LSP_MAX_HEADER_BYTES", NULL) != 0 ||
        set_limit("ELISA_LSP_MAX_HEADER_LINES", NULL) != 0 ||
        set_limit("ELISA_LSP_MAX_BODY_BYTES", NULL) != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_SOURCE_BYTES", NULL) != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_DOCUMENTS", NULL) != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_URI_BYTES", NULL) != 0 ||
        set_limit("ELISA_LSP_MAX_DERIVED_CACHE_BYTES", NULL) != 0) {
        perror("clear transport limit environment");
        return 1;
    }
    if (!check(elisa_lsp_max_header_bytes(), 16384, "default header bytes") ||
        !check(elisa_lsp_max_header_lines(), 64, "default header lines") ||
        !check(elisa_lsp_max_body_bytes(), 16777216, "default body bytes") ||
        !check(elisa_lsp_max_open_source_bytes(), 268435456, "default open source bytes") ||
        !check(elisa_lsp_max_open_documents(), 1024, "default open document count") ||
        !check(elisa_lsp_max_open_uri_bytes(), 8388608, "default open URI bytes") ||
        !check(elisa_lsp_max_derived_cache_bytes(), 67108864, "default derived cache bytes")) return 1;

    if (set_limit("ELISA_LSP_MAX_HEADER_BYTES", "32768") != 0 ||
        set_limit("ELISA_LSP_MAX_HEADER_LINES", "128") != 0 ||
        set_limit("ELISA_LSP_MAX_BODY_BYTES", "33554432") != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_SOURCE_BYTES", "536870912") != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_DOCUMENTS", "2048") != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_URI_BYTES", "16777216") != 0 ||
        set_limit("ELISA_LSP_MAX_DERIVED_CACHE_BYTES", "134217728") != 0) {
        perror("set transport limit environment");
        return 1;
    }
    if (!check(elisa_lsp_max_header_bytes(), 32768, "header byte override") ||
        !check(elisa_lsp_max_header_lines(), 128, "header line override") ||
        !check(elisa_lsp_max_body_bytes(), 33554432, "body size override") ||
        !check(elisa_lsp_max_open_source_bytes(), 536870912, "open source byte override") ||
        !check(elisa_lsp_max_open_documents(), 2048, "open document count override") ||
        !check(elisa_lsp_max_open_uri_bytes(), 16777216, "open URI byte override") ||
        !check(elisa_lsp_max_derived_cache_bytes(), 134217728, "derived cache byte override")) return 1;

    if (set_limit("ELISA_LSP_MAX_HEADER_BYTES", "255") != 0 ||
        set_limit("ELISA_LSP_MAX_HEADER_LINES", "1") != 0 ||
        set_limit("ELISA_LSP_MAX_BODY_BYTES", "268435457") != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_SOURCE_BYTES", "0") != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_DOCUMENTS", "0") != 0 ||
        set_limit("ELISA_LSP_MAX_OPEN_URI_BYTES", "0") != 0 ||
        set_limit("ELISA_LSP_MAX_DERIVED_CACHE_BYTES", "1023") != 0) return 1;
    if (!check(elisa_lsp_max_header_bytes(), -1, "header minimum bound") ||
        !check(elisa_lsp_max_header_lines(), -1, "header line minimum bound") ||
        !check(elisa_lsp_max_body_bytes(), -1, "body maximum bound") ||
        !check(elisa_lsp_max_open_source_bytes(), -1, "open source minimum bound") ||
        !check(elisa_lsp_max_open_documents(), -1, "open document minimum bound") ||
        !check(elisa_lsp_max_open_uri_bytes(), -1, "open URI minimum bound") ||
        !check(elisa_lsp_max_derived_cache_bytes(), -1, "derived cache minimum bound")) return 1;

    if (set_limit("ELISA_LSP_MAX_OPEN_SOURCE_BYTES", "1073741825") != 0 ||
        !check(elisa_lsp_max_open_source_bytes(), -1, "open source maximum bound")) return 1;
    if (set_limit("ELISA_LSP_MAX_OPEN_DOCUMENTS", "16385") != 0 ||
        !check(elisa_lsp_max_open_documents(), -1, "open document maximum bound")) return 1;
    if (set_limit("ELISA_LSP_MAX_OPEN_URI_BYTES", "67108865") != 0 ||
        !check(elisa_lsp_max_open_uri_bytes(), -1, "open URI maximum bound")) return 1;
    if (set_limit("ELISA_LSP_MAX_DERIVED_CACHE_BYTES", "1073741825") != 0 ||
        !check(elisa_lsp_max_derived_cache_bytes(), -1, "derived cache maximum bound")) return 1;

    if (set_limit("ELISA_LSP_MAX_HEADER_BYTES", "16k") != 0 ||
        !check(elisa_lsp_max_header_bytes(), -1, "non-decimal limit")) return 1;
    if (set_limit("ELISA_LSP_MAX_HEADER_BYTES", "999999999999999999999999") != 0 ||
        !check(elisa_lsp_max_header_bytes(), -1, "overflowing limit")) return 1;
    if (set_limit("ELISA_LSP_MAX_HEADER_BYTES", "") != 0 ||
        !check(elisa_lsp_max_header_bytes(), -1, "empty configured limit")) return 1;
    if (set_limit("ELISA_LSP_MAX_OPEN_SOURCE_BYTES", "64m") != 0 ||
        !check(elisa_lsp_max_open_source_bytes(), -1, "non-decimal open source limit")) return 1;
    if (set_limit("ELISA_LSP_MAX_OPEN_DOCUMENTS", "1k") != 0 ||
        !check(elisa_lsp_max_open_documents(), -1, "non-decimal open document limit")) return 1;
    if (set_limit("ELISA_LSP_MAX_OPEN_URI_BYTES", "8m") != 0 ||
        !check(elisa_lsp_max_open_uri_bytes(), -1, "non-decimal open URI limit")) return 1;
    if (set_limit("ELISA_LSP_MAX_DERIVED_CACHE_BYTES", "64m") != 0 ||
        !check(elisa_lsp_max_derived_cache_bytes(), -1, "non-decimal derived cache limit")) return 1;
    puts("Transport limits OK: defaults, overrides, bounds, and malformed configuration");
    return 0;
}
