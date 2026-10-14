#pragma once

namespace ncnn { class Net; }

namespace aeic {
// Registers an FP32 self-attention layer that accepts the existing ncnn MHA
// parameters and weight file, but bounds score storage by query-row tiles.
int register_tiled_attention(ncnn::Net& net);
}
