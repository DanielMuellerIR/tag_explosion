#ifndef TAGX_PDF_SHIM_H
#define TAGX_PDF_SHIM_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *tagx_pdf_open(const uint8_t *bytes, size_t length);
void tagx_pdf_close(void *document);
uint32_t tagx_pdf_root(void *document);
int tagx_pdf_type(void *document, uint32_t node);
uint32_t tagx_pdf_key(void *document, uint32_t node, const char *key);
uint32_t tagx_pdf_dictionary(void *document, uint32_t node);
size_t tagx_pdf_count(void *document, uint32_t node);
uint32_t tagx_pdf_item(void *document, uint32_t node, size_t index);
int tagx_pdf_integer(void *document, uint32_t node, int64_t *value);
const char *tagx_pdf_text(void *document, uint32_t node);
int tagx_pdf_stream(void *document, uint32_t node, uint8_t **bytes, size_t *length);
void tagx_pdf_free(uint8_t *bytes);
#ifdef __cplusplus
}
#endif
#endif
