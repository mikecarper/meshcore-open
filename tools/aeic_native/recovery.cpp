#include "recovery.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <signal.h>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#if defined(__linux__)
#include <sys/prctl.h>
#endif
#include <time.h>
#include <unistd.h>
#include <utility>

namespace aeic_recovery {
namespace {

static_assert(ATOMIC_INT_LOCK_FREE == 2, "Shared recovery status needs lock-free 32-bit atomics");
enum SharedState : unsigned { Pending = 0, Complete = 1, Exception = 2, Rejected = 3 };
struct SharedHeader {
    std::atomic<unsigned> state;
    std::size_t elements;
    std::uint64_t child_peak_kb;
    char reason[192];
};

class InvalidTensor : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

std::uint64_t monotonic_ms() {
    timespec now{};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        throw std::runtime_error("CLOCK_MONOTONIC unavailable");
    return std::uint64_t(now.tv_sec) * 1000u + std::uint64_t(now.tv_nsec) / 1000000u;
}

bool same(Shape a, Shape b) { return a.c == b.c && a.h == b.h && a.w == b.w; }
bool finite(const std::vector<float>& values) {
    return std::all_of(values.begin(), values.end(), [](float value) { return std::isfinite(value); });
}

void message(SharedHeader* header, const char* text) {
    std::size_t i = 0;
    if (text) {
        for (; text[i] && i + 1 < sizeof(header->reason); ++i) {
            const unsigned char ch = static_cast<unsigned char>(text[i]);
            header->reason[i] = ch < 32 || ch == 127 ? ' ' : char(ch);
        }
    }
    header->reason[i] = '\0';
}

std::uint64_t peak_kb(const rusage& usage) {
    return usage.ru_maxrss > 0 ? std::uint64_t(usage.ru_maxrss) : 0;
}

[[noreturn]] void finish_child(SharedHeader* header, unsigned state, int code) {
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) == 0) header->child_peak_kb = peak_kb(usage);
    header->state.store(state, std::memory_order_release);
    _exit(code);
}

class Mapping {
public:
    explicit Mapping(std::size_t bytes) : bytes_(bytes) {
        address_ = mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    }
    ~Mapping() { if (address_ != MAP_FAILED) munmap(address_, bytes_); }
    Mapping(const Mapping&) = delete;
    Mapping& operator=(const Mapping&) = delete;
    void* address() const { return address_; }
private:
    void* address_;
    std::size_t bytes_;
};

class Child {
public:
    explicit Child(pid_t pid) : pid_(pid) {}
    ~Child() { if (pid_ > 0) terminate(); }
    void reaped() { pid_ = -1; }
    std::uint64_t terminate() {
        if (pid_ <= 0) return 0;
        kill(pid_, SIGKILL); // Only this still-unreaped child PID is targeted.
        int status = 0;
        rusage usage{};
        while (wait4(pid_, &status, 0, &usage) < 0 && errno == EINTR) {}
        pid_ = -1;
        return peak_kb(usage);
    }
private:
    pid_t pid_;
};

} // namespace

bool checked_elements(Shape shape, std::size_t max_bytes, std::size_t& elements,
                      std::string& reason) {
    elements = 0;
    if (shape.c <= 0 || shape.h <= 0 || shape.w <= 0 || max_bytes < sizeof(float)) {
        reason = "non-positive tensor dimension or insufficient byte limit";
        return false;
    }
    std::size_t count = 1;
    for (int dimension : {shape.c, shape.h, shape.w}) {
        const auto value = std::size_t(dimension);
        if (value > std::numeric_limits<std::size_t>::max() / count) {
            reason = "tensor element-count overflow";
            return false;
        }
        count *= value;
    }
    if (count > max_bytes / sizeof(float)) {
        reason = "tensor exceeds recovery output byte limit";
        return false;
    }
    elements = count;
    reason.clear();
    return true;
}

const char* status_name(Status status) {
    switch (status) {
        case Status::Success: return "success";
        case Status::InvalidRequest: return "invalid_request";
        case Status::SetupFailure: return "setup_failure";
        case Status::ChildException: return "child_exception";
        case Status::InvalidOutput: return "invalid_output";
        case Status::ChildSignal: return "child_signal";
        case Status::ChildExit: return "child_exit";
        case Status::Timeout: return "timeout";
        case Status::WaitFailure: return "wait_failure";
    }
    return "unknown";
}

