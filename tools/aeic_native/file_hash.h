#pragma once
#include <cstdint>
#include <string>

namespace aeic {
struct FileHash {
    uint64_t bytes = 0;
    uint64_t fnv1a64 = UINT64_C(14695981039346656037);
};
// Fixed-size streaming storage; model weights can exceed the tensor file cap.
FileHash hash_file_streamed(const std::string& path);
}
