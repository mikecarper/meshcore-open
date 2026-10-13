#include "image_codecs.h"
#if defined(MESH_IMAGE_BPG_ONLY)
#include "bpg_backend.h"
#endif

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <sys/resource.h>
#include <unistd.h>

namespace {
bool ReadAll(int fd, void* output, size_t size) {
  auto* bytes = static_cast<uint8_t*>(output);
  while (size) {
    const ssize_t count = read(fd, bytes, size);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return false;
    bytes += count;
    size -= static_cast<size_t>(count);
  }
  return true;
}
bool WriteAll(int fd, const void* input, size_t size) {
  const auto* bytes = static_cast<const uint8_t*>(input);
  while (size) {
    const ssize_t count = write(fd, bytes, size);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return false;
    bytes += count;
    size -= static_cast<size_t>(count);
  }
  return true;
}
void Send(const mesh_image::ResponseHeader& header, const std::vector<uint8_t>& output) {
  if (!WriteAll(STDOUT_FILENO, &header, sizeof(header))) return;
  WriteAll(STDOUT_FILENO, output.data(), output.size());
}
}  // namespace

int main() {
  // The worker is exec'd into a new address space, with no Android VM or app
  // locks. Scalar codecs use one thread. Limit address space and core dumps.
  rlimit memory{192 * 1024 * 1024, 192 * 1024 * 1024};
  rlimit core{0, 0};
  setrlimit(RLIMIT_AS, &memory);
  setrlimit(RLIMIT_CORE, &core);
  alarm(121);  // Parent enforces the exact, normally shorter, wall-clock budget.
  signal(SIGPIPE, SIG_IGN);
  mesh_image::ResponseHeader response{mesh_image::kMagic, 1, 0, 0, 0};
  try {
    mesh_image::RequestHeader header{};
    if (!ReadAll(STDIN_FILENO, &header, sizeof(header)) ||
        header.magic != mesh_image::kMagic || header.length > mesh_image::kMaxBytes ||
        header.quality > 100 || header.codec < mesh_image::kWebP ||
        header.codec > mesh_image::kBpg || header.operation > 1) {
      throw std::runtime_error("Invalid image worker request");
    }
    if (!header.length) throw std::runtime_error("Empty image input");
#if defined(MESH_IMAGE_BPG_ONLY)
    if (header.codec != mesh_image::kBpg) throw std::runtime_error("The BPG worker only supports BPG");
#endif
    if (header.operation == 0) {
      mesh_image::CheckDimensions(header.width, header.height);
      if (header.length != header.width * header.height * 4) {
        throw std::runtime_error("RGBA buffer size does not match dimensions");
      }
    }
    std::vector<uint8_t> input(header.length);
    if (!ReadAll(STDIN_FILENO, input.data(), input.size())) {
      throw std::runtime_error("Image worker input was truncated");
    }
    std::vector<uint8_t> output;
    if (header.operation == 0) {
      mesh_image::Image image{header.width, header.height, std::move(input)};
#if defined(MESH_IMAGE_BPG_ONLY)
      output = mesh_image::EncodeBpg(image, header.quality);
#else
      output = mesh_image::Encode(static_cast<mesh_image::Codec>(header.codec), image, header.quality);
#endif
    } else {
#if defined(MESH_IMAGE_BPG_ONLY)
      mesh_image::Image image = mesh_image::DecodeBpg(input);
#else
      mesh_image::Image image = mesh_image::Decode(static_cast<mesh_image::Codec>(header.codec), input);
#endif
      response.width = image.width;
      response.height = image.height;
      output = std::move(image.rgba);
    }
    if (output.empty() || output.size() > mesh_image::kMaxBytes) {
      throw std::runtime_error("Image codec produced an invalid output size");
    }
    response.status = 0;
    response.length = static_cast<uint32_t>(output.size());
    Send(response, output);
    return 0;
  } catch (const std::exception& error) {
    const std::string message = error.what();
    const size_t size = message.size() < 1024 ? message.size() : 1024;
    response.length = static_cast<uint32_t>(size);
    Send(response, std::vector<uint8_t>(message.begin(), message.begin() + size));
    return 1;
  } catch (...) {
    const std::string message = "Native image codec failed";
    response.length = static_cast<uint32_t>(message.size());
    Send(response, std::vector<uint8_t>(message.begin(), message.end()));
    return 1;
  }
}