static Result run_shared_impl(
    Shape expected, const Options& options,
    const std::function<void(float*, std::size_t)>& child_work,
    std::shared_ptr<void>& owner, const float*& values, std::size_t& elements) {
    Result result;
    std::size_t count = 0;
    if (!checked_elements(expected, options.max_output_bytes, count, result.reason)) return result;
    if (!child_work || !options.timeout_ms || !options.poll_ms) {
        result.reason = "callback, finite deadline, and positive poll interval are required";
        return result;
    }
    const std::size_t offset = (sizeof(SharedHeader) + 63u) & ~std::size_t(63u);
    const std::size_t payload_bytes = count * sizeof(float);
    if (payload_bytes > std::numeric_limits<std::size_t>::max() - offset) {
        result.reason = "mapping byte-count overflow";
        return result;
    }
    std::shared_ptr<Mapping> shared;
    try { shared = std::make_shared<Mapping>(offset + payload_bytes); }
    catch (const std::exception& error) {
        result.status = Status::SetupFailure; result.reason = error.what(); return result;
    }
    if (shared->address() == MAP_FAILED) {
        result.status = Status::SetupFailure;
        result.reason = std::string("shared output mapping failed: ") + std::strerror(errno);
        return result;
    }
    auto* header = new (shared->address()) SharedHeader;
    header->state.store(Pending, std::memory_order_relaxed);
    header->elements = 0;
    header->child_peak_kb = 0;
    header->reason[0] = '\0';
    auto* payload = reinterpret_cast<float*>(static_cast<char*>(shared->address()) + offset);
    std::uint64_t start = 0;
    try { start = monotonic_ms(); }
    catch (const std::exception& error) {
        result.status = Status::SetupFailure; result.reason = error.what(); return result;
    }
    const pid_t parent_pid = getpid();
    const pid_t pid = fork();
    if (pid < 0) {
        result.status = Status::SetupFailure;
        result.reason = std::string("stage fork failed: ") + std::strerror(errno);
        return result;
    }
    if (pid == 0) {
        rlimit core{0, 0};
        setrlimit(RLIMIT_CORE, &core);
#if defined(__linux__)
        // Core-collection daemons can delay a fatal child's exit even when the
        // core byte limit is zero. These disposable stages must not dump data.
        prctl(PR_SET_DUMPABLE, 0);
        // A stopped/killed frontend must not leave inference running orphaned.
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent_pid) {
            message(header, "stage parent-death guard could not be established");
            finish_child(header, Rejected, 11);
        }
#else
        (void)parent_pid;
#endif
        try {
            // Initialize in the child so an incomplete write cannot look like
            // a valid zero tensor or increase the parent's resident memory.
            if (options.initialize_output)
                std::fill(payload, payload + count, std::numeric_limits<float>::quiet_NaN());
            child_work(payload, count);
            if (!std::all_of(payload, payload + count, [](float value) { return std::isfinite(value); })) {
                message(header, "child returned incomplete or non-finite output values");
                finish_child(header, Rejected, 11);
            }
            header->elements = count;
            finish_child(header, Complete, 0);
        } catch (const InvalidTensor& error) {
            message(header, error.what());
            finish_child(header, Rejected, 11);
        } catch (const std::exception& error) {
            message(header, error.what());
            finish_child(header, Exception, 10);
        } catch (...) {
            message(header, "child threw an unknown exception");
            finish_child(header, Exception, 10);
        }
    }
    Child child(pid);
    int status = 0;
    try {
        while (true) {
            rusage usage{};
            const pid_t waited = wait4(pid, &status, WNOHANG, &usage);
            if (waited == pid) { result.child_peak_kb = peak_kb(usage); child.reaped(); break; }
            if (waited < 0 && errno != EINTR) {
                result.status = Status::WaitFailure;
                result.reason = std::string("stage wait failed: ") + std::strerror(errno);
                return result;
            }
            result.elapsed_ms = monotonic_ms() - start;
            if (result.elapsed_ms >= options.timeout_ms) {
                result.child_peak_kb = child.terminate();
                result.elapsed_ms = monotonic_ms() - start;
                result.status = Status::Timeout;
                result.reason = "model stage exceeded its recovery deadline";
                return result;
            }
            const auto delay = std::min<std::uint64_t>(options.poll_ms, options.timeout_ms - result.elapsed_ms);
            timespec pause{time_t(delay / 1000u), long((delay % 1000u) * 1000000u)};
            while (nanosleep(&pause, &pause) < 0 && errno == EINTR) {}
        }
        result.elapsed_ms = monotonic_ms() - start;
        if (WIFSIGNALED(status)) {
            result.status = Status::ChildSignal;
            result.signal = WTERMSIG(status);
            result.reason = "model stage child terminated by signal";
            return result;
        }
        if (!WIFEXITED(status)) {
            result.status = Status::ChildExit;
            result.reason = "model stage child did not exit normally";
            return result;
        }
        result.exit_code = WEXITSTATUS(status);
        const unsigned state = header->state.load(std::memory_order_acquire);
        result.child_peak_kb = std::max(result.child_peak_kb, header->child_peak_kb);
        if (state == Exception) {
            result.status = Status::ChildException;
            result.reason = header->reason;
            return result;
        }
        if (state == Rejected) {
            result.status = Status::InvalidOutput;
            result.reason = header->reason;
            return result;
        }
        if (result.exit_code != 0 || state != Complete || header->elements != count) {
            result.status = Status::ChildExit;
            result.reason = "model stage exited without a complete validated output";
            return result;
        }
        // Check the committed mapping too; callback success is not trusted alone.
        if (!std::all_of(payload, payload + count, [](float value) { return std::isfinite(value); })) {
            result.status = Status::InvalidOutput;
            result.reason = "shared stage output contains non-finite values";
            return result;
        }
        owner = shared;
        values = payload;
        elements = count;
        result.status = Status::Success;
        return result;
    } catch (const std::exception& error) {
        result.status = Status::SetupFailure;
        result.reason = error.what();
        return result;
    }
}

