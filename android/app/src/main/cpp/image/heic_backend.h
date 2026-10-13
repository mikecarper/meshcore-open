#pragma once
#include "image_codecs.h"

namespace mesh_image {
std::vector<uint8_t> EncodeHeic(const Image& image, int quality);
Image DecodeHeic(const std::vector<uint8_t>& bytes);
}
