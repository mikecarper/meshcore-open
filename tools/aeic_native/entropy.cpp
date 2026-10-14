#include "entropy.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace aeic {
namespace {
uint32_t le32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
           (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
uint32_t be32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
}

std::vector<uint8_t> read_file(const std::string& path, size_t limit) {
    FILE* file = std::fopen(path.c_str(), "rb");
    if (!file) throw std::runtime_error("cannot open " + path);
    if (std::fseek(file, 0, SEEK_END) != 0) {
        std::fclose(file); throw std::runtime_error("cannot seek " + path);
    }
    long length = std::ftell(file);
    if (length < 0 || static_cast<size_t>(length) > limit) {
        std::fclose(file); throw std::runtime_error("invalid file size " + path);
    }
    std::rewind(file);
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    size_t got = std::fread(bytes.data(), 1, bytes.size(), file);
    std::fclose(file);
    if (got != bytes.size()) throw std::runtime_error("short read " + path);
    return bytes;
}

void write_file(const std::string& path, const void* data, size_t length) {
    FILE* file = std::fopen(path.c_str(), "wb");
    if (!file) throw std::runtime_error("cannot create " + path);
    size_t wrote = std::fwrite(data, 1, length, file);
    int closed = std::fclose(file);
    if (wrote != length || closed != 0)
        throw std::runtime_error("cannot write " + path);
}

uint64_t hash_bytes(const void* data, size_t length) {
    const uint8_t* bytes = static_cast<const uint8_t*>(data);
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < length; ++i) {
        hash ^= bytes[i]; hash *= UINT64_C(1099511628211);
    }
    return hash;
}
std::string hash_hex(uint64_t value) {
    std::ostringstream text;
    text << std::hex << std::setfill('0') << std::setw(16) << value;
    return text.str();
}

Bitstream read_bitstream(const std::string& path) {
    auto bytes = read_file(path);
    if (bytes.size() < 13) throw std::runtime_error("truncated AEIC header");
    Bitstream result;
    result.height = be32(bytes.data()); result.width = be32(bytes.data() + 4);
    auto supported = [](uint32_t value) { return value >= 128 && value <= 576 && value % 64 == 0; };
    if (!supported(result.height) || !supported(result.width))
        throw std::runtime_error("mobile prototype requires dimensions 128..576 divisible by 64");
    uint32_t length = be32(bytes.data() + 8);
    if (length != bytes.size() - 12) throw std::runtime_error("AEIC payload length mismatch");
    uint8_t flag = bytes[12];
    unsigned parts = (flag >> 4) + 1;
    unsigned width = (flag & 15) == 1 ? 2 : 4;
    if ((flag & 15) > 1 || parts != 2)
        throw std::runtime_error("AEIC requires exactly two framed rANS streams");
    size_t cursor = 13;
    if (cursor + width > bytes.size()) throw std::runtime_error("truncated rANS frame");
    uint32_t first = width == 2 ? uint32_t(bytes[cursor]) | (uint32_t(bytes[cursor + 1]) << 8)
                               : le32(bytes.data() + cursor);
    cursor += width;
    if (first < 4 || first > bytes.size() - cursor || bytes.size() - cursor - first < 4)
        throw std::runtime_error("invalid rANS part lengths");
    result.parts.push_back(std::make_shared<std::vector<uint8_t>>(
        bytes.begin() + cursor, bytes.begin() + cursor + first));
    cursor += first;
    result.parts.push_back(std::make_shared<std::vector<uint8_t>>(bytes.begin() + cursor, bytes.end()));
    return result;
}

