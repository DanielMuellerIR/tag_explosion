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

// Tag-Schichten: Formate, bei denen TagLib mehrere Tag-Arten nebeneinander
// kennt (siehe Kommentar zu tx_layers_get im Header).
#include <aifffile.h>
#include <apefile.h>
#include <apefooter.h>
#include <apetag.h>
#include <dsdifffile.h>
#include <dsffile.h>
#include <flacfile.h>
#include <id3v1tag.h>
#include <id3v2header.h>
#include <infotag.h>
#include <mpcfile.h>
#include <trueaudiofile.h>
#include <wavfile.h>
#include <wavpackfile.h>
#include <xiphcomment.h>

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

// ---- Tag-Schichten -------------------------------------------------------------

namespace {

// Zwischenform einer Schicht; `keys` ist die '\n'-getrennte Schlüsselliste.
struct LayerEntry {
    int32_t kind = 0;
    int32_t version = 0;
    bool present = false;
    bool strippable = true;
    std::string keys;
};

// Alle Property-Schlüssel eines Tags, '\n'-getrennt (nullptr → leer).
std::string layer_keys(const TagLib::Tag* tag) {
    std::string out;
    if (!tag) return out;
    for (const auto& [key, values] : tag->properties()) {
        if (!out.empty()) out += '\n';
        out += key.to8Bit(true);
    }
    return out;
}

// Major-Version eines ID3v2-Tags (2, 3 oder 4); 0 ohne Tag.
int32_t id3v2_version(const TagLib::ID3v2::Tag* tag) {
    if (!tag || !tag->header()) return 0;
    return static_cast<int32_t>(tag->header()->majorVersion());
}

// APE-Version aus dem Footer (1000 → 1, 2000 → 2); 0 ohne Footer.
int32_t ape_version(const TagLib::APE::Tag* tag) {
    if (!tag || !tag->footer()) return 0;
    return static_cast<int32_t>(tag->footer()->version() / 1000);
}

// Eine Schicht beschreiben. `tag` darf nullptr sein (Schicht fehlt); Schlüssel
// werden nur bei vorhandener Schicht gelesen, damit ein von TagLib intern
// vorab angelegter, leerer Tag nicht als Inhalt erscheint.
LayerEntry make_layer(int32_t kind, bool present, const TagLib::Tag* tag,
                      int32_t version, bool strippable = true) {
    LayerEntry entry;
    entry.kind = kind;
    entry.present = present;
    entry.version = present ? version : 0;
    entry.strippable = strippable;
    if (present) entry.keys = layer_keys(tag);
    return entry;
}

std::vector<LayerEntry> read_layers(tx_file* f) {
    std::vector<LayerEntry> out;
    if (auto* mpeg = file_as<TagLib::MPEG::File>(f)) {
        const auto* v1 = mpeg->ID3v1Tag(false);
        const auto* v2 = mpeg->ID3v2Tag(false);
        const auto* ape = mpeg->APETag(false);
        out.push_back(make_layer(TX_LAYER_ID3V1, mpeg->hasID3v1Tag(), v1, 1));
        out.push_back(make_layer(TX_LAYER_ID3V2, mpeg->hasID3v2Tag(), v2, id3v2_version(v2)));
        out.push_back(make_layer(TX_LAYER_APE, mpeg->hasAPETag(), ape, ape_version(ape)));
    } else if (auto* wav = file_as<TagLib::RIFF::WAV::File>(f)) {
        // WAV: ID3v2Tag()/InfoTag() liefern immer einen Tag (ggf. leer);
        // ob er in der Datei steht, sagen nur hasID3v2Tag()/hasInfoTag().
        const auto* v2 = wav->ID3v2Tag();
        out.push_back(make_layer(TX_LAYER_ID3V2, wav->hasID3v2Tag(), v2, id3v2_version(v2)));
        out.push_back(make_layer(TX_LAYER_INFO, wav->hasInfoTag(), wav->InfoTag(), 0));
    } else if (auto* aiff = file_as<TagLib::RIFF::AIFF::File>(f)) {
        const auto* v2 = aiff->tag();
        out.push_back(make_layer(TX_LAYER_ID3V2, aiff->hasID3v2Tag(), v2, id3v2_version(v2)));
    } else if (auto* dsf = file_as<TagLib::DSF::File>(f)) {
        // DSF kennt kein hasID3v2Tag(); ein nicht leerer Tag gilt als vorhanden.
        const auto* v2 = dsf->tag();
        const bool present = v2 && !v2->isEmpty();
        out.push_back(make_layer(TX_LAYER_ID3V2, present, v2, id3v2_version(v2)));
    } else if (auto* flac = file_as<TagLib::FLAC::File>(f)) {
        const auto* v1 = flac->ID3v1Tag(false);
        const auto* v2 = flac->ID3v2Tag(false);
        out.push_back(make_layer(TX_LAYER_VORBIS, flac->hasXiphComment(), flac->xiphComment(false), 0));
        out.push_back(make_layer(TX_LAYER_ID3V1, flac->hasID3v1Tag(), v1, 1));
        out.push_back(make_layer(TX_LAYER_ID3V2, flac->hasID3v2Tag(), v2, id3v2_version(v2)));
    } else if (auto* ape = file_as<TagLib::APE::File>(f)) {
        const auto* apeTag = ape->APETag(false);
        out.push_back(make_layer(TX_LAYER_APE, ape->hasAPETag(), apeTag, ape_version(apeTag)));
        out.push_back(make_layer(TX_LAYER_ID3V1, ape->hasID3v1Tag(), ape->ID3v1Tag(false), 1));
    } else if (auto* mpc = file_as<TagLib::MPC::File>(f)) {
        const auto* apeTag = mpc->APETag(false);
        out.push_back(make_layer(TX_LAYER_APE, mpc->hasAPETag(), apeTag, ape_version(apeTag)));
        out.push_back(make_layer(TX_LAYER_ID3V1, mpc->hasID3v1Tag(), mpc->ID3v1Tag(false), 1));
    } else if (auto* wv = file_as<TagLib::WavPack::File>(f)) {
        const auto* apeTag = wv->APETag(false);
        out.push_back(make_layer(TX_LAYER_APE, wv->hasAPETag(), apeTag, ape_version(apeTag)));
        out.push_back(make_layer(TX_LAYER_ID3V1, wv->hasID3v1Tag(), wv->ID3v1Tag(false), 1));
    } else if (auto* tta = file_as<TagLib::TrueAudio::File>(f)) {
        const auto* v2 = tta->ID3v2Tag(false);
        out.push_back(make_layer(TX_LAYER_ID3V1, tta->hasID3v1Tag(), tta->ID3v1Tag(false), 1));
        out.push_back(make_layer(TX_LAYER_ID3V2, tta->hasID3v2Tag(), v2, id3v2_version(v2)));
    }
    return out;
}

// Prüft, dass die Maske nur Schichten enthält, die das Format kennt.
bool mask_within(int32_t mask, int32_t allowed) {
    return mask != 0 && (mask & ~allowed) == 0;
}

// AIFF und DSF haben kein strip(): Der einzige ID3v2-Tag wird geleert, save()
// entfernt den Chunk dann (TagLib schreibt leere Tags nicht).
void clear_id3v2(TagLib::ID3v2::Tag* tag) {
    if (!tag) return;
    // Echte Kopie der Zeiger: TagLib::List ist implizit geteilt und erase()
    // löst die Teilung nicht — eine List-Kopie würde beim Entfernen mit
    // schrumpfen und der Iterator ins Leere laufen (Absturz).
    const std::vector<TagLib::ID3v2::Frame*> frames(tag->frameList().begin(), tag->frameList().end());
    for (auto* frame : frames) tag->removeFrame(frame, true);
}

} // namespace

