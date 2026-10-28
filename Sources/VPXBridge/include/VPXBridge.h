// C interface over libvpx (VP9 encoder) and libwebm (mkvmuxer) for Tinycap's WebM
// export. Kept in C so Swift can import it without C++ interop.
#ifndef TINYCAP_VPX_BRIDGE_H
#define TINYCAP_VPX_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TCWebMWriter TCWebMWriter;

typedef struct {
    int width;               // even, > 0
    int height;              // even, > 0
    double frame_rate;       // nominal, for the container and rate control
    int cq_level;            // constant quality, 0 (best) … 63 (smallest)
    int max_bitrate_kbps;    // cap in constrained-quality mode
    int keyframe_interval;   // frames between forced keyframes
    int cpu_used;            // 0 (slowest, best) … 8 (fastest)
    int threads;
} TCWebMConfig;

/// Opens `path` for writing. Returns NULL and fills `error` on failure.
TCWebMWriter *tc_webm_open(const char *path, const TCWebMConfig *config, char *error, size_t error_size);

/// Encodes one I420 frame shown from `pts_ms` for `duration_ms` (variable frame rate is fine).
/// Returns 0 on success.
int tc_webm_write_frame(TCWebMWriter *writer,
                        const uint8_t *y, int y_stride,
                        const uint8_t *u, int u_stride,
                        const uint8_t *v, int v_stride,
                        int64_t pts_ms, int64_t duration_ms,
                        char *error, size_t error_size);

/// Flushes the encoder, writes cues and closes the file, then frees the writer.
/// Returns 0 on success.
int tc_webm_finish(TCWebMWriter *writer, char *error, size_t error_size);

/// Frees the writer without finalizing (the file is left incomplete; delete it).
void tc_webm_abort(TCWebMWriter *writer);

/// Encoded bytes written so far (frame data only).
int64_t tc_webm_bytes_written(const TCWebMWriter *writer);

/// What `tc_webm_inspect` found in a file. Used by verification tools, not the app.
typedef struct {
    int width;
    int height;
    int is_vp9;
    int64_t duration_ns;
    int frames;
    int keyframes;
    int decoded_frames;
} TCWebMInfo;

/// Parses a WebM file with mkvparser and decodes every frame with libvpx.
/// Returns 0 on success. Defined in VPXInspect.cc, which the app doesn't link.
int tc_webm_inspect(const char *path, TCWebMInfo *info, char *error, size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
