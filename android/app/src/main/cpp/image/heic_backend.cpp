#include "heic_backend.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <libheif/heif.h>

namespace mesh_image {
namespace {
void CheckHeif(heif_error error) {
  if (error.code != heif_error_Ok) throw std::runtime_error(error.message ? error.message : "HEIC operation failed");
}
struct ContextDeleter { void operator()(heif_context* value) const { heif_context_free(value); } };
struct EncoderDeleter { void operator()(heif_encoder* value) const { heif_encoder_release(value); } };
struct HandleDeleter { void operator()(heif_image_handle* value) const { heif_image_handle_release(value); } };
struct FrameDeleter { void operator()(heif_image* value) const { heif_image_release(value); } };

std::unique_ptr<heif_context, ContextDeleter> NewContext() {
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("HEIC context allocation failed");
  heif_security_limits limits = *heif_get_global_security_limits();
  limits.max_image_size_pixels = kMaxDimension * kMaxDimension;
  limits.max_number_of_tiles = 1;
  limits.max_items = 8;
  limits.max_color_profile_size = 64 * 1024;
  limits.max_memory_block_size = 16 * 1024 * 1024;
  limits.max_total_memory = 64 * 1024 * 1024;
  limits.max_sequence_frames = 1;
  limits.max_iloc_extents_per_item = 16;
  limits.max_children_per_box = 32;
  limits.parent = nullptr;
  CheckHeif(heif_context_set_security_limits(context.get(), &limits));
  return context;
}

heif_error WriteHeic(heif_context*, const void* input, size_t size, void* user) {
  auto& output = *static_cast<std::vector<uint8_t>*>(user);
  if (size > kMaxBytes || output.size() > kMaxBytes - size) {
    return heif_error{heif_error_Memory_allocation_error, heif_suberror_Security_limit_exceeded, "HEIC output exceeds its size limit"};
  }
  const auto* bytes = static_cast<const uint8_t*>(input);
  output.insert(output.end(), bytes, bytes + size);
  return heif_error{heif_error_Ok, heif_suberror_Unspecified, "Success"};
}
}  // namespace

std::vector<uint8_t> EncodeHeic(const Image& image, int quality) {
  CheckDimensions(image.width, image.height);
  auto context = NewContext();
  heif_encoder* encoder_pointer = nullptr;
  CheckHeif(heif_context_get_encoder_for_format(context.get(), heif_compression_HEVC, &encoder_pointer));
  std::unique_ptr<heif_encoder, EncoderDeleter> encoder(encoder_pointer);
  CheckHeif(heif_encoder_set_lossy_quality(encoder.get(), quality));
  heif_image* frame_pointer = nullptr;
  CheckHeif(heif_image_create(image.width, image.height, heif_colorspace_RGB, heif_chroma_interleaved_RGB, &frame_pointer));
  std::unique_ptr<heif_image, FrameDeleter> frame(frame_pointer);
  CheckHeif(heif_image_add_plane(frame.get(), heif_channel_interleaved, image.width, image.height, 8));
  int stride = 0;
  uint8_t* plane = heif_image_get_plane(frame.get(), heif_channel_interleaved, &stride);
  if (!plane || stride < static_cast<int>(image.width * 3)) throw std::runtime_error("HEIC RGB allocation failed");
  for (uint32_t y = 0; y < image.height; ++y) {
    for (uint32_t x = 0; x < image.width; ++x) {
      const uint8_t* pixel = image.rgba.data() + (y * image.width + x) * 4;
      const unsigned alpha = pixel[3];
      for (uint32_t c = 0; c < 3; ++c) plane[y * stride + x * 3 + c] = (pixel[c] * alpha + 255 * (255 - alpha) + 127) / 255;
    }
  }
  heif_image_handle* handle_pointer = nullptr;
  CheckHeif(heif_context_encode_image(context.get(), frame.get(), encoder.get(), nullptr, &handle_pointer));
  std::unique_ptr<heif_image_handle, HandleDeleter> handle(handle_pointer);
  // No EXIF/XMP/ICC/image properties are copied into this new image context.
  std::vector<uint8_t> output;
  heif_writer writer{};
  writer.writer_api_version = 1;
  writer.write = WriteHeic;
  CheckHeif(heif_context_write(context.get(), &writer, &output));
  return output;
}

Image DecodeHeic(const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > kMaxBytes) throw std::runtime_error("Invalid HEIC input size");
  auto context = NewContext();
  CheckHeif(heif_context_read_from_memory_without_copy(context.get(), bytes.data(), bytes.size(), nullptr));
  if (heif_context_get_number_of_top_level_images(context.get()) != 1) throw std::runtime_error("HEIC input must contain one still image");
  heif_image_handle* handle_pointer = nullptr;
  CheckHeif(heif_context_get_primary_image_handle(context.get(), &handle_pointer));
  std::unique_ptr<heif_image_handle, HandleDeleter> handle(handle_pointer);
  const int width = heif_image_handle_get_width(handle.get());
  const int height = heif_image_handle_get_height(handle.get());
  CheckDimensions(width, height);
  heif_image* frame_pointer = nullptr;
  CheckHeif(heif_decode_image(handle.get(), &frame_pointer, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, nullptr));
  std::unique_ptr<heif_image, FrameDeleter> frame(frame_pointer);
  int stride = 0;
  const uint8_t* pixels = heif_image_get_plane_readonly(frame.get(), heif_channel_interleaved, &stride);
  if (!pixels || stride < width * 4 || heif_image_get_width(frame.get(), heif_channel_interleaved) != width ||
      heif_image_get_height(frame.get(), heif_channel_interleaved) != height) throw std::runtime_error("HEIC decoded pixel geometry is invalid");
  Image image{static_cast<uint32_t>(width), static_cast<uint32_t>(height), std::vector<uint8_t>(width * height * 4)};
  for (int y = 0; y < height; ++y) std::memcpy(image.rgba.data() + y * width * 4, pixels + y * stride, width * 4);
  return image;
}
}  // namespace mesh_image
