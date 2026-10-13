#include "vvc_backend.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <utility>

#include <vvenc/vvenc.h>
#include <vvdec/vvdec.h>

namespace mesh_image {
namespace {
int ClampByte(int value) { return std::max(0, std::min(255, value)); }

int WhiteComposite(const Image& image, uint32_t x, uint32_t y, int channel) {
  const size_t index = (static_cast<size_t>(y) * image.width + x) * 4;
  const int alpha = image.rgba[index + 3];
  return (image.rgba[index + channel] * alpha + 255 * (255 - alpha) + 127) / 255;
}

struct Encoder {
  vvencEncoder* value = vvenc_encoder_create();
  ~Encoder() { if (value) vvenc_encoder_close(value); }
};
struct Decoder {
  explicit Decoder(vvdecParams* params) : value(vvdec_decoder_open(params)) {}
  vvdecDecoder* value;
  ~Decoder() { if (value) vvdec_decoder_close(value); }
};

// Annex B units are bounded so a malformed input cannot create an unbounded
// collection or force decoding an arbitrarily long video in an image worker.
std::vector<std::pair<size_t, size_t>> NalUnits(const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > kMaxBytes) {
    throw std::runtime_error("Invalid VVC payload size");
  }
  std::vector<std::pair<size_t, size_t>> units;
  size_t start = 0;
  size_t header = 0;
  bool found = false;
  for (size_t i = 0; i + 2 < bytes.size(); ++i) {
    if (bytes[i] || bytes[i + 1]) continue;
    size_t prefix = 0;
    if (bytes[i + 2] == 1) prefix = 3;
    else if (i + 3 < bytes.size() && bytes[i + 2] == 0 && bytes[i + 3] == 1) prefix = 4;
    if (!prefix) continue;
    if (!found && i != 0) throw std::runtime_error("Invalid VVC start code");
    if (found) {
      if (i - header < 2) throw std::runtime_error("Truncated VVC NAL unit");
      units.emplace_back(start, i);
    }
    start = i;
    header = i + prefix;
    found = true;
    i += prefix - 1;
    if (units.size() >= 64) throw std::runtime_error("Too many VVC NAL units");
  }
  if (!found || bytes.size() - header < 2) throw std::runtime_error("Truncated VVC payload");
  units.emplace_back(start, bytes.size());
  return units;
}

std::vector<uint8_t> StripNonImageUnits(const std::vector<uint8_t>& bytes) {
  std::vector<uint8_t> result;
  for (const auto& unit : NalUnits(bytes)) {
    const size_t prefix = bytes[unit.first + 2] == 1 ? 3 : 4;
    const uint8_t type = (bytes[unit.first + prefix + 1] >> 3) & 31;
    // SEI, filler, delimiters, and unspecified units are not image pixels or
    // necessary picture/parameter headers. No source metadata is copied.
    if (type == 20 || type >= 23) continue;
    result.insert(result.end(), bytes.begin() + unit.first, bytes.begin() + unit.second);
  }
  if (result.empty()) throw std::runtime_error("VVC encoder produced no image");
  return result;
}

Image CopyFrame(const vvdecFrame& frame) {
  CheckDimensions(frame.width, frame.height);
  if (frame.numPlanes != 3 || frame.colorFormat != VVDEC_CF_YUV420_PLANAR ||
      frame.bitDepth != 10 || (frame.width & 1) || (frame.height & 1)) {
    throw std::runtime_error("Unsupported VVC still-image pixel format");
  }
  for (uint32_t plane = 0; plane < 3; ++plane) {
    const auto& component = frame.planes[plane];
    const uint32_t width = plane ? frame.width / 2 : frame.width;
    const uint32_t height = plane ? frame.height / 2 : frame.height;
    if (!component.ptr || component.bytesPerSample != 2 ||
        component.width != width || component.height != height ||
        component.stride < width * 2 || component.stride > (kMaxDimension + 512) * 2) {
      throw std::runtime_error("Invalid VVC decoded plane geometry");
    }
  }
  auto sample = [&frame](uint32_t plane, uint32_t x, uint32_t y) {
    uint16_t value = 0;
    std::memcpy(&value, frame.planes[plane].ptr + y * frame.planes[plane].stride + x * 2, 2);
    return (static_cast<int>(value) + 2) >> 2;
  };
  Image image;
  image.width = frame.width;
  image.height = frame.height;
  image.rgba.resize(static_cast<size_t>(image.width) * image.height * 4);
  for (uint32_t y = 0; y < image.height; ++y) {
    for (uint32_t x = 0; x < image.width; ++x) {
      const int luma = sample(0, x, y) - 16;
      const int u = sample(1, x / 2, y / 2) - 128;
      const int v = sample(2, x / 2, y / 2) - 128;
      const size_t index = (static_cast<size_t>(y) * image.width + x) * 4;
      image.rgba[index] = ClampByte((298 * luma + 409 * v + 128) >> 8);
      image.rgba[index + 1] = ClampByte((298 * luma - 100 * u - 208 * v + 128) >> 8);
      image.rgba[index + 2] = ClampByte((298 * luma + 516 * u + 128) >> 8);
      image.rgba[index + 3] = 255;
    }
  }
  return image;
}
}  // namespace

