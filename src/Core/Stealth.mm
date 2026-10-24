#include "Stealth.hpp"
#include "../Core/Hook.hpp"
#include <mach-o/dyld.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>

namespace stealth {

static Options g_opt;
static uint32_t g_self_index = UINT32_MAX;
static const char* kLogPath = nullptr;   // 由 Tweak.x 注入容器内 tmp 路径

// ---------------- PT_DENY_ATTACH ----------------
// iPhoneOS SDK 里没有 <sys/ptrace.h>（macOS 有，iOS 没有），所以自定义常量与声明。
// 直接 ptrace 会在部分构建上被 anogs 的反调试反向探测到，因此只在 opt 打开时调用。
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
extern "C" int ptrace(int request, pid_t pid, caddr_t addr, int data);

static void do_deny_attach() {
    ptrace(PT_DENY_ATTACH, 0, nullptr, 0);
}

// ---------------- P_TRACED ----------------
static int (*orig_sysctl)(int*, u_int, void*, size_t*, void*, size_t);

static int hk_sysctl(int* name, u_int namelen, void* oldp, size_t* oldlenp,
                     void* newp, size_t newlen) {
    int r = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (r == 0 && oldp && name && namelen == 4 && name[0] == CTL_KERN &&
        name[1] == KERN_PROC && name[2] == KERN_PROC_PID && oldlenp) {
        // struct kinfo_proc: kp_proc.p_flag 位于偏移 32（arm64）
        if (*oldlenp >= 40) {
            uint32_t* flag = (uint32_t*)((uint8_t*)oldp + 32);
            *flag &= ~0x00000800;   // P_TRACED
        }
    }
    return r;
}

// ---------------- TrollStore 痕迹 ----------------
// 只拦"文件存在性/打开"这一类探测，返回 ENOENT。不做全局 hook。
static const char* kSTPaths[] = {
    // TrollStore
    "/var/containers/Bundle/trollstore",
    "/var/containers/Bundle/Application/.trollstore",
    "/var/mobile/Library/Preferences/com.opa334.TrollStore.plist",
    // roothide Bootstrap（全系统注入环境）—— anogs 明确在找这一套
    "/var/containers/Bundle/tweaksupport",
    // Dopamine / rootless 越狱痕迹
    "/var/jb",
    // 包管理器
    "/var/lib/dpkg",
    "/Applications/Sileo.app",
    "/Applications/Zebra.app",
};
static const int kSTCount = sizeof(kSTPaths) / sizeof(kSTPaths[0]);

static FILE* (*orig_fopen)(const char*, const char*);
static FILE* hk_fopen(const char* path, const char* mode) {
    if (path) for (int i = 0; i < kSTCount; i++)
        if (strstr(path, kSTPaths[i])) { errno = ENOENT; return nullptr; }
    return orig_fopen(path, mode);
}

static int (*orig_access)(const char*, int);
static int hk_access(const char* path, int mode) {
    if (path) for (int i = 0; i < kSTCount; i++)
        if (strstr(path, kSTPaths[i])) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

// ---------------- dyld 视图（默认关闭） ----------------
// 开启时必须四件套同时一致，否则 count 与 name 对不上，比不隐藏更显眼。
static uint32_t (*orig_img_count)(void);
static const char* (*orig_img_name)(uint32_t);
static uint32_t hk_img_count(void) {
    uint32_t n = orig_img_count();
    return (g_self_index != UINT32_MAX && n > 0) ? n - 1 : n;
}
static const char* hk_img_name(uint32_t i) {
    if (g_self_index != UINT32_MAX) {
        uint32_t total = orig_img_count();
        if (i >= g_self_index && i + 1 < total) return orig_img_name(i + 1);
        if (i >= g_self_index) return orig_img_name(total ? total - 1 : 0);
    }
    return orig_img_name(i);
}

// ---------------- 入口 ----------------
void install(const Options& opt) {
    g_opt = opt;

    // 记录自己在 dyld 表中的位置（诊断 + 可选的视图过滤）
    uint32_t n = _dyld_image_count();
    const char* self = _dyld_get_image_name(0);
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "ARCheat.dylib")) { g_self_index = i; self = nm; break; }
    }
    (void)self;

    if (opt.deny_ptrace)  do_deny_attach();

    // 注意：只 hook libc 的 sysctl/fopen/access 这些"库里"的入口，绝不碰 anogs
    // 自己 __text 里的任何字节（它自校验）。all-libc 入口的 patch 属于本 app 进程内的
    // 普通调用重定向，anogs 的校验范围不覆盖它。

    if (opt.clear_p_traced) {
        void* p = dlsym(RTLD_DEFAULT, "sysctl");
        if (p && hook::install_inline((uintptr_t)p, (void*)hk_sysctl, (void**)&orig_sysctl))
            ; // 成功
    }

    if (opt.hide_trollstore) {
        void* pf = dlsym(RTLD_DEFAULT, "fopen");
        void* pa = dlsym(RTLD_DEFAULT, "access");
        if (pf) hook::install_inline((uintptr_t)pf, (void*)hk_fopen, (void**)&orig_fopen);
        if (pa) hook::install_inline((uintptr_t)pa, (void*)hk_access, (void**)&orig_access);
    }

    if (opt.filter_dyld_view) {
        void* pc = dlsym(RTLD_DEFAULT, "_dyld_image_count");
        void* pn = dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
        if (pc) hook::install_inline((uintptr_t)pc, (void*)hk_img_count, (void**)&orig_img_count);
        if (pn) hook::install_inline((uintptr_t)pn, (void*)hk_img_name, (void**)&orig_img_name);
    }

    if (opt.scrub_env) {
        unsetenv("DYLD_INSERT_LIBRARIES");
        unsetenv("DYLD_FORCE_FLAT_NAMESPACE");
        unsetenv("DYLD_PRINT_LIBRARIES");
    }
}

void dump_self_info() {
    if (!kLogPath) return;
    FILE* f = orig_fopen ? orig_fopen(kLogPath, "a") : fopen(kLogPath, "a");
    if (!f) return;
    uint32_t n = _dyld_image_count();
    fprintf(f, "[stealth] images=%u self_index=%u\n", n, g_self_index);
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (nm) fprintf(f, "  [%u] %s\n", i, nm);
    }
    fclose(f);
}

} // namespace stealth
