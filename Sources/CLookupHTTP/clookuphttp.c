#include "clookuphttp.h"

#include <curl/curl.h>
#include <pthread.h>
#include <string.h>

static pthread_once_t curl_setup = PTHREAD_ONCE_INIT;
static CURLcode curl_setup_result;

static void initialize_curl(void) {
    curl_setup_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static size_t receive_header(char *bytes, size_t size, size_t count, void *context) {
    const tagx_lookup_transfer *transfer = context;
    return transfer->receive_header(transfer->context, (const uint8_t *)bytes, size * count);
}

static size_t receive_body(char *bytes, size_t size, size_t count, void *context) {
    const tagx_lookup_transfer *transfer = context;
    return transfer->receive_body(transfer->context, (const uint8_t *)bytes, size * count);
}

static int check_cancellation(void *context, curl_off_t download_total, curl_off_t downloaded,
                              curl_off_t upload_total, curl_off_t uploaded) {
    (void)download_total;
    (void)downloaded;
    (void)upload_total;
    (void)uploaded;
    const tagx_lookup_transfer *transfer = context;
    return transfer->is_cancelled(transfer->context) ? 1 : 0;
}

int tagx_lookup_perform(const tagx_lookup_transfer *transfer, long *status, bool *can_try_next_proxy) {
    if (!status || !can_try_next_proxy) return CURLE_BAD_FUNCTION_ARGUMENT;
    *status = 0;
    *can_try_next_proxy = false;
    if (!transfer || !transfer->url || !transfer->method || !transfer->receive_header
        || !transfer->receive_body || !transfer->is_cancelled
        || (transfer->header_count && !transfer->headers) || (transfer->body_count && !transfer->body)) {
        return CURLE_BAD_FUNCTION_ARGUMENT;
    }
    if (pthread_once(&curl_setup, initialize_curl) != 0) return CURLE_FAILED_INIT;
    if (curl_setup_result != CURLE_OK) return curl_setup_result;
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;

    struct curl_slist *headers = NULL;
    CURLcode result = CURLE_OK;
    for (size_t index = 0; index < transfer->header_count; index++) {
        if (!transfer->headers[index]) {
            result = CURLE_BAD_FUNCTION_ARGUMENT;
            goto cleanup;
        }
        struct curl_slist *updated = curl_slist_append(headers, transfer->headers[index]);
        if (!updated) {
            result = CURLE_OUT_OF_MEMORY;
            goto cleanup;
        }
        headers = updated;
    }

#define SET(option, value) \
    do { \
        result = curl_easy_setopt(curl, option, value); \
        if (result != CURLE_OK) goto cleanup; \
    } while (0)

    SET(CURLOPT_URL, transfer->url);
    if (transfer->proxy) {
        SET(CURLOPT_PROXY, transfer->proxy);
        SET(CURLOPT_NOPROXY, "");
    }
    if (transfer->proxy_username) {
        SET(CURLOPT_PROXYUSERNAME, transfer->proxy_username);
        SET(CURLOPT_PROXYAUTH, (long)CURLAUTH_ANY);
    }
    if (transfer->proxy_password) {
        SET(CURLOPT_PROXYPASSWORD, transfer->proxy_password);
    }
    SET(CURLOPT_PROTOCOLS_STR, "https,http");
    SET(CURLOPT_DISALLOW_USERNAME_IN_URL, 1L);
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT, 30L);
    SET(CURLOPT_LOW_SPEED_LIMIT, 1L);
    SET(CURLOPT_LOW_SPEED_TIME, 30L);
    SET(CURLOPT_TIMEOUT, 7L * 24L * 60L * 60L);
    SET(CURLOPT_ACCEPT_ENCODING, "");
    SET(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
    SET(CURLOPT_CUSTOMREQUEST, transfer->method);
    SET(CURLOPT_HTTPHEADER, headers);
    if (strcmp(transfer->method, "HEAD") == 0) {
        SET(CURLOPT_NOBODY, 1L);
    } else if (transfer->has_body || strcmp(transfer->method, "POST") == 0) {
        SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)transfer->body_count);
        SET(CURLOPT_POSTFIELDS, transfer->body ? (const char *)transfer->body : "");
    }
    SET(CURLOPT_HEADERFUNCTION, receive_header);
    SET(CURLOPT_HEADERDATA, transfer);
    SET(CURLOPT_WRITEFUNCTION, receive_body);
    SET(CURLOPT_WRITEDATA, transfer);
    SET(CURLOPT_XFERINFOFUNCTION, check_cancellation);
    SET(CURLOPT_XFERINFODATA, transfer);
    SET(CURLOPT_NOPROGRESS, 0L);
#undef SET

    result = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status);
    if (result != CURLE_OK && *status == 0) {
        long connect_status = 0;
        if (curl_easy_getinfo(curl, CURLINFO_HTTP_CONNECTCODE, &connect_status) == CURLE_OK) {
            /* Ein abgelehnter CONNECT bei Proxy-Ausfall hat den Zielserver nicht erreicht. */
            *can_try_next_proxy = connect_status == 502 || connect_status == 503 || connect_status == 504
                || (connect_status == 0 && (result == CURLE_COULDNT_RESOLVE_PROXY || result == CURLE_COULDNT_CONNECT));
        }
    }

cleanup:
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return result;
}

const char *tagx_lookup_error_description(int code) {
    return curl_easy_strerror((CURLcode)code);
}

bool tagx_lookup_is_timeout(int code) {
    return code == CURLE_OPERATION_TIMEDOUT;
}
