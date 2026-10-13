// SPDX-License-Identifier: MIT
#include "bpg_backend.h"

#include <algorithm>
#include <memory>

extern "C" {
#include "libbpg.h"
int mesh_bpg_encode_rgba(const uint8_t* rgba, int width, int height, int quality,
                        int (*write_func)(void*, const uint8_t*, int), void* opaque);
void av_max_alloc(size_t size);
}

namespace mesh_image {
namespace {
struct DecoderDeleter {
  void operator()(BPGDecoderContext* decoder) const { bpg_decoder_close(decoder); }
};

int WriteBpg(void* opaque, const uint8_t* input, int length) {
  auto& output = *static_cast<std::vector<uint8_t>*>(opaque);
  if (length < 0 || static_cast<size_t>(length) > kMaxBytes ||
      output.size() > kMaxBytes - static_cast<size_t>(length)) return -1;
  try {
    output.insert(output.end(), input, input + length);
  } catch (...) {
    return -1;
  }
  return length;
}
}  // namespace

std::vector<uint8_t> EncodeBpg(const Image& image, int quality) {
  CheckDimensions(image.width, image.height);
  if (image.width < 16 || image.height < 16 ||
      image.rgba.size() != image.width * image.height * 4 || quality < 0 || quality > 100) {
    throw std::runtime_error("BPG requires a valid RGBA image with both axes at least 16 pixels");
  }
  std::vector<uint8_t> output;
  if (mesh_bpg_encode_rgba(image.rgba.data(), image.width, image.height, quality,
                           WriteBpg, &output) < 0 || output.empty() || output.size() > kMaxBytes) {
    throw std::runtime_error("BPG encoding failed");
  }
  return output;
}

Image DecodeBpg(const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > kMaxBytes) throw std::runtime_error("Invalid BPG input size");
  BPGImageInfo info{};
  // This API reads the small BPG header without starting HEVC decoding.
  if (bpg_decoder_get_info_from_buf(&info, nullptr, bytes.data(), bytes.size()) < 0) {
    throw std::runtime_error("The BPG image header is invalid");
  }
  CheckDimensions(info.width, info.height);
  if (info.has_animation || info.bit_depth != 8) {
    throw std::runtime_error("BPG requires one 8-bit still image");
  }
  av_max_alloc(32 * 1024 * 1024);
  std::unique_ptr<BPGDecoderContext, DecoderDeleter> decoder(bpg_decoder_open());
  if (!decoder) throw std::runtime_error("BPG decoder allocation failed");
  bpg_decoder_keep_extension_data(decoder.get(), 0);
  if (bpg_decoder_decode(decoder.get(), bytes.data(), bytes.size()) < 0) {
    throw std::runtime_error("BPG decoding failed");
  }
  BPGImageInfo decoded{};
  if (bpg_decoder_get_info(decoder.get(), &decoded) < 0 || decoded.width != info.width ||
      decoded.height != info.height || bpg_decoder_start(decoder.get(), BPG_OUTPUT_FORMAT_RGBA32) < 0) {
    throw std::runtime_error("The BPG decoded dimensions are invalid");
  }
  Image image{info.width, info.height, std::vector<uint8_t>(info.width * info.height * 4)};
  for (uint32_t y = 0; y < info.height; y++) {
    if (bpg_decoder_get_line(decoder.get(), image.rgba.data() + y * info.width * 4) < 0) {
      throw std::runtime_error("BPG pixel decoding failed");
    }
  }
  return image;
}
}  // namespace mesh_image
