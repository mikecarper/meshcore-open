#pragma once
#include <cstdint>
#include <fstream>
#include <limits>
#include <string>
#include <utility>

namespace aeic {
// Kotlin atomically replaces this private job file before SIGCONT. Read at most
// 33 bytes, reject overflow/decreases, and retain the last valid value if an
// atomic replacement is briefly unavailable. No counter file is modified here.
class PauseCounter {
public:
    explicit PauseCounter(std::string path) : path_(std::move(path)) {}
    uint64_t operator()() {
        std::ifstream file(path_, std::ios::binary);
        if (!file) return latest_;
        char bytes[33]; file.read(bytes, sizeof(bytes));
        const auto count = file.gcount();
        if (file.bad() || count < 1 || count > 32) return latest_;
        size_t first = 0, end = size_t(count);
        auto space = [](char ch) { return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'; };
        while (first < end && space(bytes[first])) ++first;
        while (end > first && space(bytes[end - 1])) --end;
        if (first == end) return latest_;
        uint64_t value = 0;
        for (size_t i = first; i < end; ++i) {
            if (bytes[i] < '0' || bytes[i] > '9') return latest_;
            unsigned digit = unsigned(bytes[i] - '0');
            if (value > (std::numeric_limits<uint64_t>::max() - digit) / 10) return latest_;
            value = value * 10 + digit;
        }
        if (value >= latest_) latest_ = value;
        return latest_;
    }
private:
    std::string path_;
    uint64_t latest_ = 0;
};
}
