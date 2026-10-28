// Reads a WebM file back (libwebm mkvparser) and decodes every VP9 frame (libvpx),
// so scripts/export-check.sh can verify exports without a browser. Not linked
// into the app.
#include "VPXBridge.h"

#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

#include "vpx/vp8dx.h"
#include "vpx/vpx_decoder.h"
#include "mkvparser/mkvparser.h"
#include "mkvparser/mkvreader.h"

namespace {
void set_error(char *error, size_t size, const char *message) {
    if (error && size) std::snprintf(error, size, "%s", message);
}
} // namespace

extern "C" int tc_webm_inspect(const char *path, TCWebMInfo *info, char *error, size_t error_size) {
    if (!path || !info) return -1;
    std::memset(info, 0, sizeof(*info));

    mkvparser::MkvReader reader;
    if (reader.Open(path) != 0) { set_error(error, error_size, "can't open file"); return -1; }

    long long pos = 0;
    mkvparser::EBMLHeader header;
    if (header.Parse(&reader, pos) < 0) { set_error(error, error_size, "not an EBML file"); return -1; }

    mkvparser::Segment *raw = nullptr;
    if (mkvparser::Segment::CreateInstance(&reader, pos, raw) != 0 || !raw) {
        set_error(error, error_size, "no segment"); return -1;
    }
    std::unique_ptr<mkvparser::Segment> segment(raw);
    if (segment->Load() < 0) { set_error(error, error_size, "segment didn't load"); return -1; }

    const mkvparser::Tracks *tracks = segment->GetTracks();
    const mkvparser::VideoTrack *video = nullptr;
    for (unsigned long i = 0; tracks && i < tracks->GetTracksCount(); ++i) {
        const mkvparser::Track *t = tracks->GetTrackByIndex(i);
        if (t && t->GetType() == mkvparser::Track::kVideo) { video = static_cast<const mkvparser::VideoTrack *>(t); break; }
    }
    if (!video) { set_error(error, error_size, "no video track"); return -1; }
    info->width = static_cast<int>(video->GetWidth());
    info->height = static_cast<int>(video->GetHeight());
    info->is_vp9 = video->GetCodecId() && std::strcmp(video->GetCodecId(), "V_VP9") == 0;
    info->duration_ns = segment->GetInfo() ? segment->GetInfo()->GetDuration() : 0;

    vpx_codec_ctx_t decoder;
    if (vpx_codec_dec_init(&decoder, vpx_codec_vp9_dx(), nullptr, 0) != VPX_CODEC_OK) {
        set_error(error, error_size, "VP9 decoder unavailable"); return -1;
    }

    std::vector<unsigned char> buffer;
    for (const mkvparser::Cluster *cluster = segment->GetFirst(); cluster && !cluster->EOS();
         cluster = segment->GetNext(cluster)) {
        const mkvparser::BlockEntry *entry = nullptr;
        if (cluster->GetFirst(entry) < 0) break;
        while (entry && !entry->EOS()) {
            const mkvparser::Block *block = entry->GetBlock();
            if (block && block->GetTrackNumber() == video->GetNumber()) {
                for (int i = 0; i < block->GetFrameCount(); ++i) {
                    const mkvparser::Block::Frame &frame = block->GetFrame(i);
                    buffer.resize(static_cast<size_t>(frame.len));
                    if (frame.Read(&reader, buffer.data()) != 0) break;
                    info->frames++;
                    if (block->IsKey()) info->keyframes++;
                    if (vpx_codec_decode(&decoder, buffer.data(), static_cast<unsigned>(buffer.size()), nullptr, 0) == VPX_CODEC_OK) {
                        vpx_codec_iter_t iter = nullptr;
                        while (vpx_codec_get_frame(&decoder, &iter)) info->decoded_frames++;
                    }
                }
            }
            if (cluster->GetNext(entry, entry) < 0) break;
        }
    }
    vpx_codec_destroy(&decoder);
    return 0;
}
