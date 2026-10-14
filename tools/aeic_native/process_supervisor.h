#pragma once
#include <functional>

namespace aeic {
// The direct ProcessBuilder child stays in its inherited group for Android5's
// waitpid(0) reaper. Only the inference worker owns a separate signal group.
// Both callbacks run in the supervisor; ready precedes any inference work.
int supervise_job(const std::function<int()>& worker,
                  const std::function<void(int)>& ready,
                  const std::function<void(int)>& exited);
}
