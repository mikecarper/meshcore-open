#include "png_writer.h"
#include <cstring>
#include <limits>
#include <stdexcept>
#include <zlib.h>

namespace aeic {
namespace {
void be32(std::vector<uint8_t>& bytes, uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8)
        bytes.push_back(static_cast<uint8_t>(value >> shift));
}
void chunk(std::vector<uint8_t>& png, const char* type,
           const std::vector<uint8_t>& bytes) {
    if (bytes.size() > std::numeric_limits<uint32_t>::max())
        throw std::runtime_error("PNG chunk too large");
    be32(png, static_cast<uint32_t>(bytes.size()));
    size_t first = png.size();
    png.insert(png.end(), type, type + 4);
    png.insert(png.end(), bytes.begin(), bytes.end());
    uLong crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, png.data() + first, static_cast<uInt>(4 + bytes.size()));
    be32(png, static_cast<uint32_t>(crc));
}
}
std::vector<uint8_t> make_png(uint32_t width, uint32_t height,
                              const std::vector<uint8_t>& rgb) {
    if (!width || !height || width > 576 || height > 576 || rgb.size() != size_t(width) * height * 3)
        throw std::runtime_error("invalid PNG RGB dimensions");
    size_t row = size_t(width) * 3;
    std::vector<uint8_t> filtered((row + 1) * height, 0);
    for (uint32_t h = 0; h < height; ++h)
        std::memcpy(filtered.data() + size_t(h) * (row + 1) + 1, rgb.data() + size_t(h) * row, row);
    uLongf size = compressBound(static_cast<uLong>(filtered.size()));
    std::vector<uint8_t> compressed(size);
    int result = compress2(compressed.data(), &size, filtered.data(),
                           static_cast<uLong>(filtered.size()), Z_BEST_SPEED);
    if (result != Z_OK) throw std::runtime_error("PNG zlib compression failed");
    compressed.resize(size);
    std::vector<uint8_t> png{137, 80, 78, 71, 13, 10, 26, 10};
    std::vector<uint8_t> header;
    be32(header, width); be32(header, height);
    header.insert(header.end(), {8, 2, 0, 0, 0});
    chunk(png, "IHDR", header); chunk(png, "IDAT", compressed); chunk(png, "IEND", {});
    return png;
}
}
