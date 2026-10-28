// VP9 encoding (libvpx) into a WebM file (libwebm mkvmuxer).
#include "VPXBridge.h"

#include <cstdio>
#include <cstring>
#include <memory>

#include "vpx/vp8cx.h"
#include "vpx/vpx_encoder.h"
#include "mkvmuxer/mkvmuxer.h"
#include "mkvmuxer/mkvwriter.h"

struct TCWebMWriter {
    vpx_codec_ctx_t codec{};
    bool codec_ready = false;
    mkvmuxer::MkvWriter file;
    std::unique_ptr<mkvmuxer::Segment> segment;
    uint64_t track = 0;
    int width = 0, height = 0;
    int64_t bytes = 0;
    int64_t end_ms = 0; // end of the last frame shown (pts + duration)
};

namespace {

void set_error(char *error, size_t size, const char *message, const char *detail = nullptr) {
    if (!error || size == 0) return;
    if (detail && *detail) {
        std::snprintf(error, size, "%s: %s", message, detail);
    } else {
        std::snprintf(error, size, "%s", message);
    }
}

void codec_error(TCWebMWriter *w, char *error, size_t size, const char *message) {
    const char *detail = vpx_codec_error_detail(&w->codec);
    set_error(error, size, message, detail ? detail : vpx_codec_error(&w->codec));
}

// Moves every finished packet into the WebM segment. Timebase is milliseconds.
bool drain(TCWebMWriter *w, char *error, size_t size) {
    vpx_codec_iter_t iter = nullptr;
    const vpx_codec_cx_pkt_t *pkt;
    while ((pkt = vpx_codec_get_cx_data(&w->codec, &iter)) != nullptr) {
        if (pkt->kind != VPX_CODEC_CX_FRAME_PKT) continue;
        const bool key = (pkt->data.frame.flags & VPX_FRAME_IS_KEY) != 0;
        const uint64_t timestamp_ns = static_cast<uint64_t>(pkt->data.frame.pts) * 1000000ULL;
        if (!w->segment->AddFrame(static_cast<const uint8_t *>(pkt->data.frame.buf), pkt->data.frame.sz,
                                  w->track, timestamp_ns, key)) {
            set_error(error, size, "Couldn't write a frame to the WebM file");
            return false;
        }
        w->bytes += static_cast<int64_t>(pkt->data.frame.sz);
    }
    return true;
}

} // namespace

extern "C" TCWebMWriter *tc_webm_open(const char *path, const TCWebMConfig *config, char *error, size_t error_size) {
    if (!path || !config || config->width <= 0 || config->height <= 0 || (config->width & 1) || (config->height & 1)) {
        set_error(error, error_size, "Invalid WebM settings");
        return nullptr;
    }
    auto w = std::make_unique<TCWebMWriter>();
    w->width = config->width;
    w->height = config->height;

    vpx_codec_iface_t *iface = vpx_codec_vp9_cx();
    vpx_codec_enc_cfg_t cfg;
    if (vpx_codec_enc_config_default(iface, &cfg, 0) != VPX_CODEC_OK) {
        set_error(error, error_size, "VP9 encoder unavailable");
        return nullptr;
    }
    cfg.g_w = static_cast<unsigned>(config->width);
    cfg.g_h = static_cast<unsigned>(config->height);
    cfg.g_timebase.num = 1;
    cfg.g_timebase.den = 1000;        // milliseconds: frames keep their real (variable) timing
    cfg.g_threads = static_cast<unsigned>(config->threads > 0 ? config->threads : 4);
    cfg.g_lag_in_frames = 16;         // lets the encoder use alt-ref frames
    cfg.g_pass = VPX_RC_ONE_PASS;
    cfg.rc_end_usage = VPX_CQ;        // constrained quality
    cfg.rc_target_bitrate = static_cast<unsigned>(config->max_bitrate_kbps > 0 ? config->max_bitrate_kbps : 8000);
    cfg.rc_min_quantizer = 0;
    cfg.rc_max_quantizer = 63;
    cfg.kf_mode = VPX_KF_AUTO;
    cfg.kf_min_dist = 0;
    cfg.kf_max_dist = static_cast<unsigned>(config->keyframe_interval > 0 ? config->keyframe_interval : 60);

    if (vpx_codec_enc_init(&w->codec, iface, &cfg, 0) != VPX_CODEC_OK) {
        codec_error(w.get(), error, error_size, "Couldn't start the VP9 encoder");
        return nullptr;
    }
    w->codec_ready = true;
    vpx_codec_control(&w->codec, VP8E_SET_CPUUSED, config->cpu_used);
    vpx_codec_control(&w->codec, VP8E_SET_CQ_LEVEL, config->cq_level);
    vpx_codec_control(&w->codec, VP9E_SET_ROW_MT, 1);
    vpx_codec_control(&w->codec, VP9E_SET_TILE_COLUMNS, 2);
    vpx_codec_control(&w->codec, VP9E_SET_TUNE_CONTENT, VP9E_CONTENT_SCREEN);
    vpx_codec_control(&w->codec, VP8E_SET_ENABLEAUTOALTREF, 1);
    // The exporter feeds BT.709 video-range planes (AVAssetReader is asked for that);
    // tagging the stream makes browsers convert colors the same way.
    vpx_codec_control(&w->codec, VP9E_SET_COLOR_SPACE, VPX_CS_BT_709);
    vpx_codec_control(&w->codec, VP9E_SET_COLOR_RANGE, VPX_CR_STUDIO_RANGE);

    if (!w->file.Open(path)) {
        set_error(error, error_size, "Couldn't create the WebM file", path);
        tc_webm_abort(w.release());
        return nullptr;
    }
    w->segment = std::make_unique<mkvmuxer::Segment>();
    if (!w->segment->Init(&w->file)) {
        set_error(error, error_size, "Couldn't start the WebM container");
        tc_webm_abort(w.release());
        return nullptr;
    }
    w->segment->set_mode(mkvmuxer::Segment::kFile);
    w->segment->OutputCues(true);
    w->segment->GetSegmentInfo()->set_writing_app("Tinycap");
    w->segment->GetSegmentInfo()->set_muxing_app("Tinycap (libwebm)");
    w->track = w->segment->AddVideoTrack(config->width, config->height, 0);
    auto *video = static_cast<mkvmuxer::VideoTrack *>(w->segment->GetTrackByNumber(w->track));
    if (!w->track || !video) {
        set_error(error, error_size, "Couldn't add the video track");
        tc_webm_abort(w.release());
        return nullptr;
    }
    video->set_codec_id(mkvmuxer::Tracks::kVp9CodecId);
    if (config->frame_rate > 0) video->set_frame_rate(config->frame_rate);
    w->segment->CuesTrack(w->track);
    return w.release();
}

