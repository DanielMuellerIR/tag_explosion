// ID3v2-Lyrics und Felder mit einem Speicherort außerhalb der PropertyMap.
#include "shim_internal.hpp"

#include <aifffile.h>
#include <dsffile.h>
#include <id3v2tag.h>
#include <mp4file.h>
#include <mp4item.h>
#include <mp4tag.h>
#include <mpegfile.h>
#include <podcastframe.h>
#include <synchronizedlyricsframe.h>
#include <textidentificationframe.h>
#include <unsynchronizedlyricsframe.h>
#include <wavfile.h>

#include <map>
#include <vector>

using namespace tx_shim;

namespace {

// Der ID3v2-Tag der Datei, falls das Format einen tragen kann. `create`
// legt bei MP3 einen neuen Tag an; WAV, AIFF und DSF liefern ihren Tag
// immer (TagLib erzeugt ihn dort intern erst beim Speichern, wenn er Frames
// hat). nullptr = Format ohne ID3v2.
TagLib::ID3v2::Tag* id3v2_tag(tx_file* f, bool create) {
    if (auto* mpeg = file_as<TagLib::MPEG::File>(f)) return mpeg->ID3v2Tag(create);
    if (auto* wav = file_as<TagLib::RIFF::WAV::File>(f)) return wav->ID3v2Tag();
    if (auto* aiff = file_as<TagLib::RIFF::AIFF::File>(f)) return aiff->tag();
    if (auto* dsf = file_as<TagLib::DSF::File>(f)) return dsf->tag();
    return nullptr;
}

// Der MP4-Tag der Datei (nullptr = kein MP4-Container).
TagLib::MP4::Tag* mp4_tag(tx_file* f) {
    auto* mp4 = file_as<TagLib::MP4::File>(f);
    return mp4 ? mp4->tag() : nullptr;
}

bool has_language_bytes(const char* language) {
    return language && std::strlen(language) == 3;
}

TagLib::ByteVector language_bytes(const char* language) {
    return TagLib::ByteVector(has_language_bytes(language) ? language : "XXX", 3);
}

char* copy_language(const TagLib::ByteVector& bytes) {
    // Das Sprachfeld besteht aus drei Rohbytes ohne Nullterminierung.
    return bytes.size() == 3 ? dup_string(TagLib::String(bytes)) : dup_bytes("XXX");
}

// Erster Frame eines Typs im Tag (nullptr, wenn keiner da ist).
template <typename FrameType>
FrameType* first_frame(TagLib::ID3v2::Tag* tag, const char* frameId) {
    for (auto* frame : tag->frameList(frameId)) {
        if (auto* typed = dynamic_cast<FrameType*>(frame)) return typed;
    }
    return nullptr;
}

bool has_text(const char* value) { return value && value[0]; }

bool valid_native_id3_frame(const char* id3_frame) {
    return !has_text(id3_frame) || std::strlen(id3_frame) == 4;
}

} // namespace

// TagLib kann bei Textänderungen USLT-Frames neu erzeugen. Deren Sprache
// stammt aus dem bisherigen Frame mit demselben Property-Schlüssel.
int32_t tx_shim::set_properties_preserving_lyrics(tx_file* f, const TagLib::PropertyMap& map) {
    std::map<TagLib::String, TagLib::ByteVector> languages;
    if (auto* tag = id3v2_tag(f, false)) {
        for (auto* frame : tag->frameList("USLT")) {
            auto* lyrics = dynamic_cast<TagLib::ID3v2::UnsynchronizedLyricsFrame*>(frame);
            if (!lyrics) continue;
            const auto properties = lyrics->asProperties();
            if (properties.isEmpty()) continue;
            // TagLib normalisiert die Beschreibungen. Bei einer Kollision muss
            // der Schlüssel vor setProperties als abgelehnt gemeldet werden.
            if (!languages.emplace(properties.begin()->first, lyrics->language()).second)
                return 1;
        }
    }
    const TagLib::PropertyMap rejected = f->ref.setProperties(map);
    if (!languages.empty()) {
        if (auto* tag = id3v2_tag(f, false)) {
            for (auto* frame : tag->frameList("USLT")) {
                auto* lyrics = dynamic_cast<TagLib::ID3v2::UnsynchronizedLyricsFrame*>(frame);
                if (!lyrics) continue;
                const auto properties = lyrics->asProperties();
                if (properties.isEmpty()) continue;
                const auto previous = languages.find(properties.begin()->first);
                if (previous != languages.end() && previous->second != lyrics->language())
                    lyrics->setLanguage(previous->second);
            }
        }
    }
    return property_count(rejected);
}

