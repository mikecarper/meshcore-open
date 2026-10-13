#include "image_codecs.h"
#include "heic_backend.h"
#include "vvc_backend.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <setjmp.h>

#include <avif/avif.h>
#include <jpeglib.h>
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <openjpeg.h>
#include <png.h>
#include <webp/decode.h>
#include <webp/encode.h>

namespace mesh_image {
namespace {
Image NewImage(uint32_t width, uint32_t height) {
  CheckDimensions(width, height);
  return Image{width, height, std::vector<uint8_t>(width * height * 4)};
}

std::vector<uint8_t> EncodeWebP(const Image& image, int quality) {
  WebPConfig config;
  if (!WebPConfigInit(&config)) throw std::runtime_error("WebP encoder initialization failed");
  config.quality = static_cast<float>(quality);
  config.method = 4;
  config.thread_level = 0;
  config.low_memory = 1;
  WebPPicture picture;
  if (!WebPPictureInit(&picture)) throw std::runtime_error("WebP picture initialization failed");
  picture.width = image.width;
  picture.height = image.height;
  picture.use_argb = 1;
  WebPMemoryWriter writer;
  WebPMemoryWriterInit(&writer);
  picture.writer = WebPMemoryWrite;
  picture.custom_ptr = &writer;
  if (!WebPPictureImportRGBA(&picture, image.rgba.data(), image.width * 4)) {
    WebPPictureFree(&picture);
    throw std::runtime_error("WebP pixel allocation failed");
  }
  const bool success = WebPEncode(&config, &picture);
  WebPPictureFree(&picture);
  if (!success || writer.size > kMaxBytes) {
    WebPMemoryWriterClear(&writer);
    throw std::runtime_error("WebP encoding failed");
  }
  std::vector<uint8_t> output(writer.mem, writer.mem + writer.size);
  WebPMemoryWriterClear(&writer);
  return output;
}

Image DecodeWebP(const std::vector<uint8_t>& bytes) {
  int width = 0, height = 0;
  if (!WebPGetInfo(bytes.data(), bytes.size(), &width, &height)) {
    throw std::runtime_error("Invalid WebP header");
  }
  Image image = NewImage(width, height);
  if (!WebPDecodeRGBAInto(bytes.data(), bytes.size(), image.rgba.data(), image.rgba.size(), width * 4)) {
    throw std::runtime_error("WebP decoding failed");
  }
  return image;
}

struct JpegError {
  jpeg_error_mgr manager;
  jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
};
void JpegErrorExit(j_common_ptr context) {
  auto* error = reinterpret_cast<JpegError*>(context->err);
  (*context->err->format_message)(context, error->message);
  longjmp(error->jump, 1);
}
std::vector<uint8_t> EncodeJpeg(const Image& image, int quality) {
  jpeg_compress_struct context{};
  JpegError error{};
  context.err = jpeg_std_error(&error.manager);
  error.manager.error_exit = JpegErrorExit;
  unsigned char* memory = nullptr;
  unsigned long length = 0;
  std::vector<uint8_t> row(image.width * 3);
  if (setjmp(error.jump)) {
    jpeg_destroy_compress(&context);
    free(memory);
    throw std::runtime_error(error.message);
  }
  jpeg_create_compress(&context);
  jpeg_mem_dest(&context, &memory, &length);
  context.image_width = image.width;
  context.image_height = image.height;
  context.input_components = 3;
  context.in_color_space = JCS_RGB;
  jpeg_set_defaults(&context);
  jpeg_set_quality(&context, quality, TRUE);
  context.optimize_coding = TRUE;
  context.write_JFIF_header = FALSE;
  context.write_Adobe_marker = FALSE;
  jpeg_start_compress(&context, TRUE);
  while (context.next_scanline < image.height) {
    const uint8_t* source = image.rgba.data() + context.next_scanline * image.width * 4;
    for (uint32_t x = 0; x < image.width; ++x) {
      for (uint32_t c = 0; c < 3; ++c) row[x * 3 + c] = source[x * 4 + c];
    }
    JSAMPROW pointer = row.data();
    jpeg_write_scanlines(&context, &pointer, 1);
  }
  jpeg_finish_compress(&context);
  jpeg_destroy_compress(&context);
  if (length > kMaxBytes) {
    free(memory);
    throw std::runtime_error("JPEG output exceeds its size limit");
  }
  std::vector<uint8_t> output(memory, memory + length);
  free(memory);
  return output;
}

Image DecodeJpeg(const std::vector<uint8_t>& bytes) {
  jpeg_decompress_struct context{};
  JpegError error{};
  context.err = jpeg_std_error(&error.manager);
  error.manager.error_exit = JpegErrorExit;
  Image image;
  std::vector<uint8_t> row;
  if (setjmp(error.jump)) {
    jpeg_destroy_decompress(&context);
    throw std::runtime_error(error.message);
  }
  jpeg_create_decompress(&context);
  jpeg_mem_src(&context, bytes.data(), bytes.size());
  jpeg_read_header(&context, TRUE);
  CheckDimensions(context.image_width, context.image_height);
  context.out_color_space = JCS_RGB;
  jpeg_start_decompress(&context);
  image = NewImage(context.output_width, context.output_height);
  row.resize(image.width * 3);
  while (context.output_scanline < image.height) {
    const uint32_t y = context.output_scanline;
    JSAMPROW pointer = row.data();
    if (jpeg_read_scanlines(&context, &pointer, 1) != 1) {
      jpeg_destroy_decompress(&context);
      throw std::runtime_error("JPEG scanline was truncated");
    }
    for (uint32_t x = 0; x < image.width; ++x) {
      for (uint32_t c = 0; c < 3; ++c) image.rgba[(y * image.width + x) * 4 + c] = row[x * 3 + c];
      image.rgba[(y * image.width + x) * 4 + 3] = 255;
    }
  }
  jpeg_finish_decompress(&context);
  jpeg_destroy_decompress(&context);
  return image;
}

std::vector<uint8_t> EncodePng(const Image& image) {
  png_image context{};
  context.version = PNG_IMAGE_VERSION;
  context.width = image.width;
  context.height = image.height;
  context.format = PNG_FORMAT_RGBA;
  png_alloc_size_t size = 0;
  if (!png_image_write_to_memory(&context, nullptr, &size, 0, image.rgba.data(), 0, nullptr) || size > kMaxBytes) {
    png_image_free(&context);
    throw std::runtime_error("PNG output size calculation failed");
  }
  std::vector<uint8_t> output(size);
  if (!png_image_write_to_memory(&context, output.data(), &size, 0, image.rgba.data(), 0, nullptr)) {
    const std::string message = context.message;
    png_image_free(&context);
    throw std::runtime_error(message);
  }
  png_image_free(&context);
  output.resize(size);
  // The simplified libpng API adds an sRGB chunk. Retain only critical chunks
  // (IHDR/IDAT/IEND here), dropping every optional metadata chunk.
  std::vector<uint8_t> stripped(output.begin(), output.begin() + 8);
  for (size_t offset = 8; offset + 12 <= output.size();) {
    const uint32_t length = (uint32_t(output[offset]) << 24) | (uint32_t(output[offset + 1]) << 16) |
        (uint32_t(output[offset + 2]) << 8) | uint32_t(output[offset + 3]);
    if (length > output.size() - offset - 12) throw std::runtime_error("Invalid generated PNG chunk");
    if (!(output[offset + 4] & 0x20)) stripped.insert(stripped.end(), output.begin() + offset, output.begin() + offset + length + 12);
    offset += length + 12;
  }
  return stripped;
}

Image DecodePng(const std::vector<uint8_t>& bytes) {
  png_image context{};
  context.version = PNG_IMAGE_VERSION;
  if (!png_image_begin_read_from_memory(&context, bytes.data(), bytes.size())) {
    const std::string message = context.message;
    png_image_free(&context);
    throw std::runtime_error(message);
  }
  CheckDimensions(context.width, context.height);
  Image image = NewImage(context.width, context.height);
  context.format = PNG_FORMAT_RGBA;
  if (!png_image_finish_read(&context, nullptr, image.rgba.data(), 0, nullptr)) {
    const std::string message = context.message;
    png_image_free(&context);
    throw std::runtime_error(message);
  }
  png_image_free(&context);
  return image;
}

struct AvifImageDeleter { void operator()(avifImage* value) const { avifImageDestroy(value); } };
struct AvifEncoderDeleter { void operator()(avifEncoder* value) const { avifEncoderDestroy(value); } };
struct AvifDecoderDeleter { void operator()(avifDecoder* value) const { avifDecoderDestroy(value); } };

std::vector<uint8_t> EncodeAvif(const Image& image, int quality) {
  std::unique_ptr<avifImage, AvifImageDeleter> frame(avifImageCreate(image.width, image.height, 8, AVIF_PIXEL_FORMAT_YUV420));
  if (!frame) throw std::runtime_error("AVIF image allocation failed");
  frame->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;
  frame->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
  frame->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;
  avifRGBImage rgb{};
  avifRGBImageSetDefaults(&rgb, frame.get());
  rgb.format = AVIF_RGB_FORMAT_RGBA;
  rgb.depth = 8;
  rgb.pixels = const_cast<uint8_t*>(image.rgba.data());
  rgb.rowBytes = image.width * 4;
  rgb.ignoreAlpha = AVIF_TRUE;
  if (avifImageRGBToYUV(frame.get(), &rgb) != AVIF_RESULT_OK) throw std::runtime_error("AVIF RGB conversion failed");
  std::unique_ptr<avifEncoder, AvifEncoderDeleter> encoder(avifEncoderCreate());
  if (!encoder) throw std::runtime_error("AVIF encoder allocation failed");
  encoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
  encoder->maxThreads = 1;
  encoder->speed = 7;
  encoder->quality = quality;
  encoder->qualityAlpha = quality;
  avifRWData output = AVIF_DATA_EMPTY;
  const avifResult status = avifEncoderWrite(encoder.get(), frame.get(), &output);
  if (status != AVIF_RESULT_OK || output.size > kMaxBytes) {
    avifRWDataFree(&output);
    throw std::runtime_error("AVIF encoding failed");
  }
  std::vector<uint8_t> bytes(output.data, output.data + output.size);
  avifRWDataFree(&output);
  return bytes;
}

Image DecodeAvif(const std::vector<uint8_t>& bytes) {
  std::unique_ptr<avifDecoder, AvifDecoderDeleter> decoder(avifDecoderCreate());
  if (!decoder) throw std::runtime_error("AVIF decoder allocation failed");
  decoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
  decoder->maxThreads = 1;
  decoder->imageSizeLimit = kMaxDimension * kMaxDimension;
  decoder->imageDimensionLimit = kMaxDimension;
  decoder->imageCountLimit = 1;
  decoder->ignoreExif = AVIF_TRUE;
  decoder->ignoreXMP = AVIF_TRUE;
  decoder->strictFlags = AVIF_STRICT_ENABLED;
  avifResult status = avifDecoderSetIOMemory(decoder.get(), bytes.data(), bytes.size());
  if (status == AVIF_RESULT_OK) status = avifDecoderParse(decoder.get());
  if (status == AVIF_RESULT_OK) status = avifDecoderNextImage(decoder.get());
  if (status != AVIF_RESULT_OK) throw std::runtime_error("AVIF decoding failed");
  Image image = NewImage(decoder->image->width, decoder->image->height);
  avifRGBImage rgb{};
  avifRGBImageSetDefaults(&rgb, decoder->image);
  rgb.format = AVIF_RGB_FORMAT_RGBA;
  rgb.depth = 8;
  rgb.pixels = image.rgba.data();
  rgb.rowBytes = image.width * 4;
  if (avifImageYUVToRGB(decoder->image, &rgb) != AVIF_RESULT_OK) throw std::runtime_error("AVIF pixel conversion failed");
  return image;
}

struct JxlEncoderDeleter { void operator()(JxlEncoder* value) const { JxlEncoderDestroy(value); } };
struct JxlDecoderDeleter { void operator()(JxlDecoder* value) const { JxlDecoderDestroy(value); } };
std::vector<uint8_t> EncodeJxl(const Image& image, int quality) {
  std::unique_ptr<JxlEncoder, JxlEncoderDeleter> encoder(JxlEncoderCreate(nullptr));
  if (!encoder) throw std::runtime_error("JPEG XL encoder allocation failed");
  JxlBasicInfo info;
  JxlEncoderInitBasicInfo(&info);
  info.xsize = image.width;
  info.ysize = image.height;
  info.bits_per_sample = 8;
  info.num_color_channels = 3;
  info.num_extra_channels = 0;
  info.uses_original_profile = JXL_FALSE;
  if (JxlEncoderSetBasicInfo(encoder.get(), &info) != JXL_ENC_SUCCESS) throw std::runtime_error("JPEG XL image header failed");
  JxlColorEncoding color;
  JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
  if (JxlEncoderSetColorEncoding(encoder.get(), &color) != JXL_ENC_SUCCESS) throw std::runtime_error("JPEG XL color setup failed");
  JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(encoder.get(), nullptr);
  const float distance = quality >= 100 ? 0.01f : (0.1f + (100 - quality) * 0.2f);
  if (JxlEncoderSetFrameDistance(settings, distance) != JXL_ENC_SUCCESS ||
      JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 3) != JXL_ENC_SUCCESS) {
    throw std::runtime_error("JPEG XL quality setup failed");
  }
  std::vector<uint8_t> rgb(image.width * image.height * 3);
  for (size_t i = 0; i < image.width * image.height; ++i) {
    std::memcpy(rgb.data() + i * 3, image.rgba.data() + i * 4, 3);
  }
  const JxlPixelFormat format{3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
  if (JxlEncoderAddImageFrame(settings, &format, rgb.data(), rgb.size()) != JXL_ENC_SUCCESS) throw std::runtime_error("JPEG XL image encode failed");
  JxlEncoderCloseInput(encoder.get());
  std::vector<uint8_t> output(4096);
  size_t used = 0;
  while (true) {
    uint8_t* pointer = output.data() + used;
    size_t remaining = output.size() - used;
    const auto status = JxlEncoderProcessOutput(encoder.get(), &pointer, &remaining);
    used = output.size() - remaining;
    if (status == JXL_ENC_SUCCESS) break;
    if (status != JXL_ENC_NEED_MORE_OUTPUT || output.size() >= kMaxBytes) throw std::runtime_error("JPEG XL output failed");
    output.resize(std::min<size_t>(output.size() * 2, kMaxBytes));
  }
  output.resize(used);
  return output;
}

Image DecodeJxl(const std::vector<uint8_t>& bytes) {
  std::unique_ptr<JxlDecoder, JxlDecoderDeleter> decoder(JxlDecoderCreate(nullptr));
  if (!decoder) throw std::runtime_error("JPEG XL decoder allocation failed");
  if (JxlDecoderSubscribeEvents(decoder.get(), JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS ||
      JxlDecoderSetInput(decoder.get(), bytes.data(), bytes.size()) != JXL_DEC_SUCCESS) throw std::runtime_error("JPEG XL input failed");
  JxlDecoderCloseInput(decoder.get());
  const JxlPixelFormat format{4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
  Image image;
  bool completed = false;
  while (true) {
    const auto status = JxlDecoderProcessInput(decoder.get());
    if (status == JXL_DEC_BASIC_INFO) {
      JxlBasicInfo info{};
      if (JxlDecoderGetBasicInfo(decoder.get(), &info) != JXL_DEC_SUCCESS || info.have_animation) throw std::runtime_error("Invalid JPEG XL image header");
      image = NewImage(info.xsize, info.ysize);
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      size_t size = 0;
      if (image.rgba.empty() || JxlDecoderImageOutBufferSize(decoder.get(), &format, &size) != JXL_DEC_SUCCESS || size != image.rgba.size() ||
          JxlDecoderSetImageOutBuffer(decoder.get(), &format, image.rgba.data(), size) != JXL_DEC_SUCCESS) throw std::runtime_error("JPEG XL pixel buffer failed");
    } else if (status == JXL_DEC_FULL_IMAGE) {
      completed = true;
    } else if (status == JXL_DEC_SUCCESS) {
      if (!completed) throw std::runtime_error("JPEG XL image was incomplete");
      return image;
    } else {
      throw std::runtime_error("JPEG XL decoding failed");
    }
  }
}

struct OpjBuffer {
  std::vector<uint8_t> bytes;
  size_t offset = 0;
  bool invalid = false;
};
OPJ_SIZE_T OpjRead(void* output, OPJ_SIZE_T size, void* user) {
  auto& buffer = *static_cast<OpjBuffer*>(user);
  if (buffer.offset >= buffer.bytes.size()) return static_cast<OPJ_SIZE_T>(-1);
  size = std::min<size_t>(size, buffer.bytes.size() - buffer.offset);
  std::memcpy(output, buffer.bytes.data() + buffer.offset, size);
  buffer.offset += size;
  return size;
}
OPJ_SIZE_T OpjWrite(void* input, OPJ_SIZE_T size, void* user) {
  auto& buffer = *static_cast<OpjBuffer*>(user);
  if (size > kMaxBytes || buffer.offset > kMaxBytes - size) {
    buffer.invalid = true;
    return static_cast<OPJ_SIZE_T>(-1);
  }
  if (buffer.bytes.size() < buffer.offset + size) buffer.bytes.resize(buffer.offset + size);
  std::memcpy(buffer.bytes.data() + buffer.offset, input, size);
  buffer.offset += size;
  return size;
}
OPJ_OFF_T OpjSkip(OPJ_OFF_T count, void* user) {
  auto& buffer = *static_cast<OpjBuffer*>(user);
  const auto next = static_cast<int64_t>(buffer.offset) + count;
  if (next < 0 || next > kMaxBytes) return -1;
  buffer.offset = static_cast<size_t>(next);
  return count;
}
OPJ_BOOL OpjSeek(OPJ_OFF_T offset, void* user) {
  auto& buffer = *static_cast<OpjBuffer*>(user);
  if (offset < 0 || offset > kMaxBytes) return OPJ_FALSE;
  buffer.offset = static_cast<size_t>(offset);
  return OPJ_TRUE;
}
void OpjMessage(const char*, void*) {}
struct OpjCodecDeleter { void operator()(opj_codec_t* value) const { opj_destroy_codec(value); } };
struct OpjImageDeleter { void operator()(opj_image_t* value) const { opj_image_destroy(value); } };
struct OpjStreamDeleter { void operator()(opj_stream_t* value) const { opj_stream_destroy(value); } };
std::unique_ptr<opj_stream_t, OpjStreamDeleter> NewOpjStream(OpjBuffer& buffer, bool reading) {
  std::unique_ptr<opj_stream_t, OpjStreamDeleter> stream(opj_stream_create(4096, reading));
  if (!stream) throw std::runtime_error("JPEG 2000 stream allocation failed");
  opj_stream_set_user_data(stream.get(), &buffer, nullptr);
  opj_stream_set_user_data_length(stream.get(), buffer.bytes.size());
  opj_stream_set_read_function(stream.get(), OpjRead);
  opj_stream_set_write_function(stream.get(), OpjWrite);
  opj_stream_set_skip_function(stream.get(), OpjSkip);
  opj_stream_set_seek_function(stream.get(), OpjSeek);
  return stream;
}

std::vector<uint8_t> EncodeJp2(const Image& image, int quality) {
  opj_cparameters_t parameters;
  opj_set_default_encoder_parameters(&parameters);
  parameters.tcp_numlayers = 1;
  parameters.cp_disto_alloc = 1;
  parameters.tcp_rates[0] = quality >= 100 ? 0.f : 2.f + (100 - quality) * 0.8f;
  parameters.irreversible = quality < 100;
  parameters.tcp_mct = 1;
  parameters.cp_comment = const_cast<char*>("");
  parameters.numresolution = 1;
  for (uint32_t size = std::min(image.width, image.height); size >= 2 && parameters.numresolution < 6; size >>= 1) ++parameters.numresolution;
  opj_image_cmptparm_t components[3]{};
  for (auto& component : components) {
    component.dx = component.dy = 1;
    component.w = image.width;
    component.h = image.height;
    component.prec = 8;
    component.sgnd = 0;
  }
  std::unique_ptr<opj_image_t, OpjImageDeleter> frame(opj_image_create(3, components, OPJ_CLRSPC_SRGB));
  if (!frame) throw std::runtime_error("JPEG 2000 image allocation failed");
  frame->x1 = image.width;
  frame->y1 = image.height;
  for (uint32_t c = 0; c < 3; ++c) {
    for (size_t pixel = 0; pixel < image.width * image.height; ++pixel) frame->comps[c].data[pixel] = image.rgba[pixel * 4 + c];
  }
  // A raw JPEG 2000 codestream saves the JP2 container overhead for radio
  // transport. The decoder accepts both raw J2K and JP2 containers.
  std::unique_ptr<opj_codec_t, OpjCodecDeleter> codec(opj_create_compress(OPJ_CODEC_J2K));
  if (!codec) throw std::runtime_error("JPEG 2000 encoder allocation failed");
  opj_set_error_handler(codec.get(), OpjMessage, nullptr);
  opj_set_warning_handler(codec.get(), OpjMessage, nullptr);
  opj_set_info_handler(codec.get(), OpjMessage, nullptr);
  if (!opj_setup_encoder(codec.get(), &parameters, frame.get()) || !opj_codec_set_threads(codec.get(), 1)) throw std::runtime_error("JPEG 2000 encoder setup failed");
  OpjBuffer buffer;
  auto stream = NewOpjStream(buffer, false);
  if (!opj_start_compress(codec.get(), frame.get(), stream.get()) || !opj_encode(codec.get(), stream.get()) ||
      !opj_end_compress(codec.get(), stream.get()) || buffer.invalid) throw std::runtime_error("JPEG 2000 encoding failed");
  // OpenJPEG writes an empty COM marker even with an empty comment. Remove it
  // from the main codestream header; no optional metadata is transmitted.
  std::vector<uint8_t> stripped(buffer.bytes.begin(), buffer.bytes.begin() + 2);
  size_t offset = 2;
  while (offset + 4 <= buffer.bytes.size()) {
    if (buffer.bytes[offset] != 0xff) throw std::runtime_error("Invalid generated JPEG 2000 marker");
    if (buffer.bytes[offset + 1] == 0x90) break;  // SOT begins the first tile.
    const size_t length = (size_t(buffer.bytes[offset + 2]) << 8) | buffer.bytes[offset + 3];
    if (length < 2 || length + 2 > buffer.bytes.size() - offset) throw std::runtime_error("Invalid generated JPEG 2000 marker size");
    if (buffer.bytes[offset + 1] != 0x64) stripped.insert(stripped.end(), buffer.bytes.begin() + offset, buffer.bytes.begin() + offset + length + 2);
    offset += length + 2;
  }
  stripped.insert(stripped.end(), buffer.bytes.begin() + offset, buffer.bytes.end());
  return stripped;
}

Image DecodeJp2(const std::vector<uint8_t>& bytes) {
  opj_dparameters_t parameters;
  opj_set_default_decoder_parameters(&parameters);
  const bool codestream = bytes.size() > 1 && bytes[0] == 0xff && bytes[1] == 0x4f;
  std::unique_ptr<opj_codec_t, OpjCodecDeleter> codec(opj_create_decompress(codestream ? OPJ_CODEC_J2K : OPJ_CODEC_JP2));
  if (!codec) throw std::runtime_error("JPEG 2000 decoder allocation failed");
  opj_set_error_handler(codec.get(), OpjMessage, nullptr);
  opj_set_warning_handler(codec.get(), OpjMessage, nullptr);
  opj_set_info_handler(codec.get(), OpjMessage, nullptr);
  if (!opj_setup_decoder(codec.get(), &parameters) || !opj_codec_set_threads(codec.get(), 1)) throw std::runtime_error("JPEG 2000 decoder setup failed");
  OpjBuffer buffer{bytes};
  auto stream = NewOpjStream(buffer, true);
  opj_image_t* pointer = nullptr;
  if (!opj_read_header(stream.get(), codec.get(), &pointer)) throw std::runtime_error("JPEG 2000 header failed");
  std::unique_ptr<opj_image_t, OpjImageDeleter> frame(pointer);
  if (!frame || frame->x1 <= frame->x0 || frame->y1 <= frame->y0 || (frame->numcomps != 1 && frame->numcomps != 3 && frame->numcomps != 4)) throw std::runtime_error("Invalid JPEG 2000 image geometry");
  Image image = NewImage(frame->x1 - frame->x0, frame->y1 - frame->y0);
  for (uint32_t c = 0; c < frame->numcomps; ++c) {
    const auto& component = frame->comps[c];
    if (component.prec > 16 || component.prec < 1 || component.sgnd || component.w != image.width || component.h != image.height) throw std::runtime_error("Unsupported JPEG 2000 component geometry");
  }
  if (!opj_decode(codec.get(), stream.get(), frame.get()) || !opj_end_decompress(codec.get(), stream.get())) throw std::runtime_error("JPEG 2000 decoding failed");
  for (size_t pixel = 0; pixel < image.width * image.height; ++pixel) {
    for (uint32_t c = 0; c < 3; ++c) {
      const auto& component = frame->comps[frame->numcomps == 1 ? 0 : c];
      const int maximum = (1 << component.prec) - 1;
      const int value = std::clamp(component.data[pixel], 0, maximum);
      image.rgba[pixel * 4 + c] = (value * 255 + maximum / 2) / maximum;
    }
    image.rgba[pixel * 4 + 3] = 255;
  }
  return image;
}
}  // namespace

std::vector<uint8_t> Encode(Codec codec, const Image& image, int quality) {
  CheckDimensions(image.width, image.height);
  if (image.rgba.size() != image.width * image.height * 4 || quality < 0 || quality > 100) throw std::runtime_error("Invalid image encoder parameters");
  switch (codec) {
    case kWebP: return EncodeWebP(image, quality);
    case kJpeg: return EncodeJpeg(image, quality);
    case kPng: return EncodePng(image);
    case kAvif: return EncodeAvif(image, quality);
    case kJxl: return EncodeJxl(image, quality);
    case kJp2: return EncodeJp2(image, quality);
    case kHeic: return EncodeHeic(image, quality);
    case kVvc: return EncodeVvc(image, quality);
    default: throw std::runtime_error("Unsupported image encoder");
  }
}

Image Decode(Codec codec, const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > kMaxBytes) throw std::runtime_error("Invalid compressed image size");
  switch (codec) {
    case kWebP: return DecodeWebP(bytes);
    case kJpeg: return DecodeJpeg(bytes);
    case kPng: return DecodePng(bytes);
    case kAvif: return DecodeAvif(bytes);
    case kJxl: return DecodeJxl(bytes);
    case kJp2: return DecodeJp2(bytes);
    case kHeic: return DecodeHeic(bytes);
    case kVvc: return DecodeVvc(bytes);
    default: throw std::runtime_error("Unsupported image decoder");
  }
}
}  // namespace mesh_image
