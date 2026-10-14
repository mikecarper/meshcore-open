#pragma once
#include "rans/rans.h"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace aeic {

std::vector<uint8_t> read_file(const std::string& path, size_t limit = 64u << 20);
void write_file(const std::string& path, const void* data, size_t length);
uint64_t hash_bytes(const void* data, size_t length);
std::string hash_hex(uint64_t value);

struct Bitstream {
    uint32_t height = 0, width = 0;
    std::vector<std::shared_ptr<std::vector<uint8_t>>> parts;
};
Bitstream read_bitstream(const std::string& path);
Bitstream read_bitstream_recover(const std::string& path, uint32_t height,
                                uint32_t width, std::vector<std::string>& warnings);

struct CdfTable {
    std::shared_ptr<std::vector<std::vector<int32_t>>> cdf;
    std::shared_ptr<std::vector<int32_t>> lengths, offsets;
};
CdfTable read_cdf(const std::string& path);
std::vector<float> read_floats(const std::string& path, size_t count);
std::vector<int16_t> read_indexes(const std::string& path, size_t count);

class EntropyDecoder {
public:
    explicit EntropyDecoder(const Bitstream& stream, bool best_effort = false);
    int add_cdf(const CdfTable& table);
    std::vector<int16_t> decode(const std::vector<int16_t>& indexes, int group);
    void verify_complete();
    std::vector<std::string> take_warnings();
    bool fully_complete() const;
private:
    std::vector<std::unique_ptr<RansDecoderLib>> decoders_;
    std::vector<bool> available_;
    std::vector<std::string> warnings_;
    bool best_effort_ = false;
};

class EntropyEncoder {
public:
    EntropyEncoder();
    int add_cdf(const CdfTable& table);
    void encode(const std::vector<int16_t>& symbols,
                const std::vector<int16_t>& indexes, int group);
    std::vector<uint8_t> finish(uint32_t height, uint32_t width);
private:
    std::vector<std::unique_ptr<RansEncoderLib>> encoders_;
    bool finished_ = false;
};

// Equivalent to PixelCodec.my_build_indexes for one unmasked scale.
int16_t scale_index(float scale);
// Spatial quadrant for channel group 0..3 in decoding round 0..3.
int mask_quadrant(int round, int group);

} // namespace aeic