extern "C" int tc_webm_write_frame(TCWebMWriter *w,
                                   const uint8_t *y, int y_stride,
                                   const uint8_t *u, int u_stride,
                                   const uint8_t *v, int v_stride,
                                   int64_t pts_ms, int64_t duration_ms,
                                   char *error, size_t error_size) {
    if (!w || !w->codec_ready) {
        set_error(error, error_size, "WebM writer is closed");
        return -1;
    }
    vpx_image_t image;
    // Wrap the caller's planes; vpx_img_wrap sets up format and sizes, then the
    // plane pointers and strides are pointed at the real (possibly padded) planes.
    vpx_img_wrap(&image, VPX_IMG_FMT_I420, static_cast<unsigned>(w->width), static_cast<unsigned>(w->height), 1,
                 const_cast<uint8_t *>(y));
    image.planes[VPX_PLANE_Y] = const_cast<uint8_t *>(y);
    image.planes[VPX_PLANE_U] = const_cast<uint8_t *>(u);
    image.planes[VPX_PLANE_V] = const_cast<uint8_t *>(v);
    image.stride[VPX_PLANE_Y] = y_stride;
    image.stride[VPX_PLANE_U] = u_stride;
    image.stride[VPX_PLANE_V] = v_stride;

    const unsigned long duration = static_cast<unsigned long>(duration_ms > 0 ? duration_ms : 1);
    if (pts_ms + static_cast<int64_t>(duration) > w->end_ms) w->end_ms = pts_ms + static_cast<int64_t>(duration);
    if (vpx_codec_encode(&w->codec, &image, pts_ms, duration, 0, VPX_DL_GOOD_QUALITY) != VPX_CODEC_OK) {
        codec_error(w, error, error_size, "VP9 encoding failed");
        return -1;
    }
    return drain(w, error, error_size) ? 0 : -1;
}

extern "C" int tc_webm_finish(TCWebMWriter *w, char *error, size_t error_size) {
    if (!w) return -1;
    int result = 0;
    if (w->codec_ready) {
        // Flush frames held for look-ahead.
        do {
            if (vpx_codec_encode(&w->codec, nullptr, 0, 1, 0, VPX_DL_GOOD_QUALITY) != VPX_CODEC_OK) {
                codec_error(w, error, error_size, "VP9 encoding failed while finishing");
                result = -1;
                break;
            }
            const int64_t before = w->bytes;
            if (!drain(w, error, error_size)) { result = -1; break; }
            if (w->bytes == before) break;
        } while (true);
    }
    // Without this the container's duration stops at the start of the last frame.
    // Segment duration is in timecode-scale units, which default to 1 ms.
    if (result == 0 && w->segment && w->end_ms > 0) {
        w->segment->set_duration(static_cast<double>(w->end_ms));
    }
    if (result == 0 && w->segment && !w->segment->Finalize()) {
        set_error(error, error_size, "Couldn't finish the WebM file");
        result = -1;
    }
    w->file.Close();
    w->segment.reset();
    if (w->codec_ready) vpx_codec_destroy(&w->codec);
    w->codec_ready = false;
    delete w;
    return result;
}

extern "C" void tc_webm_abort(TCWebMWriter *w) {
    if (!w) return;
    w->segment.reset();
    w->file.Close();
    if (w->codec_ready) vpx_codec_destroy(&w->codec);
    delete w;
}

extern "C" int64_t tc_webm_bytes_written(const TCWebMWriter *w) {
    return w ? w->bytes : 0;
}
