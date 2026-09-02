// Implementierung des C-Shims über die TagLib-C++-API.
// Einziger Ort im Projekt, der TagLib-Header einbindet.
#include "include/ctagshim.h"

#include <fileref.h>
#include <id3v2framefactory.h>
#include <tpropertymap.h>
#include <tvariant.h>
#include <taglib.h>

// Kapitel: ID3v2 (MP3) gibt es seit TagLib 1.x; MP4- und Matroska-Kapitel kamen
// erst mit TagLib 2.3 bzw. 2.2. Fehlen die Header (ältere Systembibliothek),
// bleibt der Shim baubar und meldet für diese Formate „keine Kapitel".
#include <mpegfile.h>
#include <id3v2tag.h>
#include <chapterframe.h>
#include <tableofcontentsframe.h>
#include <textidentificationframe.h>
#if __has_include(<mp4chapter.h>)
#include <mp4file.h>
#define TX_HAVE_MP4_CHAPTERS 1
#endif
#if __has_include(<matroskachapters.h>)
#include <matroskafile.h>
#include <matroskachapters.h>
#include <matroskachapteredition.h>
#include <matroskachapter.h>
#define TX_HAVE_MATROSKA_CHAPTERS 1
#endif

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <mutex>
#include <random>
#include <string>
#include <vector>

