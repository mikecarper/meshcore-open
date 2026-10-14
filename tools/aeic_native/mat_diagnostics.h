#pragma once
#include "mat.h"
#include <cstdint>

namespace aeic {
struct TensorStatistics {
    uint64_t hash;
    size_t count;
    float minimum, maximum;
};
// Hash/range traverse logical CHW values without copying or hashing cstep padding.
TensorStatistics diagnose_chw(const ncnn::Mat& tensor);
}
