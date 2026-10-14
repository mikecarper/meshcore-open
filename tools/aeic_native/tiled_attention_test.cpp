#include "tiled_attention.h"
#include "net.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <sstream>
#include <string>
#include <vector>
#include <sys/resource.h>

namespace {

FILE* synthetic_weights(int channels) {
    FILE* file = std::tmpfile();
    if (!file) return nullptr;
    std::mt19937 rng(74);
    std::uniform_real_distribution<float> value(-0.125f, 0.125f);
    for (int projection = 0; projection < 4; ++projection) {
        const unsigned tag = 0; // ncnn unquantized float32 matrix.
        if (std::fwrite(&tag, sizeof(tag), 1, file) != 1) { std::fclose(file); return nullptr; }
        for (int i = 0; i < channels * channels + channels; ++i) {
            const float weight = value(rng);
            if (std::fwrite(&weight, sizeof(weight), 1, file) != 1) {
                std::fclose(file); return nullptr;
            }
        }
    }
    std::rewind(file);
    return file;
}

int compare(FILE* weights, int channels, int tokens, int heads,
            bool custom_only = false, int threads = 4) {
    ncnn::Mat input(channels, tokens);
    if (input.empty()) return 3;
    std::mt19937 rng(123);
    std::normal_distribution<float> normal(0.f, 1.f);
    for (int row = 0; row < tokens; ++row)
        for (int column = 0; column < channels; ++column) input.row(row)[column] = normal(rng);
    std::vector<float> baseline;
    double maximum = 0, square = 0;
    for (int custom = custom_only ? 1 : 0; custom < 2; ++custom) {
        ncnn::Net net;
        net.opt.num_threads = threads;
        net.opt.use_packing_layout = false;
        net.opt.use_fp16_storage = false;
        net.opt.use_bf16_storage = false;
        net.opt.use_sgemm_convolution = false;
        net.opt.use_winograd_convolution = false;
        if (custom && aeic::register_tiled_attention(net)) return 4;
        std::ostringstream graph;
        graph << "7767517\n2 2\nInput in0 0 1 in0\n"
              << (custom ? "AEICTiledAttention" : "MultiHeadAttention")
              << " attention0 1 1 in0 out0 0=" << channels << " 1=" << heads
              << " 2=" << channels * channels << " 3=" << channels
              << " 4=" << channels << "\n";
        int result = net.load_param_mem(graph.str().c_str());
        std::rewind(weights);
        if (!result) result = net.load_model(weights);
        if (result) { std::fprintf(stderr, "MHA model load failed: %d\n", result); return 5; }
        auto extractor = net.create_extractor();
        result = extractor.input("in0", input);
        ncnn::Mat output;
        if (!result) result = extractor.extract("out0", output);
        if (result || output.dims != 2 || output.w != channels || output.h != tokens) {
            std::fprintf(stderr, "MHA output failure: %d dims=%d shape=%dx%d\n",
                         result, output.dims, output.w, output.h);
            return 6;
        }
        if (!custom) {
            baseline.resize(size_t(channels) * tokens);
            for (int row = 0; row < tokens; ++row)
                std::copy(output.row(row), output.row(row) + channels,
                          baseline.begin() + size_t(row) * channels);
        } else {
            for (int row = 0; row < tokens; ++row) for (int col = 0; col < channels; ++col) {
                const float value = output.row(row)[col];
                if (!std::isfinite(value)) return 7;
                if (!baseline.empty()) {
                    const double delta = std::fabs(double(value) - baseline[size_t(row) * channels + col]);
                    maximum = std::max(maximum, delta); square += delta * delta;
                }
            }
        }
    }
    rusage usage{}; getrusage(RUSAGE_SELF, &usage);
    std::printf("%s C=%d N=%d heads=%d threads=%d max_abs=%.9g rmse=%.9g peak_kb=%ld\n",
                custom_only ? "TILED_MHA_MEMORY_ONLY" : "TILED_MHA_NATIVE_COMPARE",
                channels, tokens, heads, threads, maximum,
                std::sqrt(square / (size_t(channels) * tokens)), usage.ru_maxrss);
    return maximum > 0.0001 ? 8 : 0;
}

} // namespace

int main(int argc, char** argv) {
    if (argc == 1) {
        // Single query, odd query count, partial final tile, and multiple tiles.
        for (int tokens : {1, 81, 129, 257}) {
            FILE* file = synthetic_weights(32);
            if (!file) return 9;
            const int result = compare(file, 32, tokens, 4);
            std::fclose(file);
            if (result) return result;
        }
        return 0;
    }
    if (argc < 4) {
        std::fprintf(stderr, "usage: tiled_attention_test [BIN C TOKENS [HEADS [custom [THREADS]]]]\n");
        return 2;
    }
    const int channels = std::atoi(argv[2]), tokens = std::atoi(argv[3]);
    const int heads = argc > 4 ? std::atoi(argv[4]) : 5;
    const int threads = argc > 6 ? std::atoi(argv[6]) : 4;
    if (channels < 1 || channels > 1280 || tokens < 1 || tokens > 5184 ||
        heads < 1 || heads > 20 || channels % heads || threads < 1 || threads > 4 ||
        size_t(tokens) * tokens * heads * 4 > 768u * 1024u * 1024u) return 2;
    FILE* file = std::fopen(argv[1], "rb");
    if (!file) return 9;
    const bool custom_only = argc > 5 && std::string(argv[5]) == "custom";
    const int result = compare(file, channels, tokens, heads, custom_only, threads);
    std::fclose(file);
    return result;
}