std::vector<uint8_t> EncodeVvc(const Image& image, int quality) {
  CheckDimensions(image.width, image.height);
  if (image.width < 16 || image.height < 16 || (image.width & 1) || (image.height & 1) ||
      image.rgba.size() != static_cast<size_t>(image.width) * image.height * 4) {
    throw std::runtime_error("VVC needs an even-sized image of at least 16 x 16");
  }
  vvenc_config config;
  const int boundedQuality = std::max(0, std::min(100, quality));
  const int qp = 63 - boundedQuality * 63 / 100;
  if (vvenc_init_default(&config, image.width, image.height, 1, VVENC_RC_OFF, qp, VVENC_FASTER)) {
    throw std::runtime_error("VVC encoder configuration failed");
  }
  config.m_framesToBeEncoded = 1;
  config.m_IntraPeriod = 1;
  config.m_GOPSize = 1;
  config.m_numThreads = 1;
  config.m_profile = VVENC_MAIN_10_STILL_PICTURE;
  config.m_verbosity = VVENC_SILENT;
  config.m_internChromaFormat = VVENC_CHROMA_420;
  config.m_AccessUnitDelimiter = 0;
  config.m_decodedPictureHashSEIType = VVENC_HASHTYPE_NONE;
  config.m_bufferingPeriodSEIEnabled = false;
  config.m_pictureTimingSEIEnabled = false;
  config.m_decodingUnitInfoSEIEnabled = false;
  for (int channel = 0; channel < 2; ++channel) {
    config.m_inputBitDepth[channel] = 10;
    config.m_MSBExtendedBitDepth[channel] = 10;
    config.m_internalBitDepth[channel] = 10;
  }
  Encoder encoder;
  if (!encoder.value || vvenc_encoder_open(encoder.value, &config) ||
      vvenc_init_pass(encoder.value, 0, "")) {
    throw std::runtime_error("VVC still-image encoder could not start");
  }
  std::vector<int16_t> luma(image.width * image.height);
  std::vector<int16_t> u(image.width * image.height / 4);
  std::vector<int16_t> v(u.size());
  for (uint32_t y = 0; y < image.height; ++y) {
    for (uint32_t x = 0; x < image.width; ++x) {
      const int r = WhiteComposite(image, x, y, 0);
      const int g = WhiteComposite(image, x, y, 1);
      const int b = WhiteComposite(image, x, y, 2);
      luma[y * image.width + x] = ClampByte(16 + ((66 * r + 129 * g + 25 * b + 128) >> 8)) * 4;
      if (!(x & 1) && !(y & 1)) {
        int rgb[3] = {0, 0, 0};
        for (uint32_t dy = 0; dy < 2; ++dy) {
          for (uint32_t dx = 0; dx < 2; ++dx) {
            for (int channel = 0; channel < 3; ++channel) {
              rgb[channel] += WhiteComposite(image, x + dx, y + dy, channel);
            }
          }
        }
        for (int& value : rgb) value = (value + 2) / 4;
        const size_t index = (y / 2) * (image.width / 2) + x / 2;
        u[index] = ClampByte(128 + ((-38 * rgb[0] - 74 * rgb[1] + 112 * rgb[2] + 128) >> 8)) * 4;
        v[index] = ClampByte(128 + ((112 * rgb[0] - 94 * rgb[1] - 18 * rgb[2] + 128) >> 8)) * 4;
      }
    }
  }
  vvencYUVBuffer input;
  vvenc_YUVBuffer_default(&input);
  input.planes[0] = {luma.data(), static_cast<int>(image.width), static_cast<int>(image.height), static_cast<int>(image.width)};
  input.planes[1] = {u.data(), static_cast<int>(image.width / 2), static_cast<int>(image.height / 2), static_cast<int>(image.width / 2)};
  input.planes[2] = {v.data(), static_cast<int>(image.width / 2), static_cast<int>(image.height / 2), static_cast<int>(image.width / 2)};
  std::vector<uint8_t> buffer(kMaxBytes);
  vvencAccessUnit access;
  vvenc_accessUnit_default(&access);
  access.payload = buffer.data();
  access.payloadSize = buffer.size();
  std::vector<uint8_t> output;
  bool done = false;
  for (int step = 0; !done && step < 16; ++step) {
    access.payloadUsedSize = 0;
    if (vvenc_encode(encoder.value, step == 0 ? &input : nullptr, &access, &done)) {
      throw std::runtime_error("VVC still-image encode failed");
    }
    if (access.payloadUsedSize < 0 || static_cast<size_t>(access.payloadUsedSize) > buffer.size() ||
        output.size() + access.payloadUsedSize > kMaxBytes) {
      throw std::runtime_error("VVC encoded payload is too large");
    }
    output.insert(output.end(), buffer.begin(), buffer.begin() + access.payloadUsedSize);
  }
  if (!done) throw std::runtime_error("VVC still-image encoder did not finish");
  return StripNonImageUnits(output);
}

