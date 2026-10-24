// DaemonSpawn.h —— 从 app 孵化常驻进程（header-only）
//
// 关键点：
//   POSIX_SPAWN_SETSID   子进程在新会话里，脱离 app 的进程组
//   stdio 全丢弃         父进程死后写管道会 SIGPIPE
//   信号处理重置为默认   不继承 app 里可能被 hook 过的 handler
//   helper 必须签名      否则 posix_spawn 返回 EBADEXEC

#pragma once
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <string.h>

extern char** environ;

namespace host {

static inline pid_t spawn_daemon(const char* helperPath, char* const argv[], int* errOut) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    sigset_t empty, dfl;
    sigemptyset(&empty);
    sigemptyset(&dfl);
    posix_spawnattr_setsigmask(&attr, &empty);
    posix_spawnattr_setsigdefault(&attr, &dfl);

    pid_t pid = -1;
    int rc = posix_spawn(&pid, helperPath, &fa, &attr, argv, environ);

    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        if (errOut) *errOut = rc;     // rc 本身就是 errno
        return -1;
    }
    if (errOut) *errOut = 0;
    return pid;
}

static inline bool pid_alive(pid_t pid) {
    if (pid <= 0) return false;
    return kill(pid, 0) == 0 || errno == EPERM;
}

} // namespace host
