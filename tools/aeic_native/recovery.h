#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

// Optional model-stage crash containment. The caller retains all normal tensor,
// bitstream, and dimension checks and labels every fallback output DEGRADED.
// Use from a single-threaded parent that has never initialized OpenMP/ncnn.
namespace aeic_recovery {

struct Shape {
    int c = 0;
    int h = 0;
    int w = 0;
};

struct Tensor {
    Shape shape;
    std::vector<float> values; // Contiguous CHW, one image, finite float32.
};

struct Options {
    std::size_t max_output_bytes = 128u * 1024u * 1024u;
    std::uint64_t timeout_ms = 300000;
    unsigned poll_ms = 5;
    // Optional cumulative paused milliseconds, read only in the parent.
    // The baseline is captured once per stage; later monotonic increases are
    // excluded from its deadline. elapsed_ms remains wall-clock time.
    std::function<std::uint64_t()> paused_ms;
    // Disable only for a trusted callback that checks shape/count and writes
    // every plane after model execution. This avoids faulting IPC pages while
    // inference intermediates are resident, but cannot detect omitted writes.
    bool initialize_output = true;
};

enum class Status {
    Success,
    InvalidRequest,
    SetupFailure,
    ChildException,
    InvalidOutput,
    ChildSignal,
    ChildExit,
    Timeout,
    WaitFailure,
};

struct Result {
    Status status = Status::InvalidRequest;
    Tensor output;
    int signal = 0;
    int exit_code = -1;
    std::uint64_t elapsed_ms = 0;
    std::uint64_t child_peak_kb = 0; // Linux/Android ru_maxrss, including failed children.
    std::string reason;
    bool ok() const { return status == Status::Success; }
};

// Validate dimensions and multiplication before any allocation or fork.
bool checked_elements(Shape shape, std::size_t max_bytes, std::size_t& elements,
                      std::string& reason);
const char* status_name(Status status);

// Load/run/destroy the ncnn graph entirely inside child_work. This function
// never invokes child_work in the parent. A signal, exception, wrong shape,
// non-finite output, or deadline cannot commit a partial tensor to the parent.
Result run_isolated(Shape expected, const Options& options,
                    const std::function<Tensor()>& child_work);

struct SharedResult {
    Result result; // output.values remains empty; status and child RSS are retained.
    std::shared_ptr<void> owner; // Keeps the read-only-to-caller mapping alive.
    const float* values = nullptr;
    std::size_t elements = 0;
    Shape shape;
};

// The callback runs only in the child and must validate its model tensor's CHW
// shape before writing exactly count finite floats into target. With default
// options, missing writes remain NaN and cannot commit. The caller may copy the returned mapping once
// into its owned tensor, then reset owner to release IPC without a vector copy.
SharedResult run_isolated_shared(
    Shape expected, const Options& options,
    const std::function<void(float* target, std::size_t count)>& child_work);

enum class FallbackPolicy { Zeros, PreserveOrResize };

struct Fallback {
    Tensor output;
    bool valid = false;
    std::string reason;
    std::string strategy; // "preserve", "nearest_resize", or "zeros".
};

// Preserve a valid exact-shape input, otherwise nearest-resize a valid input
// with matching channels. Missing/incompatible/non-finite inputs produce zeros.
// Zero normalized RGB is neutral gray; fallback cannot recover lost details.
Fallback make_fallback(Shape expected, std::size_t max_bytes,
                       const std::vector<Tensor>& inputs,
                       FallbackPolicy policy = FallbackPolicy::PreserveOrResize);

} // namespace aeic_recovery
