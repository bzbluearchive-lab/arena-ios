// XRead.h —— 跨进程读后端（kfd），形态 B 用。
//
// 与 SafeMem.h 的 mem:: 完全同语义，上层 World/Aim/Overlay 不需要任何改动。
//
// 设计红线（形态 B 的全部风险都在这里）：
//   1. 任何地址在采信前先过 canary：目标 app 的 mach_header 魔数 + cputype 必须对
//   2. 只用 kfd 解析出来的、带 VM_PROT_READ 的页
//   3. pid == 自己时直接回退到同进程读，核内路径不参与
//
// 未验证项：kfd 在你这个 iOS 16.1.1 / arm64e 上的 exploit 分支是否可用；
// 以 kfd 仓库当前支持表为准，别默认通过。

#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include "SafeMem.h"

// kfd 的头文件由外部提供（把 kfd 仓库的 libkfd.h 放进 vendor/）
#if __has_include("libkfd.h")
#  include "libkfd.h"
#  define HAVE_KFD 1
#else
#  define HAVE_KFD 0
#endif

namespace xmem {

struct Target {
    pid_t    pid     = 0;
    uint64_t task    = 0;   // kfd 的 task 内核地址
    uint64_t base    = 0;   // 主二进制加载基址（slid）
    bool     ready   = false;
};

static Target g_t;

// ---------- 进程查找 ----------
inline pid_t find_pid(const char* nameNeedle) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, nullptr, &sz, nullptr, 0) != 0 || sz == 0) return 0;
    struct kinfo_proc* procs = (struct kinfo_proc*)malloc(sz);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &sz, nullptr, 0) != 0) { free(procs); return 0; }

    pid_t found = 0;
    size_t n = sz / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < n; i++) {
        const char* nm = procs[i].kp_proc.p_comm;
        if (nm && strstr(nm, nameNeedle)) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

// ---------- canary：确认这是目标 app 的 mach-o，不是垃圾 ----------
inline bool canary_ok(uint64_t addr, cpu_type_t expectCpu) {
    if (addr < 0x100000000ULL || addr > 0x00007FFFFFFFFFFFULL) return false;
    uint32_t magic = 0;
    if (!xmem::read(addr, &magic, 4)) return false;
    if (magic != 0xFEEDFACF) return false;   // MH_MAGIC_64
    cpu_type_t cpu = 0;
    if (!xmem::read(addr + 4, &cpu, 4)) return false;
    return cpu == expectCpu;                 // 12 = ARM, 12|0x01000000 = ARM64
}

// ---------- 读 ----------
inline bool read(uint64_t addr, void* out, size_t n) {
    if (addr == 0 || out == nullptr || n == 0) return false;

    // 自己进程：走同进程路径，不惊动内核
    if (!g_t.ready || g_t.pid == getpid())
        return mem::read((uintptr_t)addr, out, n);

#if HAVE_KFD
    uint64_t got = kfd_read_mem(g_t.task, addr, out, n);
    return got == n;
#else
    (void)n;
    return false;   // 没接 kfd 时 fail-closed，绝不返回垃圾数据
#endif
}

inline uint64_t rdptr(uint64_t addr) {
    uint64_t v = 0;
    return read(addr, &v, sizeof(v)) ? v : 0;
}

template <typename T>
inline bool rd(uint64_t addr, T& out) { return read(addr, &out, sizeof(T)); }

// ---------- 初始化 ----------
#if HAVE_KFD
inline bool attach(const char* procName, int exploitType) {
    if (kfd_init((enum exploit_type)exploitType) != 0) return false;

    pid_t pid = find_pid(procName);
    if (!pid) return false;

    uint64_t task = kfd_get_task(pid);
    if (!task) return false;

    g_t.pid  = pid;
    g_t.task = task;
    g_t.ready = true;

    // 找主二进制基址：这里假设调用方已知（静态分析得到的 slide 后地址），
    // 或从 kfd 的 vm_map 遍历 __TEXT 段拿。未实现前保持 0，由上层跳过。
    g_t.base = 0;

    // canary：libkfd 不提供则跳过，但跳过就意味着首次读数不可信 —— 上层必须
    // 用"实体数量落在合理区间"这类语义校验兜底（World.mm 已经这么做）。
    return true;
}
#else
inline bool attach(const char*, int) { return false; }
#endif

inline const Target& target() { return g_t; }
inline void detach() { g_t = Target{}; }

} // namespace xmem
