// daemon/main.m —— 常驻进程
//
// 生命周期：由启动器 app 用 posix_spawn + SETSID 孵化。
// app 被划掉后它继续活着（这是"浮窗不消失"的核心）。
// 重启设备后才消失（符合实测：重启后需要手动再开）。
//
// 当前版本只做注入链的验证，不做读内存与绘制：
//   1. 找 SpringBoard
//   2. task_for_pid
//   3. 远程 dlopen payload（payload 里建浮窗）
//   4. 每秒写心跳 + 检查 stop 标志文件
//
// 退出：启动器往容器里写 ar_daemon.stop，本进程 1 秒内退出。

#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "../src/Inject/RemoteLoad.h"

static FILE* g_log = NULL;

static void logf_(const char* fmt, ...) {
    if (!g_log) return;
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    fprintf(g_log, "[%02d:%02d:%02d] ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

int main(int argc, char** argv) {
    @autoreleasepool {
        setsid();                       // 双保险，脱离 app 的进程组
        signal(SIGPIPE, SIG_IGN);

        const char* logPath    = (argc > 1) ? argv[1] : "/tmp/ar_daemon.log";
        const char* payloadPath= (argc > 2) ? argv[2] : NULL;

        g_log = fopen(logPath, "a");
        logf_("daemon 启动 pid=%d ppid=%d", getpid(), getppid());

        if (!payloadPath) {
            logf_("缺少 payload 路径参数，退出");
            return 1;
        }
        logf_("payload=%s", payloadPath);

        // ---- 注入链 ----
        pid_t sb = rload::find_pid("SpringBoard");
        logf_("SpringBoard pid=%d", sb);
        if (!sb) { logf_("找不到 SpringBoard"); }

        if (sb) {
            mach_port_t t = MACH_PORT_NULL;
            kern_return_t kr = task_for_pid(mach_task_self(), sb, &t);
            logf_("task_for_pid(SpringBoard) -> %d %s", kr,
                  kr == KERN_SUCCESS ? "OK" : "FAILED");
            if (kr == KERN_SUCCESS) {
                mach_port_deallocate(mach_task_self(), t);
                bool ok = rload::inject("SpringBoard", payloadPath);
                logf_("inject -> %s", ok ? "resumed" : "failed");
            } else {
                logf_("entitlement 不足：检查 com.apple.system-task-ports / cs.debugger");
            }
        }

        // ---- 常驻循环 ----
        char stopPath[1024];
        snprintf(stopPath, sizeof(stopPath), "%s", logPath);
        // stop 标志与日志同目录
        char* slash = strrchr(stopPath, '/');
        if (slash) snprintf(slash + 1, sizeof(stopPath) - (slash + 1 - stopPath), "ar_daemon.stop");

        int tick = 0;
        for (;;) {
            sleep(1);
            logf_("tick %d pid=%d ppid=%d", ++tick, getpid(), getppid());

            if (access(stopPath, F_OK) == 0) {
                logf_("检测到 stop 标志，退出");
                unlink(stopPath);
                break;
            }
        }

        if (g_log) fclose(g_log);
        return 0;
    }
}
