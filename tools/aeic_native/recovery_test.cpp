#include "recovery.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <signal.h>
#include <stdexcept>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace aeic_recovery;
namespace {
void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
Tensor image(Shape shape, float value) {
    return Tensor{shape, std::vector<float>(std::size_t(shape.c) * shape.h * shape.w, value)};
}
}

int main() {
    try {
        // Crash tests must not leave large core files in the workspace.
        rlimit core{0, 0}; setrlimit(RLIMIT_CORE, &core);
        Options options; options.max_output_bytes = 4096; options.timeout_ms = 5000;
        Shape shape{1, 2, 2};
        const pid_t parent = getpid();
        int parent_only = 7;
        Result ok = run_isolated(shape, options, [&]() {
            require(getpid() != parent, "callback executed in parent");
            parent_only = 99;
            return image(shape, 0.25f);
        });
        require(ok.ok() && ok.output.values == std::vector<float>(4, 0.25f), "valid output lost");
        require(ok.child_peak_kb > 0, "successful child memory peak missing");
        require(parent_only == 7, "child changed parent state");
        Result crash = run_isolated(shape, options, []() -> Tensor {
            raise(SIGSEGV); _exit(99);
        });
        if (crash.status != Status::ChildSignal || crash.signal != SIGSEGV)
            std::cerr << "Crash diagnostic: " << status_name(crash.status) << " signal="
                      << crash.signal << " exit=" << crash.exit_code << " reason=" << crash.reason << '\n';
        require(crash.status == Status::ChildSignal && crash.signal == SIGSEGV && crash.output.values.empty(),
                "native crash escaped isolation or committed output");
        require(crash.child_peak_kb > 0, "crashed child memory peak missing");
        Result exception = run_isolated(shape, options, []() -> Tensor {
            throw std::runtime_error("model exception\nunsafe log newline");
        });
        require(exception.status == Status::ChildException && exception.reason.find('\n') == std::string::npos,
                "child exception not bounded/sanitized");
        Result wrong_shape = run_isolated(shape, options, []() { return image(Shape{1, 1, 4}, 1.f); });
        require(wrong_shape.status == Status::InvalidOutput && wrong_shape.output.values.empty(),
                "same element count accepted with wrong dimensions");
        Result nonfinite = run_isolated(shape, options, [=]() { return image(shape, std::numeric_limits<float>::quiet_NaN()); });
        require(nonfinite.status == Status::InvalidOutput, "NaN output accepted");
        Result incomplete = run_isolated(shape, options, []() -> Tensor { _exit(0); });
        require(incomplete.status == Status::ChildExit, "uncommitted clean child exit accepted");
        Options short_deadline = options;
        short_deadline.timeout_ms = 250;
        Result hang = run_isolated(shape, short_deadline, []() -> Tensor { while (true) pause(); });
        require(hang.status == Status::Timeout && hang.elapsed_ms < 2000, "hung child was not killed promptly");
        Result invalid = run_isolated(Shape{std::numeric_limits<int>::max(), std::numeric_limits<int>::max(),
                                            std::numeric_limits<int>::max()}, options, [=]() {
            return image(shape, 1.f);
        });
        require(invalid.status == Status::InvalidRequest, "oversized shape accepted");
        SharedResult direct = run_isolated_shared(shape, options, [&](float* target, std::size_t count) {
            require(getpid() != parent && count == 4, "direct callback ran in parent or got wrong capacity");
            parent_only = 101;
            std::fill(target, target + count, 0.75f);
        });
        require(direct.result.ok() && direct.owner && direct.elements == 4 &&
                direct.shape.c == 1 && direct.shape.h == 2 && direct.shape.w == 2 &&
                direct.result.output.values.empty() && direct.result.child_peak_kb > 0,
                "direct output allocated a vector or lost shape/ownership/memory metadata");
        require(parent_only == 7, "direct child changed private parent input");
        const float* direct_values = direct.values;
        std::shared_ptr<void> retained = direct.owner;
        direct.owner.reset();
        require(direct_values[0] == 0.75f && direct_values[3] == 0.75f,
                "shared output lifetime did not follow retained owner");
        retained.reset();
        SharedResult partial = run_isolated_shared(shape, options, [](float* target, std::size_t) {
            target[0] = 1.f;
        });
        require(partial.result.status == Status::InvalidOutput && !partial.owner && !partial.values &&
                partial.elements == 0, "partial direct write committed output");
        SharedResult direct_crash = run_isolated_shared(shape, options, [](float* target, std::size_t) {
            target[0] = 2.f; raise(SIGSEGV); _exit(99);
        });
        require(direct_crash.result.status == Status::ChildSignal &&
                direct_crash.result.signal == SIGSEGV && !direct_crash.owner && !direct_crash.values,
                "direct crash committed output or escaped containment");
        SharedResult direct_hang = run_isolated_shared(shape, short_deadline,
            [](float*, std::size_t) { while (true) pause(); });
        require(direct_hang.result.status == Status::Timeout && !direct_hang.owner && !direct_hang.values,
                "direct deadline committed output or failed to reap child");
        SharedResult direct_exception = run_isolated_shared(shape, options, [](float*, std::size_t) {
            throw std::runtime_error("direct model exception");
        });
        require(direct_exception.result.status == Status::ChildException && !direct_exception.owner,
                "direct exception committed output");
        SharedResult direct_invalid = run_isolated_shared(Shape{-1, 2, 2}, options,
            [](float*, std::size_t) { _exit(99); });
        require(direct_invalid.result.status == Status::InvalidRequest && !direct_invalid.owner,
                "direct output bypassed dimension validation");
        Options lazy_output = options;
        lazy_output.initialize_output = false;
        SharedResult lazy = run_isolated_shared(shape, lazy_output, [](float* target, std::size_t count) {
            require(std::all_of(target, target + count, [](float v) { return v == 0.f; }),
                    "lazy IPC was initialized before the trusted callback");
            std::fill(target, target + count, 0.125f);
        });
        require(lazy.result.ok() && lazy.values[3] == 0.125f && lazy.result.output.values.empty(),
                "lazy direct output failed to commit the fully written tensor");
        SharedResult lazy_failure = run_isolated_shared(shape, lazy_output, [](float* target, std::size_t) {
            target[0] = 2.f;
            throw std::runtime_error("inference failed after partial lazy copy");
        });
        require(lazy_failure.result.status == Status::ChildException && !lazy_failure.owner,
                "lazy partial exception output was committed");
        Fallback preserve = make_fallback(shape, 4096, {image(shape, 0.5f)});
        require(preserve.valid && preserve.strategy == "preserve" && preserve.output.values[0] == 0.5f,
                "valid input not preserved");
        Tensor tiny{Shape{1, 1, 2}, {1.f, 2.f}};
        Fallback resize = make_fallback(Shape{1, 2, 4}, 4096, {tiny});
        require(resize.valid && resize.strategy == "nearest_resize" &&
                resize.output.values == std::vector<float>({1, 1, 2, 2, 1, 1, 2, 2}), "resize coordinates wrong");
        Fallback neutral = make_fallback(shape, 4096, {image(shape, std::numeric_limits<float>::infinity())});
        require(neutral.valid && neutral.strategy == "zeros" && neutral.output.values == std::vector<float>(4, 0),
                "non-finite input was preserved");
        Fallback bad = make_fallback(Shape{-1, 2, 2}, 4096, {});
        require(!bad.valid, "fallback bypassed dimension validation");
        int status = 0; errno = 0;
        require(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD, "stage children were not reaped");
        std::cout << "RECOVERY_TEST_PASS: vector/shared success, ownership, incomplete writes, crash, exception, shape, NaN, exit, timeout, bounds, fallback, reaping\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "RECOVERY_TEST_FAIL: " << error.what() << '\n';
        return 1;
    }
}
