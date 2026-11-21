#pragma once

#include "include/ctagshim.h"

#include <fileref.h>
#include <tpropertymap.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <stdexcept>
#include <string_view>

// Das opake C-Handle hält den FileRef; TagLib verwaltet darin Datei und Tags.
struct tx_file {
    TagLib::FileRef ref;
    bool readOnly = false;
};

namespace tx_shim {

template <typename T>
T* file_as(tx_file* f) {
    if (!f || f->ref.isNull()) return nullptr;
    return dynamic_cast<T*>(f->ref.file());
}

inline bool fits_in_u32(int64_t value) {
    return value >= 0 && value <= std::numeric_limits<uint32_t>::max();
}

inline int32_t result_count(size_t count) {
    if (count > std::numeric_limits<int32_t>::max())
        throw std::length_error("CTagShim result exceeds int32_t");
    return static_cast<int32_t>(count);
}

inline int32_t property_count(const TagLib::PropertyMap& properties) {
    int32_t count = 0;
    for (const auto& [key, values] : properties) {
        const int32_t size = result_count(values.size());
        if (size > std::numeric_limits<int32_t>::max() - count)
            throw std::length_error("CTagShim property count exceeds int32_t");
        count += size;
    }
    return count;
}

// Die C-Ausgabe erst nach vollständigem Aufbau freigeben. Die Nullfelder
// aus calloc erlauben denselben Freigabeweg auch für Teilresultate.
template <typename T, void (*Free)(T*, int32_t)>
auto allocate_result(int32_t count) {
    auto cleanup = [count](T* items) { Free(items, count); };
    auto* items = count == 0 ? nullptr
        : static_cast<T*>(std::calloc(static_cast<size_t>(count), sizeof(T)));
    if (count > 0 && !items) throw std::bad_alloc();
    return std::unique_ptr<T[], decltype(cleanup)>(items, cleanup);
}

inline char* dup_bytes(std::string_view bytes) {
    auto* out = static_cast<char*>(std::malloc(bytes.size() + 1));
    if (!out) throw std::bad_alloc();
    if (!bytes.empty()) std::memcpy(out, bytes.data(), bytes.size());
    out[bytes.size()] = '\0';
    return out;
}

inline char* dup_string(const TagLib::String& string) {
    return dup_bytes(string.to8Bit(true));
}

// TagLib fügt ID3-Frames erst der besitzenden Liste und dann dem Index
// hinzu. Beim zweiten Schritt kann der Frame schon dem Tag gehören.
template <typename Frame, typename FrameList, typename Add>
void transfer_frame(std::unique_ptr<Frame> frame, const FrameList& owningFrames, Add add) {
    try {
        add(frame.get());
    } catch (...) {
        if (std::find(owningFrames.begin(), owningFrames.end(), frame.get()) != owningFrames.end())
            frame.release();
        throw;
    }
    frame.release();
}

int32_t set_properties_preserving_lyrics(tx_file* f, const TagLib::PropertyMap& map);

} // namespace tx_shim
