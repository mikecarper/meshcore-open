#include "process_supervisor.h"
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <stdexcept>
#if defined(__linux__)
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace aeic {
#if defined(__linux__)
namespace {
volatile sig_atomic_t signal_group = 0;
volatile sig_atomic_t interrupted_signal = 0;
void relay_signal(int signal) {
    interrupted_signal = signal;
    const pid_t group = static_cast<pid_t>(signal_group);
    if (group > 1) {
        // The parent itself is never paused. A stopped worker must be resumed
        // before termination, including when the Android app has died.
        kill(-group, SIGCONT);
        kill(-group, SIGKILL);
    }
}
struct Signals {
    struct sigaction old_term, old_int, old_hup, old_pipe;
    explicit Signals() {
        signal_group = 0; interrupted_signal = 0;
        struct sigaction action{};
        action.sa_handler = relay_signal;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGTERM, &action, &old_term) || sigaction(SIGINT, &action, &old_int) || sigaction(SIGHUP, &action, &old_hup))
            throw std::runtime_error("cannot establish supervisor signal guard");
        action.sa_handler = SIG_IGN;
        if (sigaction(SIGPIPE, &action, &old_pipe)) throw std::runtime_error("cannot guard supervisor startup pipe");
    }
    ~Signals() {
        sigaction(SIGTERM, &old_term, nullptr);
        sigaction(SIGINT, &old_int, nullptr);
        sigaction(SIGHUP, &old_hup, nullptr);
        sigaction(SIGPIPE, &old_pipe, nullptr);
        signal_group = 0;
    }
    void worker_defaults() const {
        struct sigaction action{}; action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask);
        sigaction(SIGTERM, &action, nullptr); sigaction(SIGINT, &action, nullptr); sigaction(SIGHUP, &action, nullptr);
        sigaction(SIGPIPE, &old_pipe, nullptr);
    }
};
struct Pipe {
    int descriptors[2] = {-1, -1};
    Pipe() { if (pipe(descriptors)) throw std::runtime_error("cannot create supervisor startup gate"); }
    ~Pipe() { close_end(0); close_end(1); }
    void close_end(int side) { if (descriptors[side] >= 0) { close(descriptors[side]); descriptors[side] = -1; } }
};
bool byte_read(int fd) {
    char byte = 0; ssize_t count;
    do { count = read(fd, &byte, 1); } while (count < 0 && errno == EINTR);
    return count == 1 && byte == 1;
}
bool byte_write(int fd) {
    const char byte = 1; ssize_t count;
    do { count = write(fd, &byte, 1); } while (count < 0 && errno == EINTR);
    return count == 1;
}
int reap_worker(pid_t child, const std::function<void(int)>& exited) {
    // Observe without reaping first: the zombie reserves its PID/group number
    // while we terminate any remaining group members, preventing PID reuse.
    siginfo_t information{};
    int result;
    do { result = waitid(P_PID, static_cast<id_t>(child), &information, WEXITED | WNOWAIT); }
    while (result < 0 && errno == EINTR);
    if (result < 0) throw std::runtime_error("supervisor waitid failed");
    sigset_t blocked, previous;
    sigemptyset(&blocked); sigaddset(&blocked, SIGTERM); sigaddset(&blocked, SIGINT); sigaddset(&blocked, SIGHUP);
    if (sigprocmask(SIG_BLOCK, &blocked, &previous)) throw std::runtime_error("cannot guard supervisor reap");
    kill(-child, SIGCONT);
    kill(-child, SIGKILL);
    int status = 0; pid_t reaped;
    do { reaped = waitpid(child, &status, 0); } while (reaped < 0 && errno == EINTR);
    signal_group = 0;
    if (sigprocmask(SIG_SETMASK, &previous, nullptr)) throw std::runtime_error("cannot restore supervisor signal mask");
    if (reaped != child) throw std::runtime_error("supervisor did not reap its worker");
    exited(static_cast<int>(child));
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    throw std::runtime_error("unexpected supervisor worker status");
}
}
#endif
int supervise_job(const std::function<int()>& worker, const std::function<void(int)>& ready,
                  const std::function<void(int)>& exited) {
#if defined(__linux__)
    // Before any OpenMP/inference initialization, and without changing the
    // direct child's inherited app group, establish a guarded startup gate.
    const pid_t original_parent = getppid();
    Signals signals;
    if (prctl(PR_SET_PDEATHSIG, SIGTERM)) throw std::runtime_error("cannot guard supervisor parent lifetime");
    if (getppid() != original_parent) return 128 + SIGTERM;
    Pipe established, proceed;
    const pid_t supervisor = getpid();
    const pid_t child = fork();
    if (child < 0) throw std::runtime_error("cannot fork codec worker");
    if (child == 0) {
        signals.worker_defaults();
        established.close_end(0); proceed.close_end(1);
        if (setpgid(0, 0) || getpgrp() != getpid() || prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != supervisor)
            _exit(127);
        if (!byte_write(established.descriptors[1])) _exit(127);
        established.close_end(1);
        if (!byte_read(proceed.descriptors[0])) _exit(127);
        proceed.close_end(0);
        int code = 1;
        try { code = worker(); } catch (...) { code = 1; }
        std::fflush(nullptr);
        // _exit avoids running supervisor handlers/destructors in the child.
        _exit(code >= 0 && code <= 255 ? code : 1);
    }
    established.close_end(1); proceed.close_end(0);
    bool group_created = setpgid(child, child) == 0;
    if (!group_created && getpgid(child) == child) group_created = true;
    if (group_created) signal_group = static_cast<sig_atomic_t>(child);
    try {
        if (!group_created || !byte_read(established.descriptors[0])) {
            kill(child, SIGKILL);
            return reap_worker(child, exited);
        }
        established.close_end(0);
        if (interrupted_signal || getppid() != original_parent) {
            relay_signal(interrupted_signal ? interrupted_signal : SIGTERM);
        } else {
            ready(static_cast<int>(child));
            if (!byte_write(proceed.descriptors[1])) kill(-child, SIGKILL);
        }
        proceed.close_end(1);
        return reap_worker(child, exited);
    } catch (...) {
        // Callback/I/O failures cannot leave a paused child behind.
        if (signal_group > 1) { kill(-child, SIGCONT); kill(-child, SIGKILL); }
        else kill(child, SIGKILL);
        try { reap_worker(child, [](int) {}); } catch (...) {}
        throw;
    }
#else
    (void)worker; (void)ready; (void)exited;
    throw std::runtime_error("app supervision requires Linux or Android");
#endif
}
}
