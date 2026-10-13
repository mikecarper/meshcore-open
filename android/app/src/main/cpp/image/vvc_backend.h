#pragma once

#include "image_codecs.h"

namespace mesh_image {
std::vector<uint8_t> EncodeVvc(const Image& image, int quality);
Image DecodeVvc(const std::vector<uint8_t>& bytes);
}  // namespace mesh_image
