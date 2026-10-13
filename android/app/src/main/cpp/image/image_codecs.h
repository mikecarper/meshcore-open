#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace mesh_image {
constexpr uint32_t kMagic = 0x31434d49;  // IMC1, little endian.
constexpr uint32_t kMaxDimension = 512;
constexpr uint32_t kMaxBytes = 4 * 1024 * 1024;
enum Codec : uint32_t { kWebP = 1, kJpeg = 2, kPng = 3, kAvif = 4, kJxl = 5, kJp2 = 6, kVvc = 7, kHeic = 8, kBpg = 9 };

struct RequestHeader {
  uint32_t magic;
  uint32_t operation;
  uint32_t codec;
  uint32_t quality;
  uint32_t width;
  uint32_t height;
  uint32_t length;
};
struct ResponseHeader {
  uint32_t magic;
  uint32_t status;
  uint32_t width;
  uint32_t height;
  uint32_t length;
};
struct Image {
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> rgba;
};

inline void CheckDimensions(uint32_t width, uint32_t height) {
  if (!width || !height || width > kMaxDimension || height > kMaxDimension) {
    throw std::runtime_error("Image dimensions exceed the 512 x 512 limit");
  }
}

std::vector<uint8_t> Encode(Codec codec, const Image& image, int quality);
Image Decode(Codec codec, const std::vector<uint8_t>& bytes);
}  // namespace mesh_image
