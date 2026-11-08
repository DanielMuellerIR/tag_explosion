#include "pdf_shim.h"
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/Pipeline.hh>
#include <deque>
#include <memory>
#include <string>
#include <vector>
#include <stdexcept>
#include <cstdlib>
#include <cstring>

namespace {
struct Node { QPDFObjectHandle object; std::string text; };
struct Document {
    std::string input;
    QPDF pdf;
    std::deque<Node> nodes;
    Document(const uint8_t *bytes, size_t length): input(reinterpret_cast<const char *>(bytes), length) {
        pdf.setSuppressWarnings(true);
        pdf.processMemoryFile("Tag Explosion PDF snapshot", input.data(), input.size());
        nodes.push_back({QPDFObjectHandle::newNull(), {}});
    }
    uint32_t intern(QPDFObjectHandle object) {
        if (object.isNull()) return 0;
        // Identität bewahren: Dasselbe Filespec in AF und Names ist ein Anhang.
        for (size_t i = 1; i < nodes.size(); ++i) if (nodes[i].object.isSameObjectAs(object)) return static_cast<uint32_t>(i);
        if (nodes.size() >= 65536) throw std::runtime_error("PDF object budget exceeded");
        nodes.push_back({object, {}});
        return static_cast<uint32_t>(nodes.size() - 1);
    }
    QPDFObjectHandle get(uint32_t id) {
        if (id >= nodes.size()) throw std::runtime_error("Invalid PDF object");
        return nodes[id].object;
    }
};
class BoundedOutput: public Pipeline {
  public:
    std::vector<uint8_t> bytes;
    BoundedOutput(): Pipeline("Tag Explosion bounded stream", nullptr) {}
    void write(const unsigned char *data, size_t length) override {
        if (length > 64 * 1024 * 1024 - bytes.size()) throw std::runtime_error("PDF stream budget exceeded");
        bytes.insert(bytes.end(), data, data + length);
    }
    void finish() override {}
};
}

extern "C" {
void *tagx_pdf_open(const uint8_t *bytes, size_t length) {
    try {
        if (!bytes || length == 0 || length > 64 * 1024 * 1024) return nullptr;
        return new Document(bytes, length);
    } catch (...) { return nullptr; }
}
void tagx_pdf_close(void *document) { delete static_cast<Document *>(document); }
uint32_t tagx_pdf_root(void *document) { try { auto d = static_cast<Document *>(document); return d->intern(d->pdf.getRoot()); } catch (...) { return 0; } }
int tagx_pdf_type(void *document, uint32_t node) {
    try {
        auto o = static_cast<Document *>(document)->get(node);
        if (o.isInteger()) return 1;
        if (o.isName()) return 2;
        if (o.isString()) return 3;
        if (o.isArray()) return 4;
        if (o.isDictionary()) return 5;
        if (o.isStream()) return 6;
        return 0;
    } catch (...) { return 0; }
}
uint32_t tagx_pdf_key(void *document, uint32_t node, const char *key) {
    try { auto d = static_cast<Document *>(document); auto o = d->get(node); return o.isDictionary() ? d->intern(o.getKey(std::string("/") + key)) : 0; } catch (...) { return 0; }
}
uint32_t tagx_pdf_dictionary(void *document, uint32_t node) {
    try { auto d = static_cast<Document *>(document); auto o = d->get(node); return o.isStream() ? d->intern(o.getDict()) : 0; } catch (...) { return 0; }
}
size_t tagx_pdf_count(void *document, uint32_t node) {
    try { auto o = static_cast<Document *>(document)->get(node); return o.isArray() ? o.getArrayNItems() : 0; } catch (...) { return 0; }
}
uint32_t tagx_pdf_item(void *document, uint32_t node, size_t index) {
    try { auto d = static_cast<Document *>(document); auto o = d->get(node); return o.isArray() && index < static_cast<size_t>(o.getArrayNItems()) ? d->intern(o.getArrayItem(static_cast<int>(index))) : 0; } catch (...) { return 0; }
}
int tagx_pdf_integer(void *document, uint32_t node, int64_t *value) {
    try { auto o = static_cast<Document *>(document)->get(node); if (!o.isInteger()) return 0; *value = o.getIntValue(); return 1; } catch (...) { return 0; }
}
const char *tagx_pdf_text(void *document, uint32_t node) {
    try {
        auto d = static_cast<Document *>(document); auto o = d->get(node);
        if (o.isString()) d->nodes[node].text = o.getUTF8Value();
        else if (o.isName()) d->nodes[node].text = o.getName().substr(1);
        else return nullptr;
        return d->nodes[node].text.c_str();
    } catch (...) { return nullptr; }
}
int tagx_pdf_stream(void *document, uint32_t node, uint8_t **bytes, size_t *length) {
    *bytes = nullptr; *length = 0;
    try {
        auto o = static_cast<Document *>(document)->get(node);
        if (!o.isStream()) return 0;
        BoundedOutput output;
        bool filtered = false;
        if (!o.pipeStreamData(&output, &filtered, 0, qpdf_dl_generalized, true, false)) return 0;
        *length = output.bytes.size();
        *bytes = static_cast<uint8_t *>(std::malloc(*length ? *length : 1));
        if (!*bytes) return 0;
        if (*length) std::memcpy(*bytes, output.bytes.data(), *length);
        return 1;
    } catch (...) { return 0; }
}
void tagx_pdf_free(uint8_t *bytes) { std::free(bytes); }
}
