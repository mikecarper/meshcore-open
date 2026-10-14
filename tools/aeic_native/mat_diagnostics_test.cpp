#include "mat_diagnostics.h"
#include "entropy.h"
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <vector>

int main() {
    try {
        // Six logical floats per channel leave two cstep padding floats.
        ncnn::Mat tensor(3, 2, 5);
        std::vector<float> reference;
        for (int c = 0; c < tensor.c; ++c) {
            float* values = tensor.channel(c);
            for (size_t p = 0; p < tensor.cstep; ++p) values[p] = std::numeric_limits<float>::quiet_NaN();
            for (int p = 0; p < 6; ++p) {
                values[p] = float(c * 10 + p - 12);
                if (!c && p == 0) values[p] = -0.f;
                if (!c && p == 1) values[p] = std::nextafter(1.f, 2.f);
                if (!c && p == 2) values[p] = std::numeric_limits<float>::denorm_min();
                reference.push_back(values[p]);
            }
        }
        auto stats = aeic::diagnose_chw(tensor);
        if (stats.count != reference.size() || stats.minimum != -9.f || stats.maximum != 33.f ||
            stats.hash != aeic::hash_bytes(reference.data(), reference.size() * 4))
            throw std::runtime_error("streamed statistics differ from contiguous CHW baseline");
        float* first = tensor.channel(0); first[0] = std::numeric_limits<float>::quiet_NaN();
        bool rejected = false;
        try { aeic::diagnose_chw(tensor); } catch (const std::runtime_error&) { rejected = true; }
        if (!rejected) throw std::runtime_error("nonfinite logical value was accepted");
        std::printf("PASS: streaming FNV/range matches flattened CHW, ignores padded NaNs, preserves float bytes, rejects logical NaNs\n");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1;
    }
}
