#pragma once
#include <cstdint>
#include <vector>

namespace aeic {
// Lossless RGB8 PNG with one filter-zero scanline per row.
std::vector<uint8_t> make_png(uint32_t width, uint32_t height,
                              const std::vector<uint8_t>& rgb);
}
