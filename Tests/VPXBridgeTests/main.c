// Encodes synthetic I420 frames to WebM through VPXBridge, then parses and decodes
// the file. Run by scripts/test.sh. Exits non-zero on failure.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "VPXBridge.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (cond) { printf("  ok   "); } else { printf("  FAIL "); failures++; } printf(__VA_ARGS__); printf("\n"); } while (0)

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/vpxbridge-test.webm";
    const int w = 320, h = 180, frames = 45;
    char err[256] = {0};

    TCWebMConfig cfg = { .width = w, .height = h, .frame_rate = 15, .cq_level = 32, .max_bitrate_kbps = 2000,
                         .keyframe_interval = 30, .cpu_used = 6, .threads = 2 };
    TCWebMWriter *writer = tc_webm_open(path, &cfg, err, sizeof err);
    CHECK(writer != NULL, "open (%s)", err);
    if (!writer) return 1;

    // Y/U/V planes with padded strides, like CVPixelBuffer planes.
    const int ys = w + 32, cs = w / 2 + 16;
    unsigned char *y = calloc((size_t)ys * h, 1), *u = calloc((size_t)cs * h / 2, 1), *v = calloc((size_t)cs * h / 2, 1);
    int writeFailed = 0;
    long long endMs = 0; // end of the last frame shown
    for (int f = 0; f < frames; f++) {
        for (int row = 0; row < h; row++)
            for (int col = 0; col < w; col++)
                y[row * ys + col] = (unsigned char)(((col / 16 + row / 16) % 2) ? 200 : 40);
        // a moving bright box
        for (int row = 60; row < 100; row++)
            for (int col = 10 + f * 6; col < 50 + f * 6 && col < w; col++) y[row * ys + col] = 235;
        memset(u, 128, (size_t)cs * h / 2);
        memset(v, 128 + (f % 20), (size_t)cs * h / 2);
        // variable frame timing: every 5th frame is held twice as long
        long long pts = f * 66 + (f / 5) * 66, dur = (f % 5 == 4) ? 132 : 66;
        if (pts + dur > endMs) endMs = pts + dur;
        if (tc_webm_write_frame(writer, y, ys, u, cs, v, cs, pts, dur, err, sizeof err) != 0) { writeFailed = 1; break; }
    }
    CHECK(!writeFailed, "write %d frames (%s)", frames, err);
    long long encoded = tc_webm_bytes_written(writer);
    CHECK(tc_webm_finish(writer, err, sizeof err) == 0, "finish (%s), %lld bytes of video", err, encoded);
    free(y); free(u); free(v);

    TCWebMInfo info;
    CHECK(tc_webm_inspect(path, &info, err, sizeof err) == 0, "inspect (%s)", err);
    CHECK(info.is_vp9, "codec is V_VP9");
    CHECK(info.width == w && info.height == h, "size %dx%d", info.width, info.height);
    CHECK(info.frames == frames, "%d frames in file", info.frames);
    CHECK(info.decoded_frames == frames, "%d frames decode", info.decoded_frames);
    CHECK(info.keyframes >= 2, "%d keyframes (interval 30)", info.keyframes);
    double expected = endMs / 1000.0; // last frame's start + how long it is shown
    double seconds = info.duration_ns / 1e9;
    CHECK(seconds > expected - 0.005 && seconds < expected + 0.005, "duration %.3f s (expected %.3f)", seconds, expected);

    TCWebMWriter *bad = tc_webm_open(path, &(TCWebMConfig){ .width = 321, .height = 180 }, err, sizeof err);
    CHECK(bad == NULL, "odd width rejected (%s)", err);

    printf(failures ? "FAILED (%d)\n" : "PASS\n", failures);
    return failures ? 1 : 0;
}
