#include "pdf_shim.h"
#include <qpdf/Pipeline.hh>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
constexpr size_t maxPDFBytes = 64 * 1024 * 1024;
constexpr size_t maxStreamBytes = 64 * 1024 * 1024;
constexpr size_t maxNodes = 65536;

struct Node {
    QPDFObjectHandle object;
    QPDFObjGen owner;
    std::string text;
};

struct Document {
    // Direkte Objekte gehören zum nächsten indirekten Objekt. Ihr Offset
    // kann sich in unterschiedlichen PDF-Objektströmen wiederholen.
    using ObjectLocation = std::pair<QPDFObjGen, std::optional<qpdf_offset_t>>;

    std::string input;
    QPDF pdf;
    std::deque<Node> nodes;
    std::multimap<ObjectLocation, uint32_t> locations;

    Document(const uint8_t *bytes, size_t length)
        : input(reinterpret_cast<const char *>(bytes), length) {
        pdf.setSuppressWarnings(true);
        pdf.processMemoryFile("Tag Explosion PDF snapshot", input.data(), input.size());
        nodes.push_back({QPDFObjectHandle::newNull(), {}, {}});
    }

    uint32_t intern(QPDFObjectHandle object, QPDFObjGen parentOwner = {}) {
        if (object.isNull()) {
            return 0;
        }

        auto owner = object.getObjGen();
        std::optional<qpdf_offset_t> offset;
        if (!owner.isIndirect()) {
            owner = parentOwner;
            offset = object.getParsedOffset();
        }

        ObjectLocation location{owner, offset};
        auto [first, last] = locations.equal_range(location);
        // QPDF kann direkte Objekte ohne Quelloffset erzeugen (Offset -1).
        for (auto match = first; match != last; ++match) {
            if (nodes[match->second].object.isSameObjectAs(object)) {
                return match->second;
            }
        }

        if (nodes.size() >= maxNodes) {
            throw std::runtime_error("PDF object budget exceeded");
        }
        auto id = static_cast<uint32_t>(nodes.size());
        nodes.push_back({object, owner, {}});
        try {
            locations.emplace_hint(last, location, id);
        } catch (...) {
            nodes.pop_back();
            throw;
        }
        return id;
    }

    Node &get(uint32_t id) {
        return nodes.at(id);
    }
};

class BoundedOutput : public Pipeline {
public:
    std::vector<uint8_t> bytes;

    BoundedOutput() : Pipeline("Tag Explosion bounded stream", nullptr) {}

    void write(const unsigned char *data, size_t length) override {
        if (length > maxStreamBytes - bytes.size()) {
            throw std::runtime_error("PDF stream budget exceeded");
        }
        if (length != 0) {
            bytes.insert(bytes.end(), data, data + length);
        }
    }

    void finish() override {}
};
}

extern "C" {
void *tagx_pdf_open(const uint8_t *bytes, size_t length) {
    if (!bytes || length == 0 || length > maxPDFBytes) {
        return nullptr;
    }
    try {
        return new Document(bytes, length);
    } catch (...) {
        return nullptr;
    }
}

void tagx_pdf_close(void *document) {
    delete static_cast<Document *>(document);
}

uint32_t tagx_pdf_root(void *document) {
    if (!document) {
        return 0;
    }
    try {
        auto *pdf = static_cast<Document *>(document);
        return pdf->intern(pdf->pdf.getRoot());
    } catch (...) {
        return 0;
    }
}

int tagx_pdf_type(void *document, uint32_t node) {
    if (!document) {
        return 0;
    }
    try {
        auto &object = static_cast<Document *>(document)->get(node).object;
        switch (object.getTypeCode()) {
            case ot_integer: return 1;
            case ot_name: return 2;
            case ot_string: return 3;
            case ot_array: return 4;
            case ot_dictionary: return 5;
            case ot_stream: return 6;
            default: return 0;
        }
    } catch (...) {
        return 0;
    }
}

uint32_t tagx_pdf_key(void *document, uint32_t node, const char *key) {
    if (!document || !key) {
        return 0;
    }
    try {
        auto *pdf = static_cast<Document *>(document);
        auto &parent = pdf->get(node);
        if (!parent.object.isDictionary()) {
            return 0;
        }
        return pdf->intern(parent.object.getKey(std::string("/") + key), parent.owner);
    } catch (...) {
        return 0;
    }
}

uint32_t tagx_pdf_dictionary(void *document, uint32_t node) {
    if (!document) {
        return 0;
    }
    try {
        auto *pdf = static_cast<Document *>(document);
        auto &parent = pdf->get(node);
        if (!parent.object.isStream()) {
            return 0;
        }
        return pdf->intern(parent.object.getDict(), parent.owner);
    } catch (...) {
        return 0;
    }
}

size_t tagx_pdf_count(void *document, uint32_t node) {
    if (!document) {
        return 0;
    }
    try {
        auto &object = static_cast<Document *>(document)->get(node).object;
        return object.isArray() ? object.getArrayNItems() : 0;
    } catch (...) {
        return 0;
    }
}

uint32_t tagx_pdf_item(void *document, uint32_t node, size_t index) {
    if (!document) {
        return 0;
    }
    try {
        auto *pdf = static_cast<Document *>(document);
        auto &parent = pdf->get(node);
        if (!parent.object.isArray() || index >= static_cast<size_t>(parent.object.getArrayNItems())) {
            return 0;
        }
        return pdf->intern(parent.object.getArrayItem(static_cast<int>(index)), parent.owner);
    } catch (...) {
        return 0;
    }
}

int tagx_pdf_integer(void *document, uint32_t node, int64_t *value) {
    if (!document || !value) {
        return 0;
    }
    try {
        auto &object = static_cast<Document *>(document)->get(node).object;
        if (!object.isInteger()) {
            return 0;
        }
        *value = object.getIntValue();
        return 1;
    } catch (...) {
        return 0;
    }
}

const char *tagx_pdf_text(void *document, uint32_t node) {
    if (!document) {
        return nullptr;
    }
    try {
        auto &entry = static_cast<Document *>(document)->get(node);
        if (entry.object.isString()) {
            entry.text = entry.object.getUTF8Value();
        } else if (entry.object.isName()) {
            entry.text = entry.object.getName().substr(1);
        } else {
            return nullptr;
        }
        return entry.text.c_str();
    } catch (...) {
        return nullptr;
    }
}

int tagx_pdf_stream(void *document, uint32_t node, uint8_t **bytes, size_t *length) {
    if (!bytes || !length) {
        return 0;
    }
    *bytes = nullptr;
    *length = 0;
    if (!document) {
        return 0;
    }
    try {
        auto &object = static_cast<Document *>(document)->get(node).object;
        if (!object.isStream()) {
            return 0;
        }

        BoundedOutput output;
        bool filtered = false;
        if (!object.pipeStreamData(&output, &filtered, 0, qpdf_dl_generalized, true, false)) {
            return 0;
        }

        auto size = output.bytes.size();
        auto *buffer = static_cast<uint8_t *>(std::malloc(size ? size : 1));
        if (!buffer) {
            return 0;
        }
        if (size != 0) {
            std::memcpy(buffer, output.bytes.data(), size);
        }
        *bytes = buffer;
        *length = size;
        return 1;
    } catch (...) {
        return 0;
    }
}

void tagx_pdf_free(uint8_t *bytes) {
    std::free(bytes);
}
}