namespace {

// UTF-8-Kopie eines TagLib-Strings als C-String (Aufrufer gibt frei).
char* dup_string(const TagLib::String& s) {
    const std::string utf8 = s.to8Bit(true);
    char* out = static_cast<char*>(std::malloc(utf8.size() + 1));
    if (out) std::memcpy(out, utf8.c_str(), utf8.size() + 1);
    return out;
}

// FrameFactory ist ein prozessweiter TagLib-Singleton. Der Default darf bei
// parallelen Datei-Oeffnungen genau einmal gesetzt werden.
void configure_frame_factory() {
    static std::once_flag once;
    std::call_once(once, [] {
        TagLib::ID3v2::FrameFactory::instance()->setDefaultTextEncoding(
            TagLib::String::UTF8);
    });
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
    // ID3v2-Frames als UTF-8 schreiben (TagLib-Default ist Latin1, was bei
    // Umlauten zu Mojibake in anderen Programmen führt). Einmalig, idempotent.
    configure_frame_factory();
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

} // extern "C"

// ---- Kapitel ------------------------------------------------------------------

namespace {

// Zwischenform, formatunabhängig: Titel, Beginn und Ende in Millisekunden.
struct ChapterEntry {
    TagLib::String title;
    long long startMs = 0;
    long long endMs = -1; // -1 = vom Format nicht geliefert
};

// Die Datei hinter dem FileRef als konkreter TagLib-Typ (nullptr = anderer Typ).
template <typename T>
T* file_as(tx_file* f) {
    if (!f || f->ref.isNull()) return nullptr;
    return dynamic_cast<T*>(f->ref.file());
}

// ID3v2-Millisekunden sind 32 Bit ohne Vorzeichen; größere Werte werden gekappt.
unsigned int clamp_u32(long long ms) {
    if (ms < 0) return 0;
    const long long max = std::numeric_limits<unsigned int>::max();
    return static_cast<unsigned int>(ms > max ? max : ms);
}

// -- MP3: CHAP + CTOC ----------------------------------------------------------

// Titel eines CHAP-Frames: das eingebettete TIT2 (leer, wenn keins vorhanden).
TagLib::String chapter_frame_title(const TagLib::ID3v2::ChapterFrame* frame) {
    const auto& titles = frame->embeddedFrameList("TIT2");
    return titles.isEmpty() ? TagLib::String() : titles.front()->toString();
}

std::vector<ChapterEntry> read_id3_chapters(TagLib::MPEG::File* file) {
    std::vector<ChapterEntry> out;
    TagLib::ID3v2::Tag* tag = file->ID3v2Tag(false);
    if (!tag) return out;

    auto append = [&out](const TagLib::ID3v2::ChapterFrame* chap) {
        ChapterEntry entry;
        entry.title = chapter_frame_title(chap);
        entry.startMs = chap->startTime();
        entry.endMs = chap->endTime();
        out.push_back(entry);
    };

    // Reihenfolge laut Top-Level-Inhaltsverzeichnis (CTOC), wenn es eins gibt.
    // Es verweist über Element-IDs auf die CHAP-Frames.
    if (const auto* toc = TagLib::ID3v2::TableOfContentsFrame::findTopLevel(tag)) {
        for (const auto& childId : toc->childElements()) {
            if (const auto* chap = TagLib::ID3v2::ChapterFrame::findByElementID(tag, childId))
                append(chap);
        }
        if (!out.empty()) return out;
    }
    // Ohne (brauchbares) CTOC: alle CHAP-Frames nach Startzeit sortiert.
    for (const auto* frame : tag->frameList("CHAP")) {
        if (const auto* chap = dynamic_cast<const TagLib::ID3v2::ChapterFrame*>(frame))
            append(chap);
    }
    std::stable_sort(out.begin(), out.end(),
                     [](const ChapterEntry& a, const ChapterEntry& b) { return a.startMs < b.startMs; });
    return out;
}

bool write_id3_chapters(TagLib::MPEG::File* file, const std::vector<ChapterEntry>& chapters) {
    // Beim Entfernen keinen leeren ID3v2-Tag anlegen, wenn es noch keinen gibt.
    TagLib::ID3v2::Tag* tag = file->ID3v2Tag(!chapters.empty());
    if (!tag) return true;
    tag->removeFrames("CHAP");
    tag->removeFrames("CTOC");
    if (chapters.empty()) return true;

    // Element-IDs "chp0", "chp1", … verbinden CTOC und CHAP-Frames. Die
    // Byte-Offsets (0xFFFFFFFF) bedeuten laut ID3-Spezifikation „nicht benutzt“.
    TagLib::ByteVectorList childIds;
    for (size_t i = 0; i < chapters.size(); ++i) {
        const std::string idText = "chp" + std::to_string(i);
        const TagLib::ByteVector elementId(idText.c_str());
        auto* chap = new TagLib::ID3v2::ChapterFrame(
            elementId, clamp_u32(chapters[i].startMs), clamp_u32(chapters[i].endMs),
            0xFFFFFFFFu, 0xFFFFFFFFu);
        auto* title = new TagLib::ID3v2::TextIdentificationFrame("TIT2", TagLib::String::UTF8);
        title->setText(chapters[i].title);
        chap->addEmbeddedFrame(title); // der CHAP-Frame übernimmt das Eigentum
        tag->addFrame(chap);           // der Tag übernimmt das Eigentum
        childIds.append(elementId);
    }
    auto* toc = new TagLib::ID3v2::TableOfContentsFrame("toc", childIds);
    toc->setIsTopLevel(true);
    toc->setIsOrdered(true);
    tag->addFrame(toc);
    return true;
}

// -- MP4: QuickTime-Kapitelspur und Nero chpl ----------------------------------

#ifdef TX_HAVE_MP4_CHAPTERS
std::vector<ChapterEntry> read_mp4_chapters(TagLib::MP4::File* file) {
    // QuickTime-Spur zuerst (Apple Books, iTunes), sonst Nero-Liste.
    TagLib::MP4::ChapterList list = file->qtChapters();
    if (list.isEmpty()) list = file->neroChapters();
    std::vector<ChapterEntry> out;
    for (const auto& chapter : list) {
        ChapterEntry entry;
        entry.title = chapter.title();
        entry.startMs = chapter.startTime();
        out.push_back(entry);
    }
    std::stable_sort(out.begin(), out.end(),
                     [](const ChapterEntry& a, const ChapterEntry& b) { return a.startMs < b.startMs; });
    return out;
}

bool write_mp4_chapters(TagLib::MP4::File* file, const std::vector<ChapterEntry>& chapters) {
    TagLib::MP4::ChapterList list;
    for (const auto& chapter : chapters)
        list.append(TagLib::MP4::Chapter(chapter.title, chapter.startMs));
    // Beide Varianten schreiben, damit Apple-Player (QuickTime-Spur) und der
    // Rest (Nero chpl) dieselben Kapitel sehen.
    file->setNeroChapters(list);
    file->setQtChapters(list);
    return true;
}
#endif

// -- Matroska/WebM: Chapters-Element -------------------------------------------

#ifdef TX_HAVE_MATROSKA_CHAPTERS
std::vector<ChapterEntry> read_matroska_chapters(TagLib::Matroska::File* file) {
    std::vector<ChapterEntry> out;
    const TagLib::Matroska::Chapters* chapters = file->chapters(false);
    if (!chapters) return out;
    const auto& editions = chapters->chapterEditionList();
    if (editions.isEmpty()) return out;

    // Standard-Edition bevorzugen, sonst die erste.
    const TagLib::Matroska::ChapterEdition* edition = &editions.front();
    for (const auto& candidate : editions) {
        if (candidate.isDefault()) { edition = &candidate; break; }
    }
    for (const auto& chapter : edition->chapterList()) {
        ChapterEntry entry;
        const auto& displays = chapter.displayList();
        if (!displays.isEmpty()) entry.title = displays.front().string();
        // Matroska rechnet in Nanosekunden.
        entry.startMs = static_cast<long long>(chapter.timeStart() / 1000000ULL);
        entry.endMs = static_cast<long long>(chapter.timeEnd() / 1000000ULL);
        out.push_back(entry);
    }
    return out;
}

// Matroska verlangt je Kapitel und Edition eine eindeutige UID ungleich 0.
unsigned long long random_uid() {
    static std::mt19937_64 engine{std::random_device{}()};
    static std::mutex engineMutex;
    std::lock_guard<std::mutex> lock(engineMutex);
    unsigned long long uid = 0;
    while (uid == 0) uid = engine();
    return uid;
}

bool write_matroska_chapters(TagLib::Matroska::File* file, const std::vector<ChapterEntry>& chapters) {
    TagLib::Matroska::Chapters* target = file->chapters(!chapters.empty());
    if (!target) return true; // nichts vorhanden, nichts zu entfernen
    target->clear();
    if (chapters.empty()) return true;

    TagLib::List<TagLib::Matroska::Chapter> list;
    for (const auto& chapter : chapters) {
        TagLib::List<TagLib::Matroska::Chapter::Display> displays;
        displays.append(TagLib::Matroska::Chapter::Display(chapter.title, "und"));
        const auto startNs = static_cast<unsigned long long>(std::max(0LL, chapter.startMs)) * 1000000ULL;
        const auto endNs = static_cast<unsigned long long>(std::max(0LL, chapter.endMs)) * 1000000ULL;
        list.append(TagLib::Matroska::Chapter(startNs, endNs, displays, random_uid()));
    }
    target->addChapterEdition(TagLib::Matroska::ChapterEdition(list, true, false, random_uid()));
    return true;
}
#endif

} // namespace

extern "C" {

int tx_chapters_supported(tx_file* f) {
    if (file_as<TagLib::MPEG::File>(f)) return 1;
#ifdef TX_HAVE_MP4_CHAPTERS
    if (file_as<TagLib::MP4::File>(f)) return 1;
#endif
#ifdef TX_HAVE_MATROSKA_CHAPTERS
    if (file_as<TagLib::Matroska::File>(f)) return 1;
#endif
    return 0;
}

tx_chapter* tx_get_chapters(tx_file* f, int32_t* out_count) {
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;

    std::vector<ChapterEntry> entries;
    if (auto* mpeg = file_as<TagLib::MPEG::File>(f)) {
        entries = read_id3_chapters(mpeg);
#ifdef TX_HAVE_MP4_CHAPTERS
    } else if (auto* mp4 = file_as<TagLib::MP4::File>(f)) {
        entries = read_mp4_chapters(mp4);
#endif
#ifdef TX_HAVE_MATROSKA_CHAPTERS
    } else if (auto* mkv = file_as<TagLib::Matroska::File>(f)) {
        entries = read_matroska_chapters(mkv);
#endif
    } else {
        // Format ohne Kapitel: kein Fehler, einfach keine Einträge.
        *out_count = 0;
        return nullptr;
    }

    *out_count = static_cast<int32_t>(entries.size());
    if (entries.empty()) return nullptr;
    auto* out = static_cast<tx_chapter*>(std::calloc(entries.size(), sizeof(tx_chapter)));
    if (!out) { *out_count = -1; return nullptr; }
    for (size_t i = 0; i < entries.size(); ++i) {
        out[i].title = dup_string(entries[i].title);
        out[i].start_ms = entries[i].startMs;
        out[i].end_ms = entries[i].endMs;
    }
    return out;
}

void tx_free_chapters(tx_chapter* chapters, int32_t count) {
    if (!chapters) return;
    for (int32_t i = 0; i < count; ++i)
        std::free(chapters[i].title);
    std::free(chapters);
}

int tx_set_chapters(tx_file* f, const tx_chapter* chapters, int32_t count) {
    if (!f || f->ref.isNull() || (count > 0 && !chapters)) return 0;

    std::vector<ChapterEntry> entries;
    entries.reserve(static_cast<size_t>(count > 0 ? count : 0));
    for (int32_t i = 0; i < count; ++i) {
        ChapterEntry entry;
        entry.title = TagLib::String(chapters[i].title ? chapters[i].title : "", TagLib::String::UTF8);
        entry.startMs = chapters[i].start_ms;
        entry.endMs = chapters[i].end_ms;
        entries.push_back(entry);
    }

    if (auto* mpeg = file_as<TagLib::MPEG::File>(f)) return write_id3_chapters(mpeg, entries) ? 1 : 0;
#ifdef TX_HAVE_MP4_CHAPTERS
    if (auto* mp4 = file_as<TagLib::MP4::File>(f)) return write_mp4_chapters(mp4, entries) ? 1 : 0;
#endif
#ifdef TX_HAVE_MATROSKA_CHAPTERS
    if (auto* mkv = file_as<TagLib::Matroska::File>(f)) return write_matroska_chapters(mkv, entries) ? 1 : 0;
#endif
    return 0;
}

} // extern "C"

// ---- Sonstiges ----------------------------------------------------------------

extern "C" {

const char* tx_taglib_version(void) {
    // TagLib liefert die Version als Makros. Der unveränderliche lokale
    // `static` wird seit C++11 genau einmal und threadsicher initialisiert.
    // Ein bei jedem Aufruf neu beschriebenes char-Array wäre bei parallelen
    // Abfragen ein Datenrennen, obwohl sich der Versionswert nie ändert.
    static const std::string version =
        std::to_string(TAGLIB_MAJOR_VERSION) + "." +
        std::to_string(TAGLIB_MINOR_VERSION) + "." +
        std::to_string(TAGLIB_PATCH_VERSION);
    return version.c_str();
}

} // extern "C"
