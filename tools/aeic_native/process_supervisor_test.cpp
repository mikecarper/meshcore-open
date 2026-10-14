#include "process_supervisor.h"
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#if defined(__linux__)
#include <cerrno>
#include <fstream>
#include <poll.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

static void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
#if defined(__linux__)
namespace {
struct Message { int type, pid, detail; };
void send_message(int fd, Message message) {
    require(write(fd, &message, sizeof(message)) == ssize_t(sizeof(message)), "cannot write fixture message");
}
Message receive_message(int fd) {
    pollfd descriptor{fd, POLLIN, 0};
    int ready;
    do { ready = poll(&descriptor, 1, 3000); } while (ready < 0 && errno == EINTR);
    require(ready == 1, "fixture readiness timed out");
    Message message{};
    require(read(fd, &message, sizeof(message)) == ssize_t(sizeof(message)), "missing fixture message");
    return message;
}
void noop(int) {}
bool stopped(pid_t pid) {
    std::ifstream file("/proc/" + std::to_string(pid) + "/status"); std::string line;
    while (std::getline(file, line)) if (line.compare(0, 6, "State:") == 0) return line.find('T', 6) != std::string::npos;
    return false;
}
int reap(pid_t pid, bool app_group = false) {
    int status = 0; pid_t result;
    do { result = waitpid(app_group ? 0 : pid, &status, 0); } while (result < 0 && errno == EINTR);
    require(result == pid, "waitpid did not reap expected child");
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    require(WIFSIGNALED(status), "unexpected process status");
    return 128 + WTERMSIG(status);
}
void absent(pid_t pid) { require(kill(pid, 0) == -1 && errno == ESRCH, "fixture left a live process or zombie"); }
pid_t run_supervisor(int report, int mode) {
    pid_t pid = fork(); require(pid >= 0, "cannot fork supervisor fixture");
    if (pid == 0) {
        struct sigaction action{}; action.sa_handler = noop; sigemptyset(&action.sa_mask);
        sigaction(SIGUSR1, &action, nullptr);
        try {
            int code = aeic::supervise_job([&]() {
                if (mode == 0) return 7;
                if (mode == 2) { usleep(100000); return 9; }
                if (mode == 4) {
                    pid_t owner = getpid(), grandchild = fork();
                    if (grandchild == 0) {
                        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != owner) _exit(127);
                        for (;;) pause();
                    }
                    send_message(report, {2, static_cast<int>(grandchild), static_cast<int>(owner)});
                } else send_message(report, {2, static_cast<int>(getpid()), 0});
                for (;;) pause();
            }, [&](int worker) {
                send_message(report, {1, worker, static_cast<int>(getpid())});
                if (mode == 3) usleep(250000); // cancel before releasing startup gate
            }, [&](int worker) { send_message(report, {3, worker, static_cast<int>(getpid())}); });
            _exit(code);
        } catch (...) { _exit(126); }
    }
    return pid;
}
}
#endif
int main() {
#if defined(__linux__)
    // Adopt orphan fixture descendants so the test can assert that none remain
    // as zombies after abrupt supervisor/app death.
    try {
        require(setpgid(0, 0) == 0 && prctl(PR_SET_CHILD_SUBREAPER, 1) == 0, "cannot establish isolated fixture group");
        int descriptors[2]; require(pipe(descriptors) == 0, "cannot create fixture pipe");
        pid_t supervisor = run_supervisor(descriptors[1], 0);
        auto ready = receive_message(descriptors[0]);
        require(ready.type == 1 && ready.detail == supervisor && ready.pid != supervisor, "handshake must identify separate worker");
        require(getpgid(supervisor) == getpgrp(), "direct launcher must remain in Android app group");
        require(reap(supervisor, true) == 7, "app-group waitpid(0) must observe normal exit code");
        auto exited = receive_message(descriptors[0]);
        require(exited.type == 3 && exited.pid == ready.pid, "worker exit marker mismatch");
        absent(ready.pid); absent(supervisor);

        supervisor = run_supervisor(descriptors[1], 1);
        ready = receive_message(descriptors[0]); auto active = receive_message(descriptors[0]);
        require(active.type == 2 && getpgid(ready.pid) == ready.pid, "worker must own group before work");
        require(kill(-ready.pid, SIGSTOP) == 0, "cannot stop worker group");
        for (int attempt = 0; attempt < 100 && !stopped(ready.pid); ++attempt) usleep(1000);
        require(stopped(ready.pid) && !stopped(supervisor), "pause must stop worker and preserve supervisor reaper");
        require(kill(-ready.pid, SIGCONT) == 0 && kill(-ready.pid, SIGTERM) == 0, "cannot resume/cancel worker");
        require(reap(supervisor, true) == 128 + SIGTERM, "cancelled worker status must propagate");
        exited = receive_message(descriptors[0]); require(exited.type == 3, "cancelled worker must emit exit marker");
        absent(ready.pid); absent(supervisor);

        supervisor = run_supervisor(descriptors[1], 2);
        ready = receive_message(descriptors[0]);
        require(kill(supervisor, SIGUSR1) == 0, "cannot interrupt supervisor wait");
        require(reap(supervisor, true) == 9, "EINTR must not lose normal worker status");
        exited = receive_message(descriptors[0]); require(exited.type == 3, "EINTR exit marker missing"); absent(ready.pid);

        supervisor = run_supervisor(descriptors[1], 3);
        ready = receive_message(descriptors[0]);
        require(kill(supervisor, SIGKILL) == 0, "cannot terminate startup supervisor");
        require(reap(supervisor, true) == 128 + SIGKILL, "abrupt supervisor status changed");
        require(reap(ready.pid) == 128 + SIGKILL, "gated worker must die with supervisor");
        absent(ready.pid);

        pid_t app = fork(); require(app >= 0, "cannot fork app fixture");
        if (app == 0) { run_supervisor(descriptors[1], 4); for (;;) pause(); }
        ready = receive_message(descriptors[0]); active = receive_message(descriptors[0]);
        require(ready.type == 1 && active.type == 2 && active.detail == ready.pid, "app-death descendant fixture invalid");
        require(kill(-ready.pid, SIGSTOP) == 0 && kill(app, SIGKILL) == 0, "cannot stop/death-test worker group");
        require(reap(app, true) == 128 + SIGKILL, "app fixture status changed");
        require(reap(ready.detail) == 128 + SIGKILL, "supervisor must kill/reap worker after app death");
        exited = receive_message(descriptors[0]); require(exited.type == 3, "app-death worker exit marker missing");
        require(reap(active.pid) == 128 + SIGKILL, "paused recovery descendant must die after app death");
        absent(ready.pid); absent(ready.detail); absent(active.pid);
        close(descriptors[0]); close(descriptors[1]);
        std::puts("PASS: Android app-group reaping, gated worker group, pause/cancel, EINTR, parent death, no zombies");
        return 0;
    } catch (const std::exception& error) { std::fprintf(stderr, "FAIL %s\n", error.what()); return 1; }
#else
    std::puts("SKIP: Linux/Android supervisor tests"); return 0;
#endif
}
