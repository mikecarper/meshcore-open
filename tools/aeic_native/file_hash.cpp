#include "file_hash.h"
#include <array>
#include <cstdio>
#include <limits>
#include <memory>
#include <stdexcept>

namespace aeic {
namespace {
struct CloseFile {
    void operator()(FILE* file) const { std::fclose(file); }
};
}
FileHash hash_file_streamed(const std::string& path) {
    std::unique_ptr<FILE, CloseFile> file(std::fopen(path.c_str(), "rb"));
    if (!file) throw std::runtime_error("cannot open hash input " + path);
    std::array<unsigned char, 65536> chunk;
    FileHash result;
    for (;;) {
        const size_t count = std::fread(chunk.data(), 1, chunk.size(), file.get());
        if (count > std::numeric_limits<uint64_t>::max() - result.bytes)
            throw std::runtime_error("hash input byte count overflow");
        result.bytes += count;
        for (size_t i = 0; i < count; ++i) {
            result.fnv1a64 ^= chunk[i];
            result.fnv1a64 *= UINT64_C(1099511628211);
        }
        if (count < chunk.size()) {
            if (std::ferror(file.get())) throw std::runtime_error("cannot read hash input " + path);
            if (std::feof(file.get())) break;
        }
    }
    return result;
}
}
