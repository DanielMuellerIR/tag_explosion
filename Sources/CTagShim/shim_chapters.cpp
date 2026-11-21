// Kapitel-Leser und -Schreiber für die unterstützten TagLib-Container.
#include "shim_internal.hpp"

#include <chapterframe.h>
#include <id3v2tag.h>
#include <mpegfile.h>
#include <tableofcontentsframe.h>
#include <textidentificationframe.h>

// MP4- und Matroska-Kapitel sind ab TagLib 2.3 bzw. 2.2 verfügbar.
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

#include <mutex>
#include <random>
#include <vector>

using namespace tx_shim;

namespace {

// Zwischenform, formatunabhängig: Titel, Beginn und Ende in Millisekunden.
struct ChapterEntry {
    TagLib::String title;
    long long startMs = 0;
    long long endMs = -1; // -1 = vom Format nicht geliefert
};

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
    // CHAP speichert Millisekunden als UInt32. Stilles Kürzen wäre ein
    // erfolgreicher Save mit anderen Kapitelgrenzen als angefordert.
    for (const auto& chapter : chapters) {
        if (!fits_in_u32(chapter.startMs) || !fits_in_u32(chapter.endMs)) return false;
    }

    // Element-IDs "chp0", "chp1", … verbinden CTOC und CHAP-Frames. Die
    // Byte-Offsets (0xFFFFFFFF) bedeuten laut ID3-Spezifikation „nicht benutzt“.
    std::vector<std::unique_ptr<TagLib::ID3v2::Frame>> frames;
    TagLib::ByteVectorList childIds;
    for (size_t i = 0; i < chapters.size(); ++i) {
        const std::string idText = "chp" + std::to_string(i);
        const TagLib::ByteVector elementId(idText.c_str());
        auto chap = std::make_unique<TagLib::ID3v2::ChapterFrame>(
            elementId, static_cast<uint32_t>(chapters[i].startMs), static_cast<uint32_t>(chapters[i].endMs),
            0xFFFFFFFFu, 0xFFFFFFFFu);
        auto title = std::make_unique<TagLib::ID3v2::TextIdentificationFrame>("TIT2", TagLib::String::UTF8);
        title->setText(chapters[i].title);
        transfer_frame(std::move(title), chap->embeddedFrameList(),
                       [&chap](auto* frame) { chap->addEmbeddedFrame(frame); });
        frames.push_back(std::move(chap));
        childIds.append(elementId);
    }
    if (!frames.empty()) {
        auto toc = std::make_unique<TagLib::ID3v2::TableOfContentsFrame>("toc", childIds);
        toc->setIsTopLevel(true);
        toc->setIsOrdered(true);
        frames.push_back(std::move(toc));
    }

    // Beim Entfernen keinen leeren ID3v2-Tag anlegen, wenn es noch keinen gibt.
    auto* tag = file->ID3v2Tag(!frames.empty());
    if (!tag) return frames.empty();
    tag->removeFrames("CHAP");
    tag->removeFrames("CTOC");
    for (auto& frame : frames)
        transfer_frame(std::move(frame), tag->frameList(),
                       [tag](auto* chapter) { tag->addFrame(chapter); });
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
    for (const auto& chapter : chapters) {
        if (chapter.startMs < 0) return false;
        list.append(TagLib::MP4::Chapter(chapter.title, chapter.startMs));
    }
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
    // Die Umrechnung zu UInt64-Nanosekunden muss vor clear() möglich sein.
    constexpr auto maxMs = std::numeric_limits<unsigned long long>::max() / 1000000ULL;
    for (const auto& chapter : chapters) {
        if (chapter.startMs < 0 || chapter.endMs < 0
            || static_cast<unsigned long long>(chapter.startMs) > maxMs
            || static_cast<unsigned long long>(chapter.endMs) > maxMs) return false;
    }
    if (chapters.empty()) {
        if (auto* target = file->chapters(false)) target->clear();
        return true;
    }

    TagLib::List<TagLib::Matroska::Chapter> list;
    for (const auto& chapter : chapters) {
        TagLib::List<TagLib::Matroska::Chapter::Display> displays;
        displays.append(TagLib::Matroska::Chapter::Display(chapter.title, "und"));
        const auto startNs = static_cast<unsigned long long>(chapter.startMs) * 1000000ULL;
        const auto endNs = static_cast<unsigned long long>(chapter.endMs) * 1000000ULL;
        list.append(TagLib::Matroska::Chapter(startNs, endNs, displays, random_uid()));
    }
    const TagLib::Matroska::ChapterEdition edition(list, true, false, random_uid());
    auto* target = file->chapters(true);
    if (!target) return false;
    target->clear();
    target->addChapterEdition(edition);
    return true;
}
#endif

} // namespace

extern "C" {

int tx_chapters_supported(tx_file* f) try {
    if (file_as<TagLib::MPEG::File>(f)) return 1;
#ifdef TX_HAVE_MP4_CHAPTERS
    if (file_as<TagLib::MP4::File>(f)) return 1;
#endif
#ifdef TX_HAVE_MATROSKA_CHAPTERS
    if (file_as<TagLib::Matroska::File>(f)) return 1;
#endif
    return 0;
} catch (...) {
    return 0;
}

tx_chapter* tx_get_chapters(tx_file* f, int32_t* out_count) try {
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

    const auto count = result_count(entries.size());
    auto out = allocate_result<tx_chapter, tx_free_chapters>(count);
    for (size_t i = 0; i < entries.size(); ++i) {
        out[i].title = dup_string(entries[i].title);
        out[i].start_ms = entries[i].startMs;
        out[i].end_ms = entries[i].endMs;
    }
    *out_count = count;
    return out.release();
} catch (...) {
    return nullptr;
}

void tx_free_chapters(tx_chapter* chapters, int32_t count) {
    if (!chapters) return;
    for (int32_t i = 0; i < count; ++i)
        std::free(chapters[i].title);
    std::free(chapters);
}

int tx_set_chapters(tx_file* f, const tx_chapter* chapters, int32_t count) try {
    if (count < 0 || (count > 0 && !chapters) || !f || f->ref.isNull()) return 0;

    std::vector<ChapterEntry> entries;
    entries.reserve(static_cast<size_t>(count));
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
} catch (...) {
    return 0;
}

} // extern "C"
