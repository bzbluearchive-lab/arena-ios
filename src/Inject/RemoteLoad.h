// RemoteLoad.h —— 运行时把 dylib 加载进另一个进程（形态 β 的核心）
//
// 场景：daemon 拿到 SpringBoard 的 task port，把 payload 加载进去。
// 磁盘零修改，不动任何系统文件，不重启 SpringBoard。
//
// 支点：libdyld 在 dyld shared cache 里，所有进程映射到同一地址。
// 所以我们进程里 dlsym(RTLD_DEFAULT, "dlopen") 得到的地址，在目标进程里照样有效。
// 这就是为什么远程调用 dlopen 不需要先在目标里找符号。
//
// 失败模式与现象：
//   task_for_pid 返回 5 (KERN_FAILURE)  → entitlement 不够 / 目标拒绝
//   vm_allocate 失败                    → task port 是"只读"权限位（task_for_pid 给的 port
//                                          通常带全部权限，但个别版本会裁剪）
//   thread_create_running 后进程挂住    → 栈没对齐（arm64 要求 sp 16 字节对齐）
//   dlopen 返回 NULL                    → 目标进程读不到那个路径（沙盒/权限）

#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/thread_act.h>
#include <mach/arm/thread_status.h>
#include <sys/sysctl.h>

namespace rload {

struct Ctx {
    mach_port_t   task = MACH_PORT_NULL;
    pid_t         pid  = 0;
    mach_vm_address_t strAddr = 0;   // 目标里存放 dylib 路径的地址
    mach_vm_address_t stack   = 0;   // 远程线程栈
};

inline pid_t find_pid(const char* name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, nullptr, &sz, nullptr, 0) != 0 || !sz) return 0;
    struct kinfo_proc* p = (struct kinfo_proc*)malloc(sz);
    if (!p) return 0;
    if (sysctl(mib, 4, p, &sz, nullptr, 0) != 0) { free(p); return 0; }
    pid_t found = 0;
    size_t n = sz / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < n; i++)
        if (strstr(p[i].kp_proc.p_comm, name)) { found = p[i].kp_proc.p_pid; break; }
    free(p);
    return found;
}

// ---------------- 在目标进程里分配并写入 ----------------
inline bool write_remote(Ctx& c, const void* src, size_t len, mach_vm_address_t& out) {
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(c.task, &addr, len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return false;
    mach_vm_size_t done = 0;
    kr = mach_vm_write(c.task, addr, (vm_offset_t)src, (mach_msg_type_number_t)len);
    if (kr != KERN_SUCCESS) return false;
    (void)done;
    out = addr;
    return true;
}

// ---------------- 远程调用一个无参/少参函数 ----------------
// fnAddr 用本进程的地址（shared cache 保证一致）
inline kern_return_t call_remote(Ctx& c, uintptr_t fnAddr,
                                 uint64_t a0, uint64_t a1,
                                 uintptr_t retTo /*通常设为 pthread_exit*/) {
    arm_thread_state64_t st{};
    memset(&st, 0, sizeof(st));

    st.__x[0] = a0;
    st.__x[1] = a1;
    // 栈顶 16 字节对齐（arm64 硬要求，错了必然挂）
    st.__sp   = (c.stack + 0x4000) & ~0xFull;
    st.__pc   = fnAddr;
    st.__lr   = retTo ? retTo : 0;   // 返回后跳到这里，避免落回垃圾地址

    mach_port_t th = MACH_PORT_NULL;
    kern_return_t kr = thread_create(c.task, &th);
    if (kr != KERN_SUCCESS) return kr;

    arm_thread_state64_t state = st;
    kr = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&state,
                          ARM_THREAD_STATE64_COUNT);
    if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), th); return kr; }

    return thread_resume(th);
}

// ---------------- 主流程 ----------------
// dylibPath: 目标进程需要能读到的路径（未沙盒进程可读容器，所以放自己容器 Documents/）
inline bool inject(const char* procName, const char* dylibPath) {
    Ctx c;
    c.pid = find_pid(procName);
    if (!c.pid) { printf("[rload] 找不到进程 %s\n", procName); return false; }

    kern_return_t kr = task_for_pid(mach_task_self(), c.pid, &c.task);
    printf("[rload] task_for_pid(%d) -> %d\n", c.pid, kr);
    if (kr != KERN_SUCCESS) return false;

    // 路径写进目标
    size_t plen = strlen(dylibPath) + 1;
    if (!write_remote(c, dylibPath, plen, c.strAddr)) return false;

    // 栈
    if (mach_vm_allocate(c.task, &c.stack, 0x8000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return false;

    // shared cache 地址一致：直接用自己这边的 dlopen / pthread_exit
    uintptr_t dlopenAddr = (uintptr_t)dlsym(RTLD_DEFAULT, "dlopen");
    uintptr_t pthExit    = (uintptr_t)dlsym(RTLD_DEFAULT, "pthread_exit");
    if (!dlopenAddr) return false;

    // dlopen(path, RTLD_NOW)
    kr = call_remote(c, dlopenAddr, (uint64_t)c.strAddr, (uint64_t)RTLD_NOW, pthExit);
    printf("[rload] thread_resume -> %d\n", kr);
    return kr == KERN_SUCCESS;
}

// ---------------- 诊断 ----------------
inline void diagnose(int pid) {
    mach_port_t t = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &t);
    printf("[rload] pid=%d task_for_pid=%d (%s)\n", pid, kr,
           kr == KERN_SUCCESS ? "OK" : "FAILED");
    if (kr != KERN_SUCCESS)
        printf("[rload] 检查 entitlement：com.apple.system-task-ports / "
               "platform-application / com.apple.private.cs.debugger\n");
}

} // namespace rload
