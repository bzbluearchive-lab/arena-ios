// XTaskPort.h —— 基于 task port 的跨进程读（无需内核原语）
//
// 前提：调用方进程持有 com.apple.private.cs.debugger / task_for_pid-allow 这类
// entitlement，且 TrollStore 的 CoreTrust 让这些 entitlement 在用户态检查层面生效。
// 是否成立必须先跑 Docs/OVERLAY_HOST.md 里的实验 A。
//
// 通了的话，这条路径比 kfd 好一个数量级：
//   - 不需要内核 exploit
//   - 出错只影响自己，返回 KERN_INVALID_ADDRESS
//   - 没有 panic 面
//
// 与 SafeMem.h / XRead.h 完全同语义，上层 World/Aim 一行不改。

#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/sysctl.h>
#include "SafeMem.h"

namespace tmem {

struct Target {
    mach_port_t task = MACH_PORT_NULL;
    pid_t       pid  = 0;
    uint64_t    base = 0;      // 主二进制基址，用于 canary
    bool        ready = false;
};

static Target g_t;

// ---------------- 进程查找 ----------------
inline pid_t find_pid(const char* needle) {
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
        if (nm && strstr(nm, needle)) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

// ---------------- 附身 ----------------
// 返回 kern_return_t，方便在实验阶段把错误码直接打出来
inline kern_return_t attach(pid_t pid) {
    if (g_t.task != MACH_PORT_NULL) detach();
    mach_port_t t = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &t);
    if (kr != KERN_SUCCESS) return kr;
    g_t.task = t;
    g_t.pid  = pid;
    g_t.ready = true;
    return KERN_SUCCESS;
}

inline void detach() {
    if (g_t.task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), g_t.task);
    g_t = Target{};
}

// ---------------- canary ----------------
// 任何读数采信前，先确认目标基址上确实是 arm64 mach-o
inline bool canary_ok(uint64_t addr) {
    uint32_t magic = 0;
    if (!tmem::read(addr, &magic, 4)) return false;
    if (magic != 0xFEEDFACF) return false;
    uint32_t cpu = 0;
    if (!tmem::read(addr + 4, &cpu, 4)) return false;
    return (cpu & 0x00FFFFFF) == 12;     // CPU_TYPE_ARM
}

// ---------------- 读 ----------------
inline bool read(uint64_t addr, void* out, size_t n) {
    if (addr == 0 || out == nullptr || n == 0) return false;

    if (!g_t.ready || g_t.pid == getpid())
        return mem::read((uintptr_t)addr, out, n);

    mach_vm_address_t src = (mach_vm_address_t)addr;
    mach_vm_size_t    got = 0;
    kern_return_t kr = mach_vm_read_overwrite(g_t.task, src, (mach_vm_size_t)n,
                                              (mach_vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == (mach_vm_size_t)n;
}

inline uint64_t rdptr(uint64_t addr) {
    uint64_t v = 0;
    return read(addr, &v, sizeof(v)) ? v : 0;
}

template <typename T>
inline bool rd(uint64_t addr, T& out) { return read(addr, &out, sizeof(T)); }

// 跨进程写（自瞄要用；只读方案不用，留着标注清楚风险）
inline bool write(uint64_t addr, const void* in, size_t n) {
    if (!g_t.ready || g_t.pid == getpid()) return false;
    // 先确认目标可读，避免把数据写到不可读页
    char probe[8];
    if (!read(addr, probe, n < sizeof(probe) ? n : sizeof(probe))) return false;
    mach_vm_size_t done = 0;
    kern_return_t kr = mach_vm_write(g_t.task, (mach_vm_address_t)addr,
                                     (vm_offset_t)in, (mach_msg_type_number_t)n);
    (void)done;
    return kr == KERN_SUCCESS;
}

inline const Target& target() { return g_t; }

// ---------------- 实验 A 的自检 ----------------
// 直接打印结论，方便第一步就判定这条路通不通
inline void selftest(pid_t targetPid) {
    kern_return_t kr = attach(targetPid);
    printf("[tmem] task_for_pid(%d) kr=%d (%s)\n", targetPid, kr,
           kr == KERN_SUCCESS ? "KERN_SUCCESS" : "FAILED");
    if (kr != KERN_SUCCESS) {
        printf("[tmem] 这条路不通，退回 kfd（XRead.h）。"
               "先确认 entitlements 里 com.apple.private.cs.debugger 存在。\n");
        return;
    }
    // 扫一下基址附近找 mach-o 魔数，确认读路径真的通
    uint32_t magic = 0;
    uint64_t probe = 0x100000000ULL;
    if (read(probe, &magic, 4))
        printf("[tmem] read @0x%llx -> 0x%08x\n", probe, magic);
    else
        printf("[tmem] read @0x%llx 失败\n", probe);
}

} // namespace tmem