extern "C" {

tx_layer* tx_layers_get(tx_file* f, int32_t* out_count) {
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;

    const std::vector<LayerEntry> entries = read_layers(f);
    *out_count = static_cast<int32_t>(entries.size());
    if (entries.empty()) return nullptr;
    auto* out = static_cast<tx_layer*>(std::calloc(entries.size(), sizeof(tx_layer)));
    if (!out) { *out_count = -1; return nullptr; }
    for (size_t i = 0; i < entries.size(); ++i) {
        out[i].kind = entries[i].kind;
        out[i].version = entries[i].version;
        out[i].present = entries[i].present ? 1 : 0;
        out[i].strippable = entries[i].strippable ? 1 : 0;
        out[i].keys = dup_string(TagLib::String(entries[i].keys, TagLib::String::UTF8));
    }
    return out;
}

void tx_free_layers(tx_layer* layers, int32_t count) {
    if (!layers) return;
    for (int32_t i = 0; i < count; ++i)
        std::free(layers[i].keys);
    std::free(layers);
}

int tx_layers_strip(tx_file* f, int32_t mask) {
    if (!f || f->ref.isNull() || f->readOnly) return 0;

    if (auto* mpeg = file_as<TagLib::MPEG::File>(f)) {
        if (!mask_within(mask, TX_LAYER_ID3V1 | TX_LAYER_ID3V2 | TX_LAYER_APE)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_ID3V1) tags |= TagLib::MPEG::File::ID3v1;
        if (mask & TX_LAYER_ID3V2) tags |= TagLib::MPEG::File::ID3v2;
        if (mask & TX_LAYER_APE)   tags |= TagLib::MPEG::File::APE;
        // MPEG::File::strip schreibt sofort in die Datei.
        return mpeg->strip(tags, true) ? 1 : 0;
    }
    if (auto* wav = file_as<TagLib::RIFF::WAV::File>(f)) {
        if (!mask_within(mask, TX_LAYER_ID3V2 | TX_LAYER_INFO)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_ID3V2) tags |= TagLib::RIFF::WAV::File::ID3v2;
        if (mask & TX_LAYER_INFO)  tags |= TagLib::RIFF::WAV::File::Info;
        // Entfernt die Chunks direkt in der Datei (RIFF-Blockoperationen).
        wav->strip(static_cast<TagLib::RIFF::WAV::File::TagTypes>(tags));
        return 1;
    }
    if (auto* aiff = file_as<TagLib::RIFF::AIFF::File>(f)) {
        if (!mask_within(mask, TX_LAYER_ID3V2)) return 0;
        clear_id3v2(aiff->tag());
        return aiff->save() ? 1 : 0;
    }
    if (auto* dsf = file_as<TagLib::DSF::File>(f)) {
        if (!mask_within(mask, TX_LAYER_ID3V2)) return 0;
        clear_id3v2(dsf->tag());
        return dsf->save() ? 1 : 0;
    }
    if (auto* flac = file_as<TagLib::FLAC::File>(f)) {
        if (!mask_within(mask, TX_LAYER_VORBIS | TX_LAYER_ID3V1 | TX_LAYER_ID3V2)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_VORBIS) tags |= TagLib::FLAC::File::XiphComment;
        if (mask & TX_LAYER_ID3V1)  tags |= TagLib::FLAC::File::ID3v1;
        if (mask & TX_LAYER_ID3V2)  tags |= TagLib::FLAC::File::ID3v2;
        flac->strip(tags);
        return flac->save() ? 1 : 0;
    }
    // APE, MPC und WavPack: gleiche Schichten (APEv2 + ID3v1), gleiche Enums.
    if (auto* ape = file_as<TagLib::APE::File>(f)) {
        if (!mask_within(mask, TX_LAYER_APE | TX_LAYER_ID3V1)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_APE)   tags |= TagLib::APE::File::APE;
        if (mask & TX_LAYER_ID3V1) tags |= TagLib::APE::File::ID3v1;
        ape->strip(tags);
        return ape->save() ? 1 : 0;
    }
    if (auto* mpc = file_as<TagLib::MPC::File>(f)) {
        if (!mask_within(mask, TX_LAYER_APE | TX_LAYER_ID3V1)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_APE)   tags |= TagLib::MPC::File::APE;
        if (mask & TX_LAYER_ID3V1) tags |= TagLib::MPC::File::ID3v1;
        mpc->strip(tags);
        return mpc->save() ? 1 : 0;
    }
    if (auto* wv = file_as<TagLib::WavPack::File>(f)) {
        if (!mask_within(mask, TX_LAYER_APE | TX_LAYER_ID3V1)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_APE)   tags |= TagLib::WavPack::File::APE;
        if (mask & TX_LAYER_ID3V1) tags |= TagLib::WavPack::File::ID3v1;
        wv->strip(tags);
        return wv->save() ? 1 : 0;
    }
    if (auto* tta = file_as<TagLib::TrueAudio::File>(f)) {
        if (!mask_within(mask, TX_LAYER_ID3V1 | TX_LAYER_ID3V2)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_ID3V1) tags |= TagLib::TrueAudio::File::ID3v1;
        if (mask & TX_LAYER_ID3V2) tags |= TagLib::TrueAudio::File::ID3v2;
        tta->strip(tags);
        return tta->save() ? 1 : 0;
    }
    return 0;
}

int tx_save_id3v2(tx_file* f, int32_t id3v2_version) {
    if (!f || f->ref.isNull() || f->readOnly) return 0;
    if (id3v2_version != 3 && id3v2_version != 4) return 0;
    const TagLib::ID3v2::Version version =
        id3v2_version == 3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4;

    // Die Argumente entsprechen jeweils dem parameterlosen save() des
    // Formats — nur die ID3v2-Version weicht ab. Bei MP3 heißt das weiterhin:
    // alle Schichten schreiben, nichts strippen, ID3v1 aus ID3v2 nachziehen.
    if (auto* mpeg = file_as<TagLib::MPEG::File>(f))
        return mpeg->save(TagLib::MPEG::File::AllTags, TagLib::File::StripOthers,
                          version, TagLib::File::Duplicate) ? 1 : 0;
    if (auto* wav = file_as<TagLib::RIFF::WAV::File>(f))
        return wav->save(TagLib::RIFF::WAV::File::AllTags, TagLib::File::StripOthers, version) ? 1 : 0;
    if (auto* aiff = file_as<TagLib::RIFF::AIFF::File>(f))
        return aiff->save(version) ? 1 : 0;
    if (auto* dsf = file_as<TagLib::DSF::File>(f))
        return dsf->save(version) ? 1 : 0;
    if (auto* dsdiff = file_as<TagLib::DSDIFF::File>(f))
        return dsdiff->save(TagLib::DSDIFF::File::AllTags, TagLib::File::StripOthers, version) ? 1 : 0;
    return f->ref.save() ? 1 : 0;
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