SharedResult run_isolated_shared(
    Shape expected, const Options& options,
    const std::function<void(float*, std::size_t)>& child_work) {
    SharedResult shared;
    shared.result = run_shared_impl(expected, options, child_work,
                                    shared.owner, shared.values, shared.elements);
    if (shared.result.ok()) shared.shape = expected;
    return shared;
}

Result run_isolated(Shape expected, const Options& options,
                    const std::function<Tensor()>& child_work) {
    if (!child_work) {
        Result result;
        result.reason = "callback, finite deadline, and positive poll interval are required";
        return result;
    }
    SharedResult shared = run_isolated_shared(expected, options,
        [&](float* target, std::size_t count) {
            Tensor tensor = child_work();
            if (!same(tensor.shape, expected) || tensor.values.size() != count)
                throw InvalidTensor("child returned wrong shape or wrong element count");
            std::memcpy(target, tensor.values.data(), count * sizeof(float));
        });
    if (shared.result.ok()) {
        try {
            shared.result.output.shape = expected;
            shared.result.output.values.assign(shared.values, shared.values + shared.elements);
        } catch (const std::exception& error) {
            shared.result.status = Status::SetupFailure;
            shared.result.reason = error.what();
            shared.result.output = Tensor{};
        }
    }
    return std::move(shared.result);
}

Fallback make_fallback(Shape expected, std::size_t max_bytes,
                       const std::vector<Tensor>& inputs, FallbackPolicy policy) {
    Fallback result;
    std::size_t count = 0;
    if (!checked_elements(expected, max_bytes, count, result.reason)) return result;
    const Tensor* exact = nullptr;
    const Tensor* resized = nullptr;
    if (policy == FallbackPolicy::PreserveOrResize) {
        for (const Tensor& tensor : inputs) {
            std::size_t input_count = 0;
            std::string ignored;
            if (tensor.shape.c != expected.c ||
                !checked_elements(tensor.shape, max_bytes, input_count, ignored) ||
                tensor.values.size() != input_count || !finite(tensor.values)) continue;
            if (same(tensor.shape, expected)) { exact = &tensor; break; }
            if (!resized) resized = &tensor;
        }
    }
    try {
        result.output.shape = expected;
        if (exact) {
            result.output.values = exact->values;
            result.strategy = "preserve";
        } else if (resized) {
            result.output.values.resize(count);
            const Shape source = resized->shape;
            for (int c = 0; c < expected.c; ++c)
                for (int y = 0; y < expected.h; ++y)
                    for (int x = 0; x < expected.w; ++x) {
                        const int sy = int(std::uint64_t(y) * source.h / expected.h);
                        const int sx = int(std::uint64_t(x) * source.w / expected.w);
                        const std::size_t out = (std::size_t(c) * expected.h + y) * expected.w + x;
                        const std::size_t in = (std::size_t(c) * source.h + sy) * source.w + sx;
                        result.output.values[out] = resized->values[in];
                    }
            result.strategy = "nearest_resize";
        } else {
            result.output.values.assign(count, 0.f);
            result.strategy = "zeros";
        }
        result.valid = true;
        result.reason = "DEGRADED: substituted model output; lost details are not recoverable";
    } catch (const std::exception& error) {
        result.reason = error.what();
    }
    return result;
}

} // namespace aeic_recovery
