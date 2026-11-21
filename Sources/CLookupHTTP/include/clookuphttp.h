#ifndef TAGX_CLOOKUPHTTP_H
#define TAGX_CLOOKUPHTTP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef size_t (*tagx_lookup_receive)(void *context, const uint8_t *bytes, size_t count);
typedef bool (*tagx_lookup_cancelled)(void *context);

typedef struct {
    const char *url;
    const char *method;
    const char *proxy;
    const char *proxy_username;
    const char *proxy_password;
    const char *const *headers;
    size_t header_count;
    const uint8_t *body;
    size_t body_count;
    bool has_body;
    long connect_timeout_ms;
    void *context;
    tagx_lookup_receive receive_header;
    tagx_lookup_receive receive_body;
    tagx_lookup_cancelled is_cancelled;
} tagx_lookup_transfer;

int tagx_lookup_perform(const tagx_lookup_transfer *transfer, long *status, bool *can_try_next_proxy);
const char *tagx_lookup_error_description(int code);
bool tagx_lookup_is_timeout(int code);

#endif
