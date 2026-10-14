#include "mat.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
void expect(bool value, const char* description) {
    if (!value) {
        std::fprintf(stderr, "FAIL: %s\n", description);
        std::exit(1);
    }
}
}
int main(int argc, char** argv) {
    bool unsafe = argc == 2 && !std::strcmp(argv[1], "--reproduce-unsafe");
    ncnn::Mat synthesis(32, 32, 576);
    expect(!synthesis.empty(), "source synthesis allocation");
    for (int c = 0; c < synthesis.c; ++c) {
        float* values = synthesis.channel(c);
        for (int p = 0; p < 1024; ++p) values[p] = float(c) + float(p) / 1024.f;
    }
    ncnn::Mat l_T = synthesis.channel_range(0, 320);
    ncnn::Mat residual = synthesis.channel_range(320, 256);
    std::printf("channel_range borrowed=%s\n", l_T.refcount ? "false" : "true");
    if (!unsafe) {
        l_T = l_T.clone(); residual = residual.clone();
        expect(l_T.refcount && residual.refcount, "split outputs own their storage");
    }
    synthesis.release();
    for (int c = 0; c < 320; ++c) {
        const float* values = l_T.channel(c);
        for (int p = 0; p < 1024; ++p)
            expect(values[p] == float(c) + float(p) / 1024.f, "l_T survives source release");
    }
    for (int c = 0; c < 256; ++c) {
        const float* values = residual.channel(c);
        for (int p = 0; p < 1024; ++p)
            expect(values[p] == float(c + 320) + float(p) / 1024.f, "residual survives source release");
    }
    std::printf("PASS: owning l_T/residual copies preserve all pixels after synthesis release\n");
    return 0;
}