Bitstream read_bitstream_recover(const std::string& path, uint32_t height,
                                uint32_t width, std::vector<std::string>& warnings) {
    auto supported = [](uint32_t value) { return value >= 128 && value <= 576 && value % 64 == 0; };
    if (!supported(height) || !supported(width))
        throw std::runtime_error("invalid fallback image dimensions");
    Bitstream result; result.height = height; result.width = width;
    result.parts.resize(2);
    for (auto& part : result.parts) part = std::make_shared<std::vector<uint8_t>>();
    std::vector<uint8_t> bytes;
    try { bytes = read_file(path); }
    catch (const std::exception& error) {
        warnings.push_back(std::string(error.what()) + "; unavailable payload replaced by zero symbols");
        return result;
    }
    if (bytes.size() < 13) {
        warnings.push_back("truncated AEIC header; model dimensions used and unavailable payload replaced by zero symbols");
        return result;
    }
    uint32_t original_h = be32(bytes.data()), original_w = be32(bytes.data() + 4);
    if (original_h != height || original_w != width)
        warnings.push_back("AEIC dimensions disagree with fixed models; model dimensions used");
    if (be32(bytes.data() + 8) != bytes.size() - 12)
        warnings.push_back("AEIC payload length mismatch; using available bytes");
    uint8_t flag = bytes[12];
    if ((flag >> 4) != 1 || (flag & 15) > 1) {
        warnings.push_back("invalid two-stream framing flag; entropy payload unavailable");
        return result;
    }
    size_t length_bytes = (flag & 15) == 1 ? 2 : 4, cursor = 13;
    if (bytes.size() - cursor < length_bytes) {
        warnings.push_back("truncated rANS length field; entropy payload unavailable");
        return result;
    }
    size_t first = length_bytes == 2 ? uint32_t(bytes[cursor]) | (uint32_t(bytes[cursor + 1]) << 8)
                                    : le32(bytes.data() + cursor);
    cursor += length_bytes;
    size_t available = bytes.size() - cursor;
    if (first < 4) {
        warnings.push_back("invalid first rANS length; stream boundaries unavailable");
        return result;
    }
    size_t recovered_first = std::min(first, available);
    result.parts[0]->assign(bytes.begin() + cursor, bytes.begin() + cursor + recovered_first);
    if (first > available) warnings.push_back("first rANS stream truncated; second stream unavailable");
    else result.parts[1]->assign(bytes.begin() + cursor + first, bytes.end());
    if (result.parts[1]->size() < 4) warnings.push_back("second rANS stream truncated or unavailable");
    return result;
}

CdfTable read_cdf(const std::string& path) {
    auto bytes = read_file(path);
    if (bytes.size() < 16 || std::memcmp(bytes.data(), "AEICCDF1", 8))
        throw std::runtime_error("invalid CDF magic " + path);
    uint32_t rows = le32(bytes.data() + 8), columns = le32(bytes.data() + 12);
    if (!rows || rows > 1024 || columns < 3 || columns > 65538)
        throw std::runtime_error("invalid CDF dimensions " + path);
    uint64_t expected = 16 + uint64_t(rows) * 8 + uint64_t(rows) * columns * 4;
    if (expected != bytes.size()) throw std::runtime_error("CDF length mismatch " + path);
    CdfTable result;
    result.lengths = std::make_shared<std::vector<int32_t>>(rows);
    result.offsets = std::make_shared<std::vector<int32_t>>(rows);
    result.cdf = std::make_shared<std::vector<std::vector<int32_t>>>(rows);
    for (uint32_t i = 0; i < rows; ++i) {
        int32_t length = static_cast<int32_t>(le32(bytes.data() + 16 + i * 4));
        if (length < 3 || length > static_cast<int32_t>(columns))
            throw std::runtime_error("invalid CDF row length " + path);
        (*result.lengths)[i] = length;
        (*result.offsets)[i] = static_cast<int32_t>(le32(bytes.data() + 16 + rows * 4 + i * 4));
        auto& row = (*result.cdf)[i]; row.resize(length);
        const uint8_t* raw = bytes.data() + 16 + rows * 8 + size_t(i) * columns * 4;
        for (int j = 0; j < length; ++j) {
            row[j] = static_cast<int32_t>(le32(raw + j * 4));
            if (row[j] < 0 || row[j] > 65536 || (j && row[j] <= row[j - 1]))
                throw std::runtime_error("nonmonotonic CDF " + path);
        }
        if (row.front() != 0 || row.back() != 65536)
            throw std::runtime_error("CDF endpoint mismatch " + path);
    }
    return result;
}

