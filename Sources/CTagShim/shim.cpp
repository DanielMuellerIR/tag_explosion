// Datei-Handle, Textfelder, Cover und Audio-Eigenschaften über TagLib.
#include "shim_internal.hpp"

#include <id3v2framefactory.h>
#include <taglib.h>
#include <tvariant.h>

#include <mutex>

#define TX_STRINGIFY_INNER(value) #value
#define TX_STRINGIFY(value) TX_STRINGIFY_INNER(value)

using namespace tx_shim;

namespace {

// FrameFactory ist ein prozessweiter TagLib-Singleton. Der Default darf bei
// parallelen Dateiöffnungen genau einmal gesetzt werden.
void configure_frame_factory() {
    static std::once_flag once;
    std::call_once(once, [] {
        TagLib::ID3v2::FrameFactory::instance()->setDefaultTextEncoding(
            TagLib::String::UTF8);
    });
}

} // namespace

extern "C" {

tx_file* tx_open(const char* path) try {
    if (!path) return nullptr;
    // TagLibs Latin1-Default führt bei Umlauten in anderen Programmen zu Mojibake.
    configure_frame_factory();
    auto f = std::make_unique<tx_file>();
    // Auch Dateien ohne Schreibrechte sollen anzeigbar sein.
    f->ref = TagLib::FileRef(path, true, TagLib::AudioProperties::Average);
    if (f->ref.isNull() || !f->ref.file() || !f->ref.file()->isValid()) return nullptr;
    f->readOnly = f->ref.file()->readOnly();
    return f.release();
} catch (...) {
    return nullptr;
}

void tx_close(tx_file* f) {
    delete f;
}

int tx_is_readonly(tx_file* f) {
    return (f && f->readOnly) ? 1 : 0;
}

int tx_save(tx_file* f) try {
    if (!f || f->ref.isNull() || f->readOnly) return 0;
    return f->ref.save() ? 1 : 0;
} catch (...) {
    return 0;
}

tx_prop* tx_get_properties(tx_file* f, int32_t* out_count) try {
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;

    const TagLib::PropertyMap props = f->ref.properties();
    const auto count = property_count(props);
    auto out = allocate_result<tx_prop, tx_free_properties>(count);
    size_t index = 0;
    for (const auto& [key, values] : props) {
        for (const auto& value : values) {
            out[index].key = dup_string(key);
            out[index].value = dup_string(value);
            ++index;
        }
    }
    *out_count = count;
    return out.release();
} catch (...) {
    return nullptr;
}

void tx_free_properties(tx_prop* props, int32_t count) {
    if (!props) return;
    for (int32_t i = 0; i < count; ++i) {
        std::free(props[i].key);
        std::free(props[i].value);
    }
    std::free(props);
}

int32_t tx_set_properties(tx_file* f, const tx_prop* props, int32_t count) try {
    if (count < 0 || (count > 0 && !props) || !f || f->ref.isNull()) return -1;

    // Gleiche Schlüssel zu mehrwertigen Einträgen zusammenfassen.
    TagLib::PropertyMap map;
    for (int32_t i = 0; i < count; ++i) {
        const TagLib::String key(props[i].key ? props[i].key : "", TagLib::String::UTF8);
        const TagLib::String value(props[i].value ? props[i].value : "", TagLib::String::UTF8);
        map[key].append(value);
    }
    return set_properties_preserving_lyrics(f, map);
} catch (...) {
    return -1;
}

tx_picture* tx_get_pictures(tx_file* f, int32_t* out_count) try {
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;

    const auto pics = f->ref.complexProperties("PICTURE");
    const auto count = result_count(pics.size());
    auto out = allocate_result<tx_picture, tx_free_pictures>(count);
    size_t index = 0;
    for (const auto& pic : pics) {
        const TagLib::ByteVector data = pic.value("data").toByteVector();
        auto& item = out[index++];
        item.size = result_count(data.size());
        item.data = static_cast<uint8_t*>(std::malloc(data.size() > 0 ? data.size() : 1));
        if (!item.data) throw std::bad_alloc();
        if (item.size > 0) std::memcpy(item.data, data.data(), data.size());
        item.mime = dup_string(pic.value("mimeType").toString());
        item.picture_type = dup_string(pic.value("pictureType").toString());
        item.description = dup_string(pic.value("description").toString());
    }
    *out_count = count;
    return out.release();
} catch (...) {
    return nullptr;
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

int tx_set_pictures(tx_file* f, const tx_picture* pics, int32_t count) try {
    if (count < 0 || (count > 0 && !pics) || !f || f->ref.isNull()) return 0;

    TagLib::List<TagLib::VariantMap> list;
    for (int32_t i = 0; i < count; ++i) {
        const auto& picture = pics[i];
        if (picture.size < 0 || (picture.size > 0 && !picture.data)) return 0;

        TagLib::VariantMap map;
        const auto data = picture.size == 0 ? TagLib::ByteVector() : TagLib::ByteVector(
            reinterpret_cast<const char*>(picture.data), static_cast<unsigned int>(picture.size));
        map.insert("data", data);
        if (picture.mime && picture.mime[0])
            map.insert("mimeType", TagLib::String(picture.mime, TagLib::String::UTF8));
        if (picture.picture_type && picture.picture_type[0])
            map.insert("pictureType", TagLib::String(picture.picture_type, TagLib::String::UTF8));
        if (picture.description && picture.description[0])
            map.insert("description", TagLib::String(picture.description, TagLib::String::UTF8));
        list.append(map);
    }
    return f->ref.setComplexProperties("PICTURE", list) ? 1 : 0;
} catch (...) {
    return 0;
}

int tx_get_audio_properties(tx_file* f, tx_audio_properties* out) try {
    if (!out) return 0;
    *out = {};
    if (!f || f->ref.isNull()) return 0;
    const TagLib::AudioProperties* ap = f->ref.audioProperties();
    if (!ap) return 0;
    *out = {ap->lengthInMilliseconds(), ap->bitrate(), ap->sampleRate(), ap->channels()};
    return 1;
} catch (...) {
    return 0;
}

const char* tx_taglib_version(void) {
    return TX_STRINGIFY(TAGLIB_MAJOR_VERSION) "."
           TX_STRINGIFY(TAGLIB_MINOR_VERSION) "."
           TX_STRINGIFY(TAGLIB_PATCH_VERSION);
}

} // extern "C"
