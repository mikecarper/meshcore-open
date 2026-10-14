#include "file_hash.h"
#include "entropy.h"
#include <cstdio>
#include <stdexcept>
#include <vector>

namespace {
void expect(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
}
int main() {
    const char* path = "aeic_file_hash_test.tmp";
    try {
        aeic::write_file(path, "hello", 5);
        auto hash = aeic::hash_file_streamed(path);
        expect(hash.bytes == 5 && hash.fnv1a64 == UINT64_C(0xa430d84680aabd0b), "known FNV-1a file hash");
        aeic::write_file(path, nullptr, 0);
        hash = aeic::hash_file_streamed(path);
        expect(hash.bytes == 0 && hash.fnv1a64 == UINT64_C(14695981039346656037), "empty file hash");
        std::vector<unsigned char> data(131073);
        for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<unsigned char>((i * 37 + i / 251) & 255);
        aeic::write_file(path, data.data(), data.size());
        hash = aeic::hash_file_streamed(path);
        expect(hash.bytes == data.size() && hash.fnv1a64 == aeic::hash_bytes(data.data(), data.size()), "hash across two chunk boundaries");
        std::remove(path);
        bool rejected = false;
        try { aeic::hash_file_streamed(path); } catch (const std::runtime_error&) { rejected = true; }
        expect(rejected, "missing hash input must fail");
        std::puts("FILE_HASH_TEST_COMPLETE");
        return 0;
    } catch (const std::exception& error) {
        std::remove(path);
        std::fprintf(stderr, "file hash test failed: %s\n", error.what());
        return 1;
    }
}