std::vector<float> read_floats(const std::string& path, size_t count) {
    auto bytes = read_file(path);
    if (bytes.size() != count * sizeof(float)) throw std::runtime_error("float count mismatch " + path);
    std::vector<float> result(count);
    for (size_t i = 0; i < count; ++i) {
        uint32_t raw = le32(bytes.data() + i * 4);
        std::memcpy(&result[i], &raw, 4);
        if (!std::isfinite(result[i])) throw std::runtime_error("nonfinite float " + path);
    }
    return result;
}
std::vector<int16_t> read_indexes(const std::string& path, size_t count) {
    auto bytes = read_file(path);
    if (bytes.size() != count * 2) throw std::runtime_error("index count mismatch " + path);
    std::vector<int16_t> result(count);
    for (size_t i = 0; i < count; ++i)
        result[i] = static_cast<int16_t>(uint16_t(bytes[2 * i]) | (uint16_t(bytes[2 * i + 1]) << 8));
    return result;
}

EntropyDecoder::EntropyDecoder(const Bitstream& stream, bool best_effort) : best_effort_(best_effort) {
    if (stream.parts.size() != 2) throw std::runtime_error("AEIC requires two decoders");
    for (auto& part : stream.parts) {
        std::unique_ptr<RansDecoderLib> decoder(new RansDecoderLib);
        bool available = true;
        try { decoder->set_stream(part); }
        catch (const std::exception& error) {
            if (!best_effort_) throw;
            available = false;
            warnings_.push_back("rANS part " + std::to_string(decoders_.size()) + ": " + error.what() + "; zero symbols used");
        }
        available_.push_back(available); decoders_.push_back(std::move(decoder));
    }
    if (decoders_.size() != 2) throw std::runtime_error("AEIC requires two decoders");
}
int EntropyDecoder::add_cdf(const CdfTable& table) {
    int group = -1;
    for (auto& decoder : decoders_) group = decoder->add_cdf(table.cdf, table.lengths, table.offsets);
    return group;
}
std::vector<int16_t> EntropyDecoder::decode(const std::vector<int16_t>& indexes, int group) {
    // Match py_rans.cpp: every call splits its own indexes into two parts.
    size_t split = indexes.size() / 2;
    auto first = std::make_shared<std::vector<int16_t>>(indexes.begin(), indexes.begin() + split);
    auto second = std::make_shared<std::vector<int16_t>>(indexes.begin() + split, indexes.end());
    std::vector<int16_t> result;
    for (size_t part = 0; part < 2; ++part) {
        const auto& input = part ? second : first;
        std::vector<int16_t> values(input->size(), 0);
        if (available_[part]) {
            try { values = decoders_[part]->decode_stream(input, group); }
            catch (const std::exception& error) {
                if (!best_effort_) throw;
                available_[part] = false;
                warnings_.push_back("rANS part " + std::to_string(part) + ": " + error.what() +
                    "; this group and remaining groups replaced by zero symbols");
            }
        }
        result.insert(result.end(), values.begin(), values.end());
    }
    return result;
}
bool EntropyDecoder::fully_complete() const {
    for (size_t i = 0; i < decoders_.size(); ++i)
        if (!available_[i] || decoders_[i]->bytes_remaining() != 0 || decoders_[i]->state() != RANS_BYTE_L) return false;
    return true;
}
std::vector<std::string> EntropyDecoder::take_warnings() {
    std::vector<std::string> result; result.swap(warnings_); return result;
}
void EntropyDecoder::verify_complete() {
    for (size_t i = 0; i < decoders_.size(); ++i) {
        if (!available_[i] || decoders_[i]->bytes_remaining() != 0 || decoders_[i]->state() != RANS_BYTE_L) {
            std::string reason = "entropy completion mismatch in part " + std::to_string(i);
            if (!best_effort_) throw std::runtime_error(reason);
            warnings_.push_back(reason);
        }
    }
}
EntropyEncoder::EntropyEncoder() {
    for (int i = 0; i < 2; ++i)
        encoders_.push_back(std::unique_ptr<RansEncoderLib>(new RansEncoderLib));
}
int EntropyEncoder::add_cdf(const CdfTable& table) {
    int group = -1;
    for (auto& encoder : encoders_) group = encoder->add_cdf(table.cdf, table.lengths, table.offsets);
    return group;
}
void EntropyEncoder::encode(const std::vector<int16_t>& symbols,
                           const std::vector<int16_t>& indexes, int group) {
    if (finished_) throw std::runtime_error("cannot append to a finished bitstream");
    if (symbols.size() != indexes.size()) throw std::runtime_error("encoder symbols/indexes size mismatch");
    size_t split = symbols.size() / 2;
    for (int part = 0; part < 2; ++part) {
        size_t first = part ? split : 0, last = part ? symbols.size() : split;
        auto sym = std::make_shared<std::vector<int16_t>>(symbols.begin() + first, symbols.begin() + last);
        auto idx = std::make_shared<std::vector<int16_t>>(indexes.begin() + first, indexes.begin() + last);
        encoders_[part]->encode_with_indexes(sym, idx, group);
    }
}
std::vector<uint8_t> EntropyEncoder::finish(uint32_t height, uint32_t width) {
    if (finished_) throw std::runtime_error("encoder already finished");
    auto supported = [](uint32_t value) { return value >= 128 && value <= 576 && value % 64 == 0; };
    if (!supported(height) || !supported(width)) throw std::runtime_error("invalid encoded image dimensions");
    finished_ = true;
    std::vector<std::vector<uint8_t>> parts;
    for (auto& encoder : encoders_) { encoder->flush(); parts.push_back(encoder->get_encoded_stream()); }
    unsigned length_bytes = parts[0].size() > 65535 ? 4 : 2;
    uint64_t payload_size = 1 + length_bytes + parts[0].size() + parts[1].size();
    if (payload_size > (64u << 20)) throw std::runtime_error("encoded payload exceeds mobile limit");
    std::vector<uint8_t> output;
    auto big_endian = [&output](uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) output.push_back(static_cast<uint8_t>(value >> shift));
    };
    output.reserve(static_cast<size_t>(payload_size) + 12);
    big_endian(height); big_endian(width); big_endian(static_cast<uint32_t>(payload_size));
    output.push_back(length_bytes == 2 ? 0x11 : 0x10);
    for (unsigned i = 0; i < length_bytes; ++i) output.push_back(static_cast<uint8_t>(parts[0].size() >> (i * 8)));
    for (auto& part : parts) output.insert(output.end(), part.begin(), part.end());
    return output;
}
int16_t scale_index(float scale) {
    if (!std::isfinite(scale)) throw std::runtime_error("nonfinite context scale");
    // PyTorch applies the Python scalar constants as float32 tensor scalars.
    const float minimum = static_cast<float>(std::log(0.11));
    const float step = static_cast<float>((std::log(256.0) - std::log(0.11)) / 63.0);
    scale = std::max(scale, 1e-5f);
    float index = (std::log(scale) - minimum) / step;
    index = std::min(63.f, std::max(0.f, index));
    return scale < 0.08f ? -1 : static_cast<int16_t>(index);
}
int mask_quadrant(int round, int group) {
    static const int quadrants[4][4] = {{0, 1, 2, 3}, {3, 2, 1, 0}, {2, 3, 0, 1}, {1, 0, 3, 2}};
    if (round < 0 || round >= 4 || group < 0 || group >= 4)
        throw std::runtime_error("invalid spatial mask");
    return quadrants[round][group];
}
} // namespace aeic
