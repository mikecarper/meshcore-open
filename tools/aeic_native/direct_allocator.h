#pragma once
#include "allocator.h"

namespace aeic {
// Its lifetime exceeds every staged Mat. Returning memory directly to ncnn's
// aligned malloc avoids local pools retaining intermediates and cloning output.
class DirectAllocator final : public ncnn::Allocator {
public:
    void* fastMalloc(size_t bytes) override { return ncnn::fastMalloc(bytes); }
    void fastFree(void* pointer) override { ncnn::fastFree(pointer); }
};
inline ncnn::Allocator* direct_allocator() {
    static DirectAllocator allocator;
    return &allocator;
}
}
