#include "image_codecs.h"

#include <jni.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <sys/resource.h>
#include <unistd.h>

namespace {
std::mutex operation_mutex;
std::mutex child_mutex;
pid_t active_child = -1;
std::atomic<uint64_t> cancel_generation{0};

void DrainSigpipe() {
  // libc sigtimedwait starts at API23. The kernel syscall exists on API21;
  // its signal set is always eight bytes, including on 32-bit Android.
  uint64_t mask = uint64_t(1) << (SIGPIPE - 1);
  timespec zero{0, 0};
  while (syscall(__NR_rt_sigtimedwait, &mask, nullptr, &zero, sizeof(mask)) >= 0) {}
}

struct Fd {
  int value = -1;
  ~Fd() { if (value >= 0) close(value); }
  void Close() { if (value >= 0) close(value); value = -1; }
};

void Throw(JNIEnv* env, const std::string& message) {
  jclass type = env->FindClass("java/lang/IllegalStateException");
  if (type) env->ThrowNew(type, message.c_str());
}

void FinishChild(pid_t child, bool terminate, int* status) {
  // Reap and clear the PID under one lock. Cancellation cannot accidentally
  // signal a PID reused after waitpid.
  std::lock_guard<std::mutex> lock(child_mutex);
  if (terminate) kill(child, SIGKILL);
  while (waitpid(child, status, 0) < 0 && errno == EINTR) {}
  if (active_child == child) active_child = -1;
}

std::vector<uint8_t> Run(
    const std::string& path, const mesh_image::RequestHeader& header,
    const std::vector<uint8_t>& input, int deadline_ms, uint64_t generation) {
  std::unique_lock<std::mutex> operation_lock(operation_mutex, std::try_to_lock);
  if (!operation_lock.owns_lock()) throw std::runtime_error("Another image codec is running");
  if (cancel_generation.load() != generation) throw std::runtime_error("Image compression cancelled");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(deadline_ms);
  int input_pipe[2] = {-1, -1};
  int output_pipe[2] = {-1, -1};
  if (pipe(input_pipe) < 0) throw std::runtime_error("Image input pipe creation failed");
  if (pipe(output_pipe) < 0) {
    close(input_pipe[0]); close(input_pipe[1]);
    throw std::runtime_error("Image output pipe creation failed");
  }
  Fd input_read{input_pipe[0]}, input_write{input_pipe[1]};
  Fd output_read{output_pipe[0]}, output_write{output_pipe[1]};
  // Prepare every pointer before fork. In the child, only async-signal-safe
  // functions run before exec; no malloc, JNI, C++, or codec library is used.
  const char* executable = path.c_str();
  char* const arguments[] = {const_cast<char*>(executable), nullptr};
  const auto slash = path.find_last_of('/');
  const std::string library_path = "LD_LIBRARY_PATH=" + path.substr(0, slash);
  char* const environment[] = {const_cast<char*>(library_path.c_str()), nullptr};
  rlimit descriptor_limit{};
  getrlimit(RLIMIT_NOFILE, &descriptor_limit);
  const int close_limit = static_cast<int>(std::min<rlim_t>(descriptor_limit.rlim_cur, 65536));
  pid_t child;
  {
    std::lock_guard<std::mutex> lock(child_mutex);
    // Cancel may have arrived while pipes/pointers were being prepared.
    // Checking under the PID ownership lock prevents that old job from
    // creating a process after cancellation already inspected active_child.
    if (cancel_generation.load() != generation) throw std::runtime_error("Image compression cancelled");
    child = fork();
    if (child > 0) active_child = child;
    if (child == 0) {
      if (dup2(input_pipe[0], STDIN_FILENO) < 0 || dup2(output_pipe[1], STDOUT_FILENO) < 0) _exit(126);
      for (int descriptor = 3; descriptor < close_limit; ++descriptor) close(descriptor);
      execve(executable, arguments, environment);
      _exit(127);
    }
  }
  if (child < 0) throw std::runtime_error("Image worker process creation failed");
  input_read.Close();
  output_write.Close();
  fcntl(input_write.value, F_SETFL, fcntl(input_write.value, F_GETFL) | O_NONBLOCK);
  fcntl(output_read.value, F_SETFL, fcntl(output_read.value, F_GETFL) | O_NONBLOCK);
  std::vector<uint8_t> packet(sizeof(header) + input.size());
  std::memcpy(packet.data(), &header, sizeof(header));
  std::memcpy(packet.data() + sizeof(header), input.data(), input.size());
  std::vector<uint8_t> response;
  response.reserve(4096);
  size_t sent = 0;
  size_t expected = sizeof(mesh_image::ResponseHeader);
  bool eof = false;
  int status = 0;
  try {
    while (!eof) {
      if (cancel_generation.load() != generation) throw std::runtime_error("Image compression cancelled");
      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
      if (remaining <= 0) throw std::runtime_error("Image codec deadline exceeded");
      pollfd descriptors[2] = {
          {output_read.value, POLLIN, 0},
          {input_write.value, POLLOUT, 0},
      };
      const int ready = poll(descriptors, 2, static_cast<int>(std::min<int64_t>(remaining, 50)));
      if (ready < 0 && errno == EINTR) continue;
      if (ready < 0) throw std::runtime_error("Image worker pipe polling failed");
      if (descriptors[1].revents & POLLOUT) {
        // A failed worker closes stdout, so drain/read that pipe first on the
        // next iteration. SIGPIPE is blocked for this native thread below.
        const ssize_t count = write(input_write.value, packet.data() + sent, packet.size() - sent);
        if (count > 0) sent += static_cast<size_t>(count);
        else if (count < 0 && errno != EAGAIN && errno != EINTR) input_write.Close();
        if (sent == packet.size()) input_write.Close();
      }
      if (descriptors[1].revents & (POLLHUP | POLLERR)) input_write.Close();
      if (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR)) {
        uint8_t block[8192];
        while (true) {
          const ssize_t count = read(output_read.value, block, sizeof(block));
          if (count == 0) { eof = true; break; }
          if (count < 0 && errno == EINTR) continue;
          if (count < 0 && errno == EAGAIN) break;
          if (count < 0) throw std::runtime_error("Image worker result read failed");
          if (response.size() + count > mesh_image::kMaxBytes + sizeof(mesh_image::ResponseHeader)) throw std::runtime_error("Image worker output exceeds its size limit");
          response.insert(response.end(), block, block + count);
          if (response.size() >= sizeof(mesh_image::ResponseHeader)) {
            mesh_image::ResponseHeader reply;
            std::memcpy(&reply, response.data(), sizeof(reply));
            if (reply.magic != mesh_image::kMagic || reply.length > mesh_image::kMaxBytes || reply.status > 1) throw std::runtime_error("Invalid image worker response");
            expected = sizeof(reply) + reply.length;
            if (response.size() > expected) throw std::runtime_error("Image worker returned trailing bytes");
          }
        }
      }
    }
    // A worker must exit after its one response. Kill after draining output to
    // make even an unexpected exit stall bounded, then reap before releasing.
    FinishChild(child, true, &status);
  } catch (...) {
    FinishChild(child, true, &status);
    throw;
  }
  if (cancel_generation.load() != generation) throw std::runtime_error("Image compression cancelled");
  if (response.size() < sizeof(mesh_image::ResponseHeader) || response.size() != expected) throw std::runtime_error("Image worker failed or returned a truncated result");
  mesh_image::ResponseHeader reply;
  std::memcpy(&reply, response.data(), sizeof(reply));
  const auto payload = response.begin() + sizeof(reply);
  if (reply.status) throw std::runtime_error(std::string(payload, response.end()));
  if (header.operation == 0) return std::vector<uint8_t>(payload, response.end());
  mesh_image::CheckDimensions(reply.width, reply.height);
  if (reply.length != reply.width * reply.height * 4) throw std::runtime_error("Decoded image geometry does not match its pixels");
  std::vector<uint8_t> output(8 + reply.length);
  std::memcpy(output.data(), &reply.width, 4);
  std::memcpy(output.data() + 4, &reply.height, 4);
  std::memcpy(output.data() + 8, &*payload, reply.length);
  return output;
}
}  // namespace

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_meshcore_meshcore_1open_MeshcoreImageNative_run(
    JNIEnv* env, jobject, jstring worker_path, jint operation, jint codec,
    jint width, jint height, jint quality, jbyteArray bytes, jint deadline_ms, jlong generation) {
  sigset_t blocked, previous;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &blocked, &previous);
  try {
    if (!worker_path || !bytes || (operation != 0 && operation != 1) || codec < 1 || codec > 9 || quality < 0 || quality > 100 || deadline_ms < 1 || deadline_ms > 120000) throw std::runtime_error("Invalid native image codec request");
    const jsize size = env->GetArrayLength(bytes);
    if (size <= 0 || size > static_cast<jsize>(mesh_image::kMaxBytes)) throw std::runtime_error("Image input exceeds its size limit");
    if (operation == 0) {
      mesh_image::CheckDimensions(width, height);
      if (size != width * height * 4) throw std::runtime_error("RGBA buffer size does not match dimensions");
    }
    const char* path_chars = env->GetStringUTFChars(worker_path, nullptr);
    if (!path_chars) throw std::runtime_error("Image worker path allocation failed");
    const std::string path(path_chars);
    env->ReleaseStringUTFChars(worker_path, path_chars);
    std::vector<uint8_t> input(size);
    env->GetByteArrayRegion(bytes, 0, size, reinterpret_cast<jbyte*>(input.data()));
    if (env->ExceptionCheck()) {
      pthread_sigmask(SIG_SETMASK, &previous, nullptr);
      return nullptr;
    }
    const mesh_image::RequestHeader header{mesh_image::kMagic, static_cast<uint32_t>(operation), static_cast<uint32_t>(codec), static_cast<uint32_t>(quality), static_cast<uint32_t>(width), static_cast<uint32_t>(height), static_cast<uint32_t>(size)};
    const auto output = Run(path, header, input, deadline_ms, static_cast<uint64_t>(generation));
    jbyteArray result = env->NewByteArray(output.size());
    if (result) env->SetByteArrayRegion(result, 0, output.size(), reinterpret_cast<const jbyte*>(output.data()));
    // A write to a dead pipe may have queued SIGPIPE. Drain it before restoring
    // the caller's mask; it must never reach the app's Android signal handler.
    DrainSigpipe();
    pthread_sigmask(SIG_SETMASK, &previous, nullptr);
    return result;
  } catch (const std::exception& error) {
    DrainSigpipe();
    pthread_sigmask(SIG_SETMASK, &previous, nullptr);
    Throw(env, error.what());
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_meshcore_meshcore_1open_MeshcoreImageNative_cancel(JNIEnv*, jobject) {
  cancel_generation.fetch_add(1);
  std::lock_guard<std::mutex> lock(child_mutex);
  if (active_child > 0) kill(active_child, SIGKILL);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_meshcore_meshcore_1open_MeshcoreImageNative_token(JNIEnv*, jobject) {
  return static_cast<jlong>(cancel_generation.load());
}
