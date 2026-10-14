#include "entropy.h"
#include <algorithm>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace {
void expect(bool value, const char* description) {
    if (!value) throw std::runtime_error(description);
}
void append32(std::vector<uint8_t>& bytes, uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) bytes.push_back(static_cast<uint8_t>(value >> shift));
}
void appendbe32(std::vector<uint8_t>& bytes, uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8) bytes.push_back(static_cast<uint8_t>(value >> shift));
}
}
int main() {
    const std::string temporary = "aeic_entropy_test.tmp";
    try {
        expect(aeic::hash_hex(aeic::hash_bytes("hello", 5)) == "a430d84680aabd0b", "FNV-1a hash");
        expect(aeic::scale_index(-1.f) == -1 && aeic::scale_index(.079f) == -1, "scale skip threshold");
        expect(aeic::scale_index(.08f) == 0 && aeic::scale_index(256.f) == 63, "scale endpoints");
        for (int r = 0; r < 4; ++r) {
            int bits = 0; for (int g = 0; g < 4; ++g) bits |= 1 << aeic::mask_quadrant(r, g);
            expect(bits == 15, "spatial masks are permutations");
        }
        aeic::CdfTable table;
        table.cdf = std::make_shared<std::vector<std::vector<int32_t>>>(3);
        table.lengths = std::make_shared<std::vector<int32_t>>(3, 7);
        table.offsets = std::make_shared<std::vector<int32_t>>(3, -2);
        for (auto& row : *table.cdf) row = {0, 1000, 20000, 30000, 40000, 50000, 65536};
        std::vector<uint8_t> raw{'A','E','I','C','C','D','F','1'};
        append32(raw, 3); append32(raw, 7);
        for (auto value : *table.lengths) append32(raw, value);
        for (auto value : *table.offsets) append32(raw, value);
        for (auto& row : *table.cdf) for (auto value : row) append32(raw, value);
        aeic::write_file(temporary, raw.data(), raw.size());
        auto loaded = aeic::read_cdf(temporary);
        expect(*loaded.cdf == *table.cdf && *loaded.offsets == *table.offsets, "CDF binary roundtrip");
        std::vector<std::unique_ptr<RansEncoderLib>> encoders;
        for (int i = 0; i < 2; ++i) {
            std::unique_ptr<RansEncoderLib> encoder(new RansEncoderLib);
            encoder->add_cdf(table.cdf, table.lengths, table.offsets); encoders.push_back(std::move(encoder));
        }
        std::vector<std::vector<int16_t>> rounds, round_indexes;
        // Odd counts verify that each call splits independently as py_rans does.
        for (int round = 0; round < 5; ++round) {
            size_t count = 1025 + round * 2;
            std::vector<int16_t> indexes(count), symbols(count);
            for (size_t i = 0; i < count; ++i) {
                indexes[i] = i % 11 ? static_cast<int16_t>(i % 3) : -1;
                symbols[i] = indexes[i] < 0 ? 0 : static_cast<int16_t>((int(i) * 31 + round * 7) % 601 - 300);
            }
            size_t split = count / 2;
            for (int part = 0; part < 2; ++part) {
                size_t first = part ? split : 0, last = part ? count : split;
                auto idx = std::make_shared<std::vector<int16_t>>(indexes.begin() + first, indexes.begin() + last);
                auto sym = std::make_shared<std::vector<int16_t>>(symbols.begin() + first, symbols.begin() + last);
                encoders[part]->encode_with_indexes(sym, idx, 0);
            }
            rounds.push_back(symbols); round_indexes.push_back(indexes);
        }
        aeic::Bitstream stream; stream.height = 256; stream.width = 256;
        for (auto& encoder : encoders) {
            encoder->flush(); stream.parts.push_back(std::make_shared<std::vector<uint8_t>>(encoder->get_encoded_stream()));
        }
        std::vector<uint8_t> framed;
        appendbe32(framed, 256); appendbe32(framed, 256);
        appendbe32(framed, static_cast<uint32_t>(3 + stream.parts[0]->size() + stream.parts[1]->size()));
        framed.push_back(0x11); framed.push_back(static_cast<uint8_t>(stream.parts[0]->size()));
        framed.push_back(static_cast<uint8_t>(stream.parts[0]->size() >> 8));
        for (auto& part : stream.parts) framed.insert(framed.end(), part->begin(), part->end());
        aeic::EntropyEncoder native_encoder;
        int native_group = native_encoder.add_cdf(loaded);
        for (size_t round = 0; round < rounds.size(); ++round)
            native_encoder.encode(rounds[round], round_indexes[round], native_group);
        expect(native_encoder.finish(256, 256) == framed, "native encoder matches original framed bytes exactly");
        aeic::write_file(temporary, framed.data(), framed.size());
        auto parsed = aeic::read_bitstream(temporary);
        expect(parsed.height == 256 && parsed.width == 256 && *parsed.parts[0] == *stream.parts[0], "bitstream framing roundtrip");
        aeic::EntropyDecoder decoder(parsed); int group = decoder.add_cdf(loaded);
        for (size_t round = 0; round < rounds.size(); ++round)
            expect(decoder.decode(round_indexes[round], group) == rounds[round], "two-stream multi-round entropy symbols");
        decoder.verify_complete();
        // Truncated streams must fail with an exception rather than overread.
        bool rejected = false;
        auto truncated = stream;
        truncated.parts[0] = std::make_shared<std::vector<uint8_t>>(stream.parts[0]->begin(), stream.parts[0]->begin() + 4);
        try {
            aeic::EntropyDecoder bad(truncated); int bad_group = bad.add_cdf(table);
            for (auto& indexes : round_indexes) bad.decode(indexes, bad_group);
        } catch (const std::runtime_error&) { rejected = true; }
        expect(rejected, "truncated rANS stream is rejected");
        // Recovery preserves the healthy half and never reads past damaged data.
        aeic::EntropyDecoder recovered(truncated, true);
        int recovered_group = recovered.add_cdf(table);
        for (size_t round = 0; round < rounds.size(); ++round) {
            auto values = recovered.decode(round_indexes[round], recovered_group);
            size_t half = values.size() / 2;
            expect(std::equal(values.begin() + half, values.end(), rounds[round].begin() + half), "healthy entropy part remains exact");
            expect(std::all_of(values.begin(), values.begin() + half, [](int16_t v) { return v == 0; }), "unavailable entropy part uses zero symbols");
        }
        recovered.verify_complete();
        expect(!recovered.fully_complete() && !recovered.take_warnings().empty(), "recovered entropy is explicitly incomplete");
        std::vector<std::string> warnings;
        auto intact_best = aeic::read_bitstream_recover(temporary, 256, 256, warnings);
        expect(warnings.empty() && *intact_best.parts[0] == *parsed.parts[0] && *intact_best.parts[1] == *parsed.parts[1], "intact framing recovery changes nothing");
        auto short_frame = framed; short_frame.resize(short_frame.size() - 4);
        aeic::write_file(temporary, short_frame.data(), short_frame.size());
        auto short_best = aeic::read_bitstream_recover(temporary, 256, 256, warnings);
        expect(!warnings.empty() && *short_best.parts[0] == *parsed.parts[0] && short_best.parts[1]->size() + 4 == parsed.parts[1]->size(), "truncated outer payload salvages known stream boundaries and warns");
        warnings.clear();
        auto header_only = std::vector<uint8_t>(8, 0);
        aeic::write_file(temporary, header_only.data(), header_only.size());
        auto empty_best = aeic::read_bitstream_recover(temporary, 512, 512, warnings);
        expect(empty_best.height == 512 && empty_best.width == 512 && empty_best.parts[0]->empty() && !warnings.empty(), "missing header uses bounded model dimensions");
        aeic::EntropyDecoder empty_decoder(empty_best, true);
        int empty_group = empty_decoder.add_cdf(table);
        auto empty_values = empty_decoder.decode(round_indexes[0], empty_group);
        expect(std::all_of(empty_values.begin(), empty_values.end(), [](int16_t v) { return v == 0; }), "missing streams yield zeros");
        expect(!empty_decoder.fully_complete() && !empty_decoder.take_warnings().empty(), "missing streams never report entropy completion");
        // Mutations exercise bypass counts and state normalization under sanitizers.
        uint32_t mutation_state = 271;
        size_t noticed = 0;
        for (int attempt = 0; attempt < 512; ++attempt) {
            auto mutation = parsed;
            size_t part = size_t(attempt & 1);
            mutation.parts[part] = std::make_shared<std::vector<uint8_t>>(*parsed.parts[part]);
            mutation_state = mutation_state * 1664525u + 1013904223u;
            size_t position = mutation_state % mutation.parts[part]->size();
            (*mutation.parts[part])[position] ^= uint8_t(1u << (attempt % 8));
            aeic::EntropyDecoder damaged(mutation, true);
            int damaged_group = damaged.add_cdf(table);
            for (size_t round = 0; round < rounds.size(); ++round)
                expect(damaged.decode(round_indexes[round], damaged_group).size() == rounds[round].size(), "recovered mutation preserves symbol counts");
            damaged.verify_complete();
            if (!damaged.take_warnings().empty()) ++noticed;
        }
        expect(noticed > 0, "mutated streams produce recovery diagnostics");
        // Repeated two-bit continuation values must be rejected before any
        // uint32 shift by32. Mutation tests may miss this exact stream state.
        auto overflow_cdf = std::make_shared<std::vector<std::vector<int32_t>>>(1, std::vector<int32_t>{0,65535,65536});
        auto overflow_lengths = std::make_shared<std::vector<int32_t>>(1, 3);
        auto overflow_offsets = std::make_shared<std::vector<int32_t>>(1, 0);
        auto overflow_stream = std::make_shared<std::vector<uint8_t>>(32, 255);
        RansDecoderLib overflow_decoder;
        overflow_decoder.set_stream(overflow_stream);
        int overflow_group = overflow_decoder.add_cdf(overflow_cdf, overflow_lengths, overflow_offsets);
        bool overflow_rejected = false;
        try { overflow_decoder.decode_stream(std::make_shared<std::vector<int16_t>>(1, 0), overflow_group); }
        catch (const std::runtime_error& error) { overflow_rejected = std::string(error.what()).find("bypass integer overflow") != std::string::npos; }
        expect(overflow_rejected, "oversized bypass continuation cannot reach undefined shifts");
        framed[12] = 0x21;
        aeic::write_file(temporary, framed.data(), framed.size());
        rejected = false;
        try { aeic::read_bitstream(temporary); } catch (const std::runtime_error&) { rejected = true; }
        expect(rejected, "unsupported stream count rejected");
        aeic::EntropyEncoder skip_encoder;
        int skip_group = skip_encoder.add_cdf(table);
        std::vector<int16_t> all_skip(8, -1), all_zero(8, 0);
        skip_encoder.encode(all_zero, all_skip, skip_group);
        auto skipped = skip_encoder.finish(256, 256);
        aeic::write_file(temporary, skipped.data(), skipped.size());
        auto skip_stream = aeic::read_bitstream(temporary);
        aeic::EntropyDecoder skip_decoder(skip_stream);
        int skip_decode_group = skip_decoder.add_cdf(table);
        expect(skip_decoder.decode(all_skip, skip_decode_group) == all_zero, "all-skipped stream encodes safely");
        skip_decoder.verify_complete();
        // High-entropy data exercises four-byte part lengths and full int16 bypass values.
        std::vector<int16_t> wide_symbols(75001), wide_indexes(wide_symbols.size(), 0);
        uint32_t random_state = 1;
        for (auto& value : wide_symbols) {
            random_state = random_state * 1664525u + 1013904223u;
            value = static_cast<int16_t>(random_state >> 16);
        }
        aeic::EntropyEncoder wide_encoder; int wide_group = wide_encoder.add_cdf(table);
        wide_encoder.encode(wide_symbols, wide_indexes, wide_group);
        auto wide_bytes = wide_encoder.finish(512, 512);
        expect(wide_bytes[12] == 0x10, "large stream uses four-byte part lengths");
        aeic::write_file(temporary, wide_bytes.data(), wide_bytes.size());
        auto wide_stream = aeic::read_bitstream(temporary);
        aeic::EntropyDecoder wide_decoder(wide_stream); int wide_decode_group = wide_decoder.add_cdf(table);
        expect(wide_decoder.decode(wide_indexes, wide_decode_group) == wide_symbols, "full int16 symbols and four-byte frames roundtrip");
        wide_decoder.verify_complete();
        std::remove(temporary.c_str());
        std::printf("PASS: exact two-stream encoder/decoder, framing, int16 bypass, skipped indexes, terminal checks, bounded damaged-stream salvage and512 mutations\n");
        return 0;
    } catch (const std::exception& error) {
        std::remove(temporary.c_str());
        std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1;
    }
}
