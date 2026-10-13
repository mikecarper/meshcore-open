#include "vvc_backend.h"

#include <algorithm>
#include <cmath>
#include <iostream>

using mesh_image::Image;

Image Fixture(uint32_t width, uint32_t height) {
  Image result;
  result.width = width;
  result.height = height;
  result.rgba.resize(width * height * 4);
  for (uint32_t y = 0; y < height; ++y) {
    for (uint32_t x = 0; x < width; ++x) {
      const size_t pixel = (y * width + x) * 4;
      result.rgba[pixel] = 20 + x * 210 / width;
      result.rgba[pixel + 1] = 30 + y * 200 / height;
      result.rgba[pixel + 2] = x > width / 2 ? 180 : 50;
      result.rgba[pixel + 3] = 255;
    }
  }
  return result;
}

int main() {
  try {
    for (const auto& geometry : {std::pair<uint32_t, uint32_t>{16, 16}, {32, 64}, {128, 96}, {512, 512}}) {
      const Image original = Fixture(geometry.first, geometry.second);
      const auto encoded = mesh_image::EncodeVvc(original, 75);
      const Image decoded = mesh_image::DecodeVvc(encoded);
      if (decoded.width != original.width || decoded.height != original.height ||
          decoded.rgba.size() != original.rgba.size()) {
        throw std::runtime_error("VVC dimensions did not round-trip");
      }
      double squared = 0;
      for (size_t pixel = 0; pixel < decoded.rgba.size(); pixel += 4) {
        for (size_t component = 0; component < 3; ++component) {
          const int error = static_cast<int>(decoded.rgba[pixel + component]) - original.rgba[pixel + component];
          squared += error * error;
        }
        if (decoded.rgba[pixel + 3] != 255) throw std::runtime_error("VVC alpha output is not opaque");
      }
      const double rmse = std::sqrt(squared / (original.width * original.height * 3));
      if (rmse > 25) throw std::runtime_error("VVC decoded colors exceed the smoke-test error bound");
      std::cout << "VVC round trip " << decoded.width << "x" << decoded.height
                << ": " << encoded.size() << " bytes, RGB RMSE " << rmse << "\n";
    }
    for (const auto& bad : {std::vector<uint8_t>{}, {1, 2, 3}, {0, 0, 1}, {0, 0, 1, 0, 0}}) {
      bool rejected = false;
      try { mesh_image::DecodeVvc(bad); }
      catch (const std::exception&) { rejected = true; }
      if (!rejected) throw std::runtime_error("VVC malformed input was accepted");
    }
    auto transparent = Fixture(32, 32);
    for (size_t pixel = 3; pixel < transparent.rgba.size(); pixel += 4) transparent.rgba[pixel] = 0;
    const auto opaque = mesh_image::DecodeVvc(mesh_image::EncodeVvc(transparent, 75));
    if (std::any_of(opaque.rgba.begin(), opaque.rgba.end(), [](uint8_t value) { return value < 245; })) {
      throw std::runtime_error("VVC transparent pixels were not composited onto white");
    }
    auto duplicate = mesh_image::EncodeVvc(Fixture(32, 32), 75);
    const auto second = duplicate;
    duplicate.insert(duplicate.end(), second.begin(), second.end());
    bool rejected_video = false;
    try { mesh_image::DecodeVvc(duplicate); }
    catch (const std::exception&) { rejected_video = true; }
    if (!rejected_video) throw std::runtime_error("VVC accepted multiple images in one payload");
    std::cout << "VVC malformed-input checks passed\n";
  } catch (const std::exception& error) {
    std::cerr << "VVC smoke test failed: " << error.what() << "\n";
    return 1;
  }
  return 0;
}
