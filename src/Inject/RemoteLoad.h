// RemoteLoad.h —— 运行时把 dylib 加载进另一个进程（形态 β 的核心）
//
// 场景：daemon 拿到 SpringBoard 的 task port，把 payload 加载进去。
// 磁盘零修改，不动任何系统文件，不重启 SpringBoard。
//
// iOS 注意：<mach/mach_vm.h> 在 iOS SDK 里被 #error 禁用，所以一律用 vm_* 系列
// （vm_allocate / vm_write / thread_*），它们在 <mach/vm_map.h> 声明，对远程 task 同样有效。
//
// 支点：libdyld 在 dyld shared cache 里，所有进程映射到同一地址。
// 所以我们进程里 dlsym(RTLD_DEFAULT, "dlopen") 得到的地址，在目标进程里照样有效。
// 这就是为什么远程调用 dlopen 不需要先在目标里找符号。
//
// 失败模式与现象：
//   task_for_pid 返回 5 (KERN_FAILURE)  → entitlement 不够 / 目标拒绝
//   vm_allocate 失败                    → task port 权限被裁剪
//   thread_resume 之后进程挂住          → 栈没对齐（arm64 要求 sp 16 字节对齐）
//   dlopen 返回 NULL                    → 目标进程读不到那个路径

#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/thread_act.h>
#include <mach/arm/thread_status.h>
#include <sys/sysctl.h>

namespace rload {

struct Ctx {
    mach_port_t  task    = MACH_PORT_NULL;
    pid_t        pid     = 0;
    vm_address_t strAddr = 0;   // 目标进程里存放 dylib 路径的地址
    vm_address_t stack   = 0;   // 远程线程栈
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
    for (size_t i = 0; i < n; i++) {
        if (strstr(p[i].kp_proc.p_comm, name)) { found = p[i].kp_proc.p_pid; break; }
    }
    free(p);
    return found;
}

// 在目标进程里分配并写入
inline bool write_remote(Ctx& c, const void* src, size_t len, vm_address_t& out) {
    vm_address_t addr = 0;
    kern_return_t kr = vm_allocate(c.task, &addr, (vm_size_t)len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return false;
    kr = vm_write(c.task, addr, (vm_offset_t)src, (mach_msg_type_number_t)len);
    if (kr != KERN_SUCCESS) return false;
    out = addr;
    return true;
}

// 远程调用一个两参函数（用来调 dlopen(path, RTLD_NOW)）
// fnAddr 用本进程地址（shared cache 保证一致）
// retTo 是返回后跳去的地址，通常给 pthread_exit，避免落回垃圾地址
inline kern_return_t call_remote(Ctx& c, uintptr_t fnAddr,
                                 uint64_t a0, uint64_t a1, uintptr_t retTo) {
    mach_port_t th = MACH_PORT_NULL;
    kern_return_t kr = thread_create(c.task, &th);
    if (kr != KERN_SUCCESS) return kr;

    arm_thread_state64_t st;
    memset(&st, 0, sizeof(st));
    st.__x[0]  = a0;
    st.__x[1]  = a1;
    st.__sp    = (uint64_t)((c.stack + 0x10000) & ~0xFull);   // 16 字节对齐
    st.__pc    = (uint64_t)fnAddr;
    st.__lr    = (uint64_t)(retTo ? retTo : 0);

    kr = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&st,
                          ARM_THREAD_STATE64_COUNT);
    if (kr != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), th);
        return kr;
    }
    return thread_resume(th);
}

// 主流程
inline bool inject(const char* procName, const char* dylibPath) {
    Ctx c;
    c.pid = find_pid(procName);
    if (!c.pid) { printf("[rload] process not found: %s\n", procName); return false; }

    kern_return_t kr = task_for_pid(mach_task_self(), c.pid, &c.task);
    printf("[rload] task_for_pid(%d) -> %d\n", c.pid, kr);
    if (kr != KERN_SUCCESS) return false;

    size_t plen = strlen(dylibPath) + 1;
    if (!write_remote(c, dylibPath, plen, c.strAddr)) {
        printf("[rload] write_remote(path) failed\n");
        return false;
    }
    if (vm_allocate(c.task, &c.stack, 0x10000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        printf("[rload] vm_allocate(stack) failed\n");
        return false;
    }

    uintptr_t dlopenAddr = (uintptr_t)dlsym(RTLD_DEFAULT, "dlopen");
    uintptr_t pthExit    = (uintptr_t)dlsym(RTLD_DEFAULT, "pthread_exit");
    if (!dlopenAddr) { printf("[rload] dlopen not found\n"); return false; }

    kr = call_remote(c, dlopenAddr, (uint64_t)c.strAddr, (uint64_t)RTLD_NOW, pthExit);
    printf("[rload] thread_resume -> %d\n", kr);
    return kr == KERN_SUCCESS;
}

inline void diagnose(int pid) {
    mach_port_t t = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &t);
    printf("[rload] pid=%d task_for_pid=%d (%s)\n", pid, kr,
           kr == KERN_SUCCESS ? "OK" : "FAILED");
    if (kr == KERN_SUCCESS) mach_port_deallocate(mach_task_self(), t);
    else printf("[rload] check entitlements: com.apple.system-task-ports / cs.debugger\n");
}

} // namespace rload
