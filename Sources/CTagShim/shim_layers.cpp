// Abfrage und Entfernung formatspezifischer Tag-Schichten.
#include "shim_internal.hpp"

#include <aifffile.h>
#include <apefile.h>
#include <apefooter.h>
#include <apetag.h>
#include <dsdifffile.h>
#include <dsffile.h>
#include <flacfile.h>
#include <id3v1tag.h>
#include <id3v2header.h>
#include <id3v2tag.h>
#include <infotag.h>
#include <mpcfile.h>
#include <mpegfile.h>
#include <trueaudiofile.h>
#include <wavfile.h>
#include <wavpackfile.h>
#include <xiphcomment.h>

#include <string>
#include <vector>

using namespace tx_shim;

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

template <typename File>
void append_ape_layers(std::vector<LayerEntry>& layers, File* file) {
    const auto* ape = file->APETag(false);
    layers.push_back(make_layer(TX_LAYER_APE, file->hasAPETag(), ape, ape_version(ape)));
    layers.push_back(make_layer(TX_LAYER_ID3V1, file->hasID3v1Tag(), file->ID3v1Tag(false), 1));
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
        append_ape_layers(out, ape);
    } else if (auto* mpc = file_as<TagLib::MPC::File>(f)) {
        append_ape_layers(out, mpc);
    } else if (auto* wv = file_as<TagLib::WavPack::File>(f)) {
        append_ape_layers(out, wv);
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

template <typename File>
int strip_ape_layers(File* file, int32_t mask) {
    if (!mask_within(mask, TX_LAYER_APE | TX_LAYER_ID3V1)) return 0;
    int tags = 0;
    if (mask & TX_LAYER_APE) tags |= File::APE;
    if (mask & TX_LAYER_ID3V1) tags |= File::ID3v1;
    file->strip(tags);
    return file->save() ? 1 : 0;
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

tx_layer* tx_layers_get(tx_file* f, int32_t* out_count) try {
    if (out_count) *out_count = -1;
    if (!f || f->ref.isNull() || !out_count) return nullptr;

    const std::vector<LayerEntry> entries = read_layers(f);
    const auto count = result_count(entries.size());
    auto out = allocate_result<tx_layer, tx_free_layers>(count);
    for (size_t i = 0; i < entries.size(); ++i) {
        out[i].kind = entries[i].kind;
        out[i].version = entries[i].version;
        out[i].present = entries[i].present ? 1 : 0;
        out[i].strippable = entries[i].strippable ? 1 : 0;
        out[i].keys = dup_bytes(entries[i].keys);
    }
    *out_count = count;
    return out.release();
} catch (...) {
    return nullptr;
}

void tx_free_layers(tx_layer* layers, int32_t count) {
    if (!layers) return;
    for (int32_t i = 0; i < count; ++i)
        std::free(layers[i].keys);
    std::free(layers);
}

int tx_layers_strip(tx_file* f, int32_t mask) try {
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
    if (auto* ape = file_as<TagLib::APE::File>(f)) return strip_ape_layers(ape, mask);
    if (auto* mpc = file_as<TagLib::MPC::File>(f)) return strip_ape_layers(mpc, mask);
    if (auto* wv = file_as<TagLib::WavPack::File>(f)) return strip_ape_layers(wv, mask);
    if (auto* tta = file_as<TagLib::TrueAudio::File>(f)) {
        if (!mask_within(mask, TX_LAYER_ID3V1 | TX_LAYER_ID3V2)) return 0;
        int tags = 0;
        if (mask & TX_LAYER_ID3V1) tags |= TagLib::TrueAudio::File::ID3v1;
        if (mask & TX_LAYER_ID3V2) tags |= TagLib::TrueAudio::File::ID3v2;
        tta->strip(tags);
        return tta->save() ? 1 : 0;
    }
    return 0;
} catch (...) {
    return 0;
}

int tx_save_id3v2(tx_file* f, int32_t id3v2_version) try {
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
} catch (...) {
    return 0;
}

} // extern "C"
