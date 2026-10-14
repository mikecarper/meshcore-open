#include "mat_diagnostics.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace aeic {
TensorStatistics diagnose_chw(const ncnn::Mat& tensor) {
    if (tensor.empty() || tensor.dims != 3 || tensor.elempack != 1 || tensor.elemsize != 4)
        throw std::runtime_error("stage output must be float32 CHW");
    size_t plane = size_t(tensor.w) * tensor.h;
    TensorStatistics stats{UINT64_C(14695981039346656037), plane * tensor.c,
                           std::numeric_limits<float>::infinity(),
                           -std::numeric_limits<float>::infinity()};
    for (int c = 0; c < tensor.c; ++c) {
        const float* values = tensor.channel(c);
        const uint8_t* bytes = reinterpret_cast<const uint8_t*>(values);
        for (size_t p = 0; p < plane; ++p) {
            float value = values[p];
            if (!std::isfinite(value)) throw std::runtime_error("nonfinite tensor value");
            stats.minimum = std::min(stats.minimum, value);
            stats.maximum = std::max(stats.maximum, value);
            for (unsigned b = 0; b < 4; ++b) {
                stats.hash ^= bytes[p * 4 + b];
                stats.hash *= UINT64_C(1099511628211);
            }
        }
    }
    return stats;
}
}
