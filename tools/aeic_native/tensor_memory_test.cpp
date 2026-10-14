#include "tensor_memory.h"
#include "pause_counter.h"
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>
#if !defined(_WIN32)
#include <sys/stat.h>
#include <unistd.h>
#endif

static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static bool equal(const ncnn::Mat& a, const ncnn::Mat& b) {
    if (a.w != b.w || a.h != b.h || a.c != b.c) return false;
    for (int c = 0; c < a.c; ++c) if (std::memcmp(a.channel(c), b.channel(c), size_t(a.w) * a.h * 4)) return false;
    return true;
}
int main() {
    try {
        ncnn::Mat target(3, 5, 7), other(3, 5, 7);
        for (int c = 0; c < target.c; ++c) {
            float* a = target.channel(c); float* b = other.channel(c);
            for (int i = 0; i < 15; ++i) { a[i] = float((c * 15 + i) % 23 - 11) / 7; b[i] = float(i - c) / 13; }
        }
        ncnn::Mat alias = target;
        ncnn::Mat saved = target.clone();
        require(!aeic::add_unique_inplace(target, other) && equal(target, saved), "shared target must not be modified");
        alias.release();
        ncnn::Mat borrowed(target.w, target.h, target.c, target.data);
        require(!aeic::add_unique_inplace(borrowed, other), "borrowed target must not be modified");
        auto expected = saved.clone();
        for (int c = 0; c < expected.c; ++c) {
            float* values = expected.channel(c); const float* add = other.channel(c);
            for (int i = 0; i < 15; ++i) values[i] += add[i];
        }
        void* allocation = target.data;
        require(aeic::add_unique_inplace(target, other) && target.data == allocation && equal(target, expected), "unique add must reuse exact FP32 storage");
        for (int scale : {1, 2}) for (int height : {1, 31, 32, 65, 288, 576}) {
            auto tiles = aeic::convolution_row_tiles(height, scale);
            int next = 0;
            for (const auto& tile : tiles) {
                require(tile.output_first == next && tile.output_end > next, "tile rows must cover exactly once");
                require(tile.input_first >= 0 && tile.input_end <= height && tile.crop_first >= 0, "invalid halo bounds");
                for (int row = tile.output_first; row < tile.output_end; ++row) {
                    for (int tap = -1; tap <= 1; ++tap) {
                        int physical = row + tap;
                        if (physical < 0 || physical >= height * scale) continue;
                        int needed = physical / scale;
                        require(needed >= tile.input_first && needed < tile.input_end, "convolution halo misses a required source row");
                    }
                }
                next = tile.output_end;
            }
            require(next == height * scale, "incomplete tile coverage");
        }
#if !defined(_WIN32)
        char temporary[] = "/tmp/aeic-spill-test-XXXXXX";
        require(mkdtemp(temporary) != nullptr, "cannot create test directory");
        std::string root = temporary;
        std::string counter_path = root + "/pause";
        aeic::PauseCounter counter(counter_path);
        require(counter() == 0, "absent pause counter must default to zero");
        auto write_counter = [&](const char* text) {
            FILE* counter_file = std::fopen(counter_path.c_str(), "wb");
            require(counter_file != nullptr, "cannot write pause fixture");
            std::fputs(text, counter_file); std::fclose(counter_file);
        };
        write_counter("1234\n"); require(counter() == 1234, "valid pause counter must be read");
        for (const char* invalid : {"12", "-1", "1234x", "18446744073709551616", "0000000000000000000000000000000001235"}) {
            write_counter(invalid); require(counter() == 1234, "pause counter must reject decreases/malformed/overflow/oversize");
        }
        write_counter("9999"); require(counter() == 9999, "pause counter must accept monotonic increase");
        unlink(counter_path.c_str()); require(counter() == 9999, "unavailable atomic replacement must retain last valid value");
        std::string marker = root + "/unrelated";
        FILE* file = std::fopen(marker.c_str(), "wb"); require(file != nullptr, "cannot create marker"); std::fputs("keep", file); std::fclose(file);
        std::string private_path;
        {
            aeic::TensorSpillStore storage(root); private_path = storage.directory();
            storage.spill("padded", target);
            auto restored = storage.restore("padded");
            require(equal(target, restored) && !storage.contains("padded"), "spill must preserve logical CHW bytes and channel padding");
            storage.spill("corrupted", target);
            file = std::fopen((private_path + "/tensor-1").c_str(), "r+b"); require(file != nullptr, "cannot mutate fixture");
            std::fputc(255, file); std::fclose(file);
            bool rejected = false;
            try { storage.restore("corrupted"); } catch (const std::exception&) { rejected = true; }
            require(rejected, "changed scratch bytes must fail checksum");
            storage.spill("unused", other);
            storage.discard_except({"corrupted"});
            require(!storage.contains("unused"), "dead spilled slots must be discarded");
        }
        struct stat status;
        require(lstat(private_path.c_str(), &status) != 0 && lstat(marker.c_str(), &status) == 0, "cleanup must remove only owned scratch files");
        std::string link = root + "/link";
        require(symlink(root.c_str(), link.c_str()) == 0, "cannot create symlink fixture");
        bool rejected = false;
        try { aeic::TensorSpillStore unsafe(link); } catch (const std::exception&) { rejected = true; }
        require(rejected, "symlink spill root must be rejected");
        unlink(link.c_str()); unlink(marker.c_str()); rmdir(root.c_str());
#endif
        std::puts("PASS: exact FP32 spill, bounded halos, alias-safe storage reuse, private cleanup");
        return 0;
    } catch (const std::exception& error) { std::fprintf(stderr, "FAIL %s\n", error.what()); return 1; }
}