extern "C" {

int tx_id3v2_supported(tx_file* f) try {
    return (file_as<TagLib::MPEG::File>(f) || file_as<TagLib::RIFF::WAV::File>(f)
            || file_as<TagLib::RIFF::AIFF::File>(f) || file_as<TagLib::DSF::File>(f)) ? 1 : 0;
} catch (...) {
    return 0;
}

char* tx_get_lyrics_language(tx_file* f) try {
    TagLib::ID3v2::Tag* tag = id3v2_tag(f, false);
    if (!tag) return nullptr;
    auto* uslt = first_frame<TagLib::ID3v2::UnsynchronizedLyricsFrame>(tag, "USLT");
    return uslt ? copy_language(uslt->language()) : nullptr;
} catch (...) {
    return nullptr;
}

int tx_set_lyrics_language(tx_file* f, const char* language) try {
    if (!has_language_bytes(language)) return 0;
    TagLib::ID3v2::Tag* tag = id3v2_tag(f, false);
    if (!tag) return tx_id3v2_supported(f);
    const auto bytes = language_bytes(language);
    for (auto* frame : tag->frameList("USLT")) {
        if (auto* uslt = dynamic_cast<TagLib::ID3v2::UnsynchronizedLyricsFrame*>(frame))
            uslt->setLanguage(bytes);
    }
    return 1;
} catch (...) {
    return 0;
}

tx_synced_line* tx_get_synced_lyrics(tx_file* f, int32_t* out_count, char** out_language) try {
    if (out_language) *out_language = nullptr;
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;
    TagLib::ID3v2::Tag* tag = id3v2_tag(f, false);
    if (!tag) { *out_count = 0; return nullptr; }
    auto* sylt = first_frame<TagLib::ID3v2::SynchronizedLyricsFrame>(tag, "SYLT");
    if (!sylt) { *out_count = 0; return nullptr; }

    // SYLT kann statt Millisekunden auch MPEG-Frames zählen; das rechnen wir
    // nicht um (dafür fehlt die Frame-Dauer), sondern melden keine Zeilen.
    if (sylt->timestampFormat() != TagLib::ID3v2::SynchronizedLyricsFrame::AbsoluteMilliseconds) {
        *out_count = 0;
        return nullptr;
    }
    std::vector<TagLib::ID3v2::SynchronizedLyricsFrame::SynchedText> lines;
    for (const auto& entry : sylt->synchedText()) lines.push_back(entry);
    std::stable_sort(lines.begin(), lines.end(),
                     [](const auto& a, const auto& b) { return a.time < b.time; });

    const auto count = result_count(lines.size());
    auto out = allocate_result<tx_synced_line, tx_free_synced_lyrics>(count);
    for (size_t i = 0; i < lines.size(); ++i) {
        out[i].text = dup_string(lines[i].text);
        out[i].time_ms = lines[i].time;
    }
    if (out_language) *out_language = copy_language(sylt->language());
    *out_count = count;
    return out.release();
} catch (...) {
    return nullptr;
}

void tx_free_synced_lyrics(tx_synced_line* lines, int32_t count) {
    if (!lines) return;
    for (int32_t i = 0; i < count; ++i) std::free(lines[i].text);
    std::free(lines);
}

int tx_set_synced_lyrics(tx_file* f, const tx_synced_line* lines, int32_t count,
                         const char* language, int preserve_empty) try {
    if (count < 0 || (count > 0 && !lines) || !tx_id3v2_supported(f)) return 0;

    using SyncedFrame = TagLib::ID3v2::SynchronizedLyricsFrame;
    std::unique_ptr<SyncedFrame> sylt;
    if (count > 0 || preserve_empty) {
        SyncedFrame::SynchedTextList list;
        for (int32_t i = 0; i < count; ++i) {
            const auto& line = lines[i];
            if (!fits_in_u32(line.time_ms)) return 0;
            list.append(SyncedFrame::SynchedText(
                static_cast<uint32_t>(line.time_ms),
                TagLib::String(line.text ? line.text : "", TagLib::String::UTF8)));
        }
        sylt = std::make_unique<SyncedFrame>(TagLib::String::UTF8);
        sylt->setLanguage(language_bytes(language));
        sylt->setTimestampFormat(SyncedFrame::AbsoluteMilliseconds);
        sylt->setType(SyncedFrame::Lyrics);
        sylt->setSynchedText(list);
    }

    // Beim Entfernen keinen leeren ID3v2-Tag anlegen.
    auto* tag = id3v2_tag(f, sylt != nullptr);
    if (!tag) return sylt ? 0 : 1;
    tag->removeFrames("SYLT");
    if (sylt)
        transfer_frame(std::move(sylt), tag->frameList(),
                       [tag](auto* frame) { tag->addFrame(frame); });
    return 1;
} catch (...) {
    return 0;
}

int tx_native_field_supported(tx_file* f, const char* id3_frame, const char* mp4_atom) try {
    if (!valid_native_id3_frame(id3_frame) || !f || f->ref.isNull()) return 0;
    if (has_text(id3_frame) && tx_id3v2_supported(f)) return 1;
    if (has_text(mp4_atom) && mp4_tag(f)) return 1;
    return 0;
} catch (...) {
    return 0;
}

char* tx_get_native_field(tx_file* f, const char* id3_frame, const char* mp4_atom) try {
    if (!valid_native_id3_frame(id3_frame) || !f || f->ref.isNull()) return nullptr;
    if (has_text(id3_frame)) {
        if (TagLib::ID3v2::Tag* tag = id3v2_tag(f, false)) {
            const auto& frames = tag->frameList(id3_frame);
            if (frames.isEmpty()) return nullptr;
            // Das Podcast-Flag hat keinen Text — Vorhandensein heißt gesetzt.
            if (std::strcmp(id3_frame, "PCST") == 0) return dup_bytes("1");
            return dup_string(frames.front()->toString());
        }
    }
    if (has_text(mp4_atom)) {
        if (TagLib::MP4::Tag* tag = mp4_tag(f)) {
            if (!tag->contains(mp4_atom)) return nullptr;
            const TagLib::MP4::Item item = tag->item(mp4_atom);
            if (std::strcmp(mp4_atom, "pcst") == 0) return item.toBool() ? dup_bytes("1") : nullptr;
            return dup_string(item.toStringList().toString(", "));
        }
    }
    return nullptr;
} catch (...) {
    return nullptr;
}

int tx_set_native_field(tx_file* f, const char* id3_frame, const char* mp4_atom,
                        const char* value) try {
    if (!valid_native_id3_frame(id3_frame) || !f || f->ref.isNull()) return 0;
    const bool remove = !has_text(value);
    if (has_text(id3_frame) && tx_id3v2_supported(f)) {
        const TagLib::ByteVector frameId(id3_frame, 4);
        std::unique_ptr<TagLib::ID3v2::Frame> frame;
        if (!remove) {
            if (std::strcmp(id3_frame, "PCST") == 0) {
                frame = std::make_unique<TagLib::ID3v2::PodcastFrame>();
            } else {
                auto textFrame = std::make_unique<TagLib::ID3v2::TextIdentificationFrame>(
                    frameId, TagLib::String::UTF8);
                textFrame->setText(TagLib::String(value, TagLib::String::UTF8));
                frame = std::move(textFrame);
            }
        }
        // Beim Entfernen keinen leeren Tag anlegen: ohne Tag gibt es nichts
        // zu entfernen.
        auto* tag = id3v2_tag(f, !remove);
        if (!tag) return remove ? 1 : 0;
        tag->removeFrames(frameId);
        if (frame)
            transfer_frame(std::move(frame), tag->frameList(),
                           [tag](auto* native) { tag->addFrame(native); });
        return 1;
    }
    if (has_text(mp4_atom)) {
        if (TagLib::MP4::Tag* tag = mp4_tag(f)) {
            if (remove) { tag->removeItem(mp4_atom); return 1; }
            if (std::strcmp(mp4_atom, "pcst") == 0) {
                tag->setItem(mp4_atom, TagLib::MP4::Item(true));
            } else {
                tag->setItem(mp4_atom, TagLib::MP4::Item(
                    TagLib::StringList(TagLib::String(value, TagLib::String::UTF8))));
            }
            return 1;
        }
    }
    return 0;
} catch (...) {
    return 0;
}

} // extern "C"
