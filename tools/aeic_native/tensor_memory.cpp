#include "tensor_memory.h"
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>
#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace aeic {
namespace {
constexpr unsigned long long fnv_offset = 14695981039346656037ULL;
unsigned long long hash_part(unsigned long long hash, const void* bytes, size_t count) {
    const auto* data = static_cast<const unsigned char*>(bytes);
    for (size_t i = 0; i < count; ++i) { hash ^= data[i]; hash *= 1099511628211ULL; }
    return hash;
}
void check_chw(const ncnn::Mat& tensor) {
    if (tensor.empty() || tensor.dims != 3 || tensor.elempack != 1 || tensor.elemsize != 4 ||
        tensor.c < 1 || tensor.h < 1 || tensor.w < 1 ||
        static_cast<unsigned long long>(tensor.c) * tensor.h * tensor.w > (64ULL << 20))
        throw std::runtime_error("invalid bounded FP32 spill tensor");
}
#if !defined(_WIN32)
struct Descriptor {
    int fd;
    explicit Descriptor(int value) : fd(value) {
        if (fd < 0) throw std::runtime_error(std::string("scratch file open failed: ") + std::strerror(errno));
    }
    ~Descriptor() { close(fd); }
};
void transfer(int fd, void* data, size_t count, bool writing) {
    auto* bytes = static_cast<unsigned char*>(data);
    while (count) {
        size_t part = std::min(count, size_t(64u << 10));
        ssize_t used = writing ? write(fd, bytes, part) : read(fd, bytes, part);
        if (used < 0 && errno == EINTR) continue;
        if (used <= 0) throw std::runtime_error("scratch tensor I/O failed or truncated");
        count -= size_t(used); bytes += used;
    }
}
void release_file_cache(int fd) {
    // Clean cache pages can otherwise compete with the released anonymous Mat.
    // An advisory failure is harmless: it cannot change tensor bytes.
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
}
#endif
}
TensorSpillStore::TensorSpillStore(const std::string& directory) {
#if !defined(_WIN32)
    struct stat status;
    if (lstat(directory.c_str(), &status) != 0) {
        if (errno != ENOENT || mkdir(directory.c_str(), 0700) != 0)
            throw std::runtime_error("cannot create private spill root " + directory);
        if (lstat(directory.c_str(), &status) != 0) throw std::runtime_error("cannot inspect spill root");
    }
    if (!S_ISDIR(status.st_mode) || status.st_uid != getuid())
        throw std::runtime_error("spill root must be an owned directory, not a symlink");
    std::string pattern = directory + "/aeic-tensors-XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
    char* created = mkdtemp(name.data());
    if (!created) throw std::runtime_error("cannot create private spill directory");
    directory_ = created;
#else
    (void)directory;
    throw std::runtime_error("tensor spilling requires Linux or Android");
#endif
}
TensorSpillStore::~TensorSpillStore() {
#if !defined(_WIN32)
    for (const auto& record : records_) unlink(record.second.path.c_str());
    if (!directory_.empty()) rmdir(directory_.c_str());
#endif
}
bool TensorSpillStore::contains(const std::string& slot) const { return records_.count(slot) != 0; }
void TensorSpillStore::spill(const std::string& slot, const ncnn::Mat& tensor) {
    check_chw(tensor);
    if (contains(slot)) throw std::runtime_error("duplicate spilled slot " + slot);
#if !defined(_WIN32)
    Record record{directory_ + "/tensor-" + std::to_string(sequence_++), tensor.c, tensor.h, tensor.w, fnv_offset};
    Descriptor file(open(record.path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    try {
        size_t plane_bytes = size_t(tensor.h) * tensor.w * sizeof(float);
        for (int c = 0; c < tensor.c; ++c) {
            const void* data = tensor.channel(c);
            transfer(file.fd, const_cast<void*>(data), plane_bytes, true);
            record.hash = hash_part(record.hash, data, plane_bytes);
            // Bound dirty page-cache growth as well as userspace allocations.
            if (fdatasync(file.fd)) throw std::runtime_error("scratch tensor data sync failed");
            release_file_cache(file.fd);
        }
        if (fsync(file.fd)) throw std::runtime_error("scratch tensor sync failed");
        release_file_cache(file.fd);
        records_.emplace(slot, record);
    } catch (...) { unlink(record.path.c_str()); throw; }
#endif
}
ncnn::Mat TensorSpillStore::restore(const std::string& slot) {
    auto found = records_.find(slot);
    if (found == records_.end()) throw std::runtime_error("missing spilled slot " + slot);
    const Record& record = found->second;
    ncnn::Mat result(record.w, record.h, record.c);
    if (result.empty()) throw std::runtime_error("cannot allocate restored spill tensor");
#if !defined(_WIN32)
    Descriptor file(open(record.path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    struct stat status;
    size_t plane_bytes = size_t(record.h) * record.w * sizeof(float);
    if (fstat(file.fd, &status) || !S_ISREG(status.st_mode) || status.st_uid != getuid() ||
        status.st_size != static_cast<off_t>(plane_bytes * record.c))
        throw std::runtime_error("scratch tensor file length or ownership changed");
    unsigned long long hash = fnv_offset;
    for (int c = 0; c < record.c; ++c) {
        void* data = result.channel(c);
        transfer(file.fd, data, plane_bytes, false);
        hash = hash_part(hash, data, plane_bytes);
        release_file_cache(file.fd);
    }
    release_file_cache(file.fd);
    if (hash != record.hash) throw std::runtime_error("scratch tensor bytes changed");
    if (unlink(record.path.c_str())) throw std::runtime_error("cannot remove restored scratch tensor");
    records_.erase(found);
#endif
    return result;
}
void TensorSpillStore::discard_except(const std::set<std::string>& slots) {
    for (auto it = records_.begin(); it != records_.end();) {
        if (slots.count(it->first)) { ++it; continue; }
#if !defined(_WIN32)
        unlink(it->second.path.c_str());
#endif
        it = records_.erase(it);
    }
}
bool add_unique_inplace(ncnn::Mat& target, const ncnn::Mat& other) {
    if (!target.refcount || *target.refcount != 1 || !other.refcount || target.data == other.data ||
        target.dims != 3 || other.dims != 3 || target.elempack != 1 || other.elempack != 1 ||
        target.elemsize != 4 || other.elemsize != 4 || target.w != other.w || target.h != other.h || target.c != other.c)
        return false;
    size_t plane = size_t(target.h) * target.w;
    for (int c = 0; c < target.c; ++c) {
        float* destination = target.channel(c); const float* source = other.channel(c);
        for (size_t i = 0; i < plane; ++i) destination[i] = destination[i] + source[i];
    }
    return true;
}
std::vector<RowTile> convolution_row_tiles(int height, int scale, int rows) {
    if (height < 1 || height > 1024 || (scale != 1 && scale != 2) || rows < 2 || rows > 1024 || rows % scale)
        throw std::runtime_error("invalid convolution row tile dimensions");
    std::vector<RowTile> result;
    int output_height = height * scale;
    for (int first = 0; first < output_height; first += rows) {
        int end = std::min(output_height, first + rows);
        int halo = scale == 1 ? 2 : 1;
        int input_first = std::max(0, first / scale - halo);
        int input_end = std::min(height, (end + scale - 1) / scale + halo);
        result.push_back({input_first, input_end, first, end, first - input_first * scale});
    }
    return result;
}
}
