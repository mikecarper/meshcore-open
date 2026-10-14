#pragma once
#include "mat.h"
#include <map>
#include <set>
#include <string>
#include <vector>

namespace aeic {
// Private, per-run scratch storage. Files contain exact logical FP32 CHW bytes;
// no full-size serialization buffer or precision conversion is used.
class TensorSpillStore {
public:
    explicit TensorSpillStore(const std::string& directory);
    ~TensorSpillStore();
    TensorSpillStore(const TensorSpillStore&) = delete;
    TensorSpillStore& operator=(const TensorSpillStore&) = delete;
    void spill(const std::string& slot, const ncnn::Mat& tensor);
    ncnn::Mat restore(const std::string& slot);
    void discard_except(const std::set<std::string>& slots);
    bool contains(const std::string& slot) const;
    const std::string& directory() const { return directory_; }
private:
    struct Record { std::string path; int c, h, w; unsigned long long hash; };
    std::string directory_;
    std::map<std::string, Record> records_;
    unsigned long long sequence_ = 0;
};

// Refuse shared ownership and borrowed views. No caller may retain a future
// consumer of target; that liveness decision is made by the renderer scheduler.
bool add_unique_inplace(ncnn::Mat& target, const ncnn::Mat& other);
struct RowTile { int input_first, input_end, output_first, output_end, crop_first; };
// A source-row halo covers 1x1 or same-padding 3x3 convolution after identity or
// nearest 2x interpolation. Identity uses two rows to preserve the ARM kernel's
// paired-row phase; all valid rows are copied exactly once.
std::vector<RowTile> convolution_row_tiles(int input_height, int scale, int rows = 64);
}