Image DecodeVvc(const std::vector<uint8_t>& bytes) {
  const auto units = NalUnits(bytes);
  vvdecParams params;
  vvdec_params_default(&params);
  params.threads = 1;
  params.parseDelay = 0;
  params.logLevel = VVDEC_SILENT;
  params.filmGrainSynthesis = false;
  params.verifyPictureHash = false;
  params.simd = VVDEC_SIMD_SCALAR;
  params.errHandlingFlags = VVDEC_ERR_HANDLING_OFF;
  Decoder decoder(&params);
  if (!decoder.value) throw std::runtime_error("VVC decoder could not start");
  Image image;
  auto takeFrame = [&](vvdecFrame* frame) {
    if (!frame) return;
    try {
      if (!image.rgba.empty()) throw std::runtime_error("VVC image contains multiple pictures");
      image = CopyFrame(*frame);
    } catch (...) {
      vvdec_frame_unref(decoder.value, frame);
      throw;
    }
    vvdec_frame_unref(decoder.value, frame);
  };
  for (const auto& unit : units) {
    vvdecAccessUnit access;
    vvdec_accessUnit_default(&access);
    access.payload = const_cast<uint8_t*>(bytes.data() + unit.first);
    access.payloadSize = unit.second - unit.first;
    access.payloadUsedSize = access.payloadSize;
    vvdecFrame* frame = nullptr;
    const int status = vvdec_decode(decoder.value, &access, &frame);
    if (status != VVDEC_OK && status != VVDEC_TRY_AGAIN && status != VVDEC_EOF) {
      if (frame) vvdec_frame_unref(decoder.value, frame);
      throw std::runtime_error("VVC still-image bitstream is invalid");
    }
    takeFrame(frame);
  }
  for (int step = 0; step < 16; ++step) {
    vvdecFrame* frame = nullptr;
    const int status = vvdec_flush(decoder.value, &frame);
    if (status != VVDEC_OK && status != VVDEC_TRY_AGAIN && status != VVDEC_EOF) {
      if (frame) vvdec_frame_unref(decoder.value, frame);
      throw std::runtime_error("VVC still-image decoder could not finish");
    }
    takeFrame(frame);
    if (status == VVDEC_EOF) break;
    if (step == 15) throw std::runtime_error("VVC still-image decoder did not finish");
  }
  if (image.rgba.empty()) throw std::runtime_error("VVC image has no decoded picture");
  return image;
}
}  // namespace mesh_image
