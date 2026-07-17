// Implementierung des C-Shims über die TagLib-C++-API.
// Einziger Ort im Projekt, der TagLib-Header einbindet.
#include "include/ctagshim.h"

#include <fileref.h>
#include <tpropertymap.h>
#include <tvariant.h>
#include <taglib.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>

namespace {

// UTF-8-Kopie eines TagLib-Strings als C-String (Aufrufer gibt frei).
char* dup_string(const TagLib::String& s) {
    const std::string utf8 = s.to8Bit(true);
    char* out = static_cast<char*>(std::malloc(utf8.size() + 1));
    if (out) std::memcpy(out, utf8.c_str(), utf8.size() + 1);
    return out;
}

} // namespace

// Das opake Handle hält den FileRef; TagLib verwaltet darin Datei + Tags.
struct tx_file {
    TagLib::FileRef ref;
    bool readOnly = false;
};

extern "C" {

tx_file* tx_open(const char* path) {
    if (!path) return nullptr;
    auto* f = new (std::nothrow) tx_file();
    if (!f) return nullptr;
    // Erst beschreibbar versuchen, dann read-only als Fallback (z.B. Datei
    // ohne Schreibrechte soll trotzdem anzeigbar sein).
    f->ref = TagLib::FileRef(path, true, TagLib::AudioProperties::Average);
    if (f->ref.isNull() || !f->ref.file() || !f->ref.file()->isValid()) {
        delete f;
        return nullptr;
    }
    f->readOnly = f->ref.file()->readOnly();
    return f;
}

void tx_close(tx_file* f) {
    delete f;
}

int tx_is_readonly(tx_file* f) {
    return (f && f->readOnly) ? 1 : 0;
}

int tx_save(tx_file* f) {
    if (!f || f->ref.isNull() || f->readOnly) return 0;
    return f->ref.save() ? 1 : 0;
}

// ---- Properties -------------------------------------------------------------

tx_prop* tx_get_properties(tx_file* f, int32_t* out_count) {
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;

    const TagLib::PropertyMap props = f->ref.properties();
    int32_t total = 0;
    for (const auto& [key, values] : props)
        total += static_cast<int32_t>(values.size());

    *out_count = total;
    if (total == 0) return nullptr;

    auto* out = static_cast<tx_prop*>(std::calloc(static_cast<size_t>(total), sizeof(tx_prop)));
    if (!out) { *out_count = -1; return nullptr; }

    int32_t i = 0;
    for (const auto& [key, values] : props) {
        for (const auto& value : values) {
            out[i].key = dup_string(key);
            out[i].value = dup_string(value);
            ++i;
        }
    }
    return out;
}

void tx_free_properties(tx_prop* props, int32_t count) {
    if (!props) return;
    for (int32_t i = 0; i < count; ++i) {
        std::free(props[i].key);
        std::free(props[i].value);
    }
    std::free(props);
}

int32_t tx_set_properties(tx_file* f, const tx_prop* props, int32_t count) {
    if (!f || f->ref.isNull() || (count > 0 && !props)) return -1;

    // Gleiche Schlüssel zu mehrwertigen Einträgen zusammenfassen.
    TagLib::PropertyMap map;
    for (int32_t i = 0; i < count; ++i) {
        const TagLib::String key(props[i].key ? props[i].key : "", TagLib::String::UTF8);
        const TagLib::String value(props[i].value ? props[i].value : "", TagLib::String::UTF8);
        map[key].append(value);
    }
    const TagLib::PropertyMap rejected = f->ref.setProperties(map);
    int32_t rejectedCount = 0;
    for (const auto& [key, values] : rejected)
        rejectedCount += static_cast<int32_t>(values.size());
    return rejectedCount;
}

// ---- Bilder -----------------------------------------------------------------

tx_picture* tx_get_pictures(tx_file* f, int32_t* out_count) {
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;

    const auto pics = f->ref.complexProperties("PICTURE");
    *out_count = static_cast<int32_t>(pics.size());
    if (pics.isEmpty()) { *out_count = 0; return nullptr; }

    auto* out = static_cast<tx_picture*>(std::calloc(pics.size(), sizeof(tx_picture)));
    if (!out) { *out_count = -1; return nullptr; }

    int32_t i = 0;
    for (const auto& pic : pics) {
        const TagLib::ByteVector data = pic.value("data").toByteVector();
        out[i].size = static_cast<int32_t>(data.size());
        out[i].data = static_cast<uint8_t*>(std::malloc(data.size() > 0 ? data.size() : 1));
        if (out[i].data && data.size() > 0)
            std::memcpy(out[i].data, data.data(), data.size());
        out[i].mime = dup_string(pic.value("mimeType").toString());
        out[i].picture_type = dup_string(pic.value("pictureType").toString());
        out[i].description = dup_string(pic.value("description").toString());
        ++i;
    }
    return out;
}

void tx_free_pictures(tx_picture* pics, int32_t count) {
    if (!pics) return;
    for (int32_t i = 0; i < count; ++i) {
        std::free(pics[i].data);
        std::free(pics[i].mime);
        std::free(pics[i].picture_type);
        std::free(pics[i].description);
    }
    std::free(pics);
}

int tx_set_pictures(tx_file* f, const tx_picture* pics, int32_t count) {
    if (!f || f->ref.isNull() || (count > 0 && !pics)) return 0;

    TagLib::List<TagLib::VariantMap> list;
    for (int32_t i = 0; i < count; ++i) {
        TagLib::VariantMap map;
        map.insert("data", TagLib::ByteVector(
            reinterpret_cast<const char*>(pics[i].data),
            static_cast<unsigned int>(pics[i].size)));
        if (pics[i].mime && pics[i].mime[0])
            map.insert("mimeType", TagLib::String(pics[i].mime, TagLib::String::UTF8));
        if (pics[i].picture_type && pics[i].picture_type[0])
            map.insert("pictureType", TagLib::String(pics[i].picture_type, TagLib::String::UTF8));
        if (pics[i].description && pics[i].description[0])
            map.insert("description", TagLib::String(pics[i].description, TagLib::String::UTF8));
        list.append(map);
    }
    return f->ref.setComplexProperties("PICTURE", list) ? 1 : 0;
}

// ---- Audio-Eigenschaften ------------------------------------------------------

int tx_get_audio_properties(tx_file* f, tx_audio_properties* out) {
    if (!f || f->ref.isNull() || !out) return 0;
    const TagLib::AudioProperties* ap = f->ref.audioProperties();
    if (!ap) return 0;
    out->length_ms = ap->lengthInMilliseconds();
    out->bitrate_kbps = ap->bitrate();
    out->sample_rate_hz = ap->sampleRate();
    out->channels = ap->channels();
    return 1;
}

// ---- Sonstiges ----------------------------------------------------------------

const char* tx_taglib_version(void) {
    // TagLib liefert die Version als Makros; zusammensetzen und statisch halten.
    static char version[32];
    std::snprintf(version, sizeof(version), "%d.%d.%d",
                  TAGLIB_MAJOR_VERSION, TAGLIB_MINOR_VERSION, TAGLIB_PATCH_VERSION);
    return version;
}

} // extern "C"
