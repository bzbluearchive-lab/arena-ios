// ManualMap.hpp —— 不经过 dyld 的 Mach-O 加载器（形态 A 的核心）
//
// 解决的问题：TrollFools / LC_LOAD_DYLIB 注入会在三个地方留下无法隐藏的痕：
//   1. 主二进制的 load commands 里多一条 LC_LOAD_DYLIB（anogs 可以读自己的头部）
//   2. app 包 PlugIns/ 目录里多一个文件（anogs 可以 stat 自己的 bundle）
//   3. dyld 的镜像表里多一项（_dyld_image_count / TASK_DYLD_INFO）
// Manual map 把这三条一起消掉：dyld 从头到尾不知道我们有这个镜像。
//
// 关键工程决定：
//   ★ payload 必须编译成 plain arm64（ARCHS = arm64），不要 arm64e。
//     理由：arm64e 的 chained fixups 是 DYLD_CHAINED_PTR_ARM64E，绑定时需要
//     ptrauth 签名，自己做等于重写一遍 dyld 的签名逻辑；plain arm64 是
//     DYLD_CHAINED_PTR_64_OFFSET，纯算术，无 PAC。arm64e 硬件上跑 arm64 代码没问题。
//   ★ 映射后端用容器内一个真实文件（ftruncate + mmap MAP_SHARED），
//     这样 proc_regionfilename() 报出来的是 app 自己容器里的路径，
//     不是"匿名可执行区"——后者是 anogs 会直接标记的一类信号。
//   ★ payload 里不要定义 ObjC 类。绕过 dyld 就没有 image 注册，
//     我们自己的类不会进 ObjC runtime。payload 保持纯 C/C++，
//     只调用 method_setImplementation 去改别人的类，这条路完全通。

#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <mach-o/loader.h>
#include <mach-o/fixup-chains.h>
#include <mach-o/nlist.h>
#include <dlfcn.h>

namespace mmap64 {

struct Mapped {
    uintptr_t base = 0;      // 映射基址（已含 slide 还原后的相对布局）
    size_t    size = 0;
    int       fd   = -1;
    bool      ok   = false;
};

// ---------------- 工具 ----------------
static inline uintptr_t page_down(uintptr_t a) { return a & ~(uintptr_t)(getpagesize() - 1); }
static inline uintptr_t page_up(uintptr_t a)   { return page_down(a + getpagesize() - 1); }

static const struct load_command* lc_find(const struct mach_header_64* mh, uint32_t cmd) {
    const uint8_t* p = (const uint8_t*)mh + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command* lc = (const struct load_command*)p;
        if (lc->cmd == cmd) return lc;
        p += lc->cmdsize;
    }
    return nullptr;
}

// ---------------- 符号解析：只走 dlsym（依赖必须已在进程里） ----------------
static uintptr_t resolve_symbol(const char* name) {
    void* p = dlsym(RTLD_DEFAULT, name);
    if (p) return (uintptr_t)p;
    // 弱符号落空是正常的（比如 __cxa_atexit 之类），返回 0 继续
    return 0;
}

// ---------------- chained fixups（iOS 15+ 现代二进制主路径） ----------------
static bool apply_chained_fixups(const struct mach_header_64* mh, uintptr_t slide, uintptr_t base) {
    const struct linkedit_data_command* lc =
        (const struct linkedit_data_command*)lc_find(mh, LC_DYLD_CHAINED_FIXUPS);
    if (!lc) return true;   // 老格式（bind opcodes）见文末说明，本骨架不覆盖

    uintptr_t fixups = base + (lc->dataoff - 0) ;   // dataoff 相对 __LINKEDIT 的偏移
    // 正确算法：从 __LINKEDIT 段的 vmaddr 推算。这里用 base + dataoff 只在
    // __LINKEDIT 紧跟文件头且 slide==0 时成立，实装时必须按 segment 换算。
    const struct dyld_chained_fixups_header* hdr =
        (const struct dyld_chained_fixups_header*)fixups;

    const uint8_t* starts = (const uint8_t*)hdr + hdr->starts_offset;
    const struct dyld_chained_starts_in_image* si =
        (const struct dyld_chained_starts_in_image*)starts;

    const uint8_t* imports_pool = (const uint8_t*)hdr + hdr->imports_offset;

    for (uint32_t seg = 0; seg < si->seg_count; seg++) {
        uint32_t off = si->seg_info_offset[seg];
        if (off == 0) continue;   // 该段无链

        const struct dyld_chained_starts_in_segment* ss =
            (const struct dyld_chained_starts_in_segment*)((const uint8_t*)si + off);

        for (uint16_t pg = 0; pg < ss->page_count; pg++) {
            uint16_t start = ss->page_start[pg];
            if (start == DYLD_CHAINED_PTR_START_NONE) continue;

            uintptr_t pageAddr = base + ss->segment_offset + (uintptr_t)pg * ss->page_size;
            uint32_t  idx = start;

            while (idx != 0xFFFF && idx < ss->page_size) {
                uintptr_t* slot = (uintptr_t*)(pageAddr + idx);

                if (ss->pointer_format == DYLD_CHAINED_PTR_64_OFFSET ||
                    ss->pointer_format == DYLD_CHAINED_PTR_64) {
                    dyld_chained_ptr_64_rebase rb;
                    dyld_chained_ptr_64_bind    bd;
                    memcpy(&rb, slot, sizeof(rb));
                    memcpy(&bd, slot, sizeof(bd));

                    if (rb.bind) {
                        char* sym = (char*)imports_pool + bd.ordinal;  // 实装需按 imports 表偏移
                        uintptr_t addr = resolve_symbol(sym);
                        uintptr_t val = addr + bd.addend;
                        memcpy(slot, &val, sizeof(val));
                        idx += bd.next;
                    } else {
                        uintptr_t val = base + rb.target;
                        memcpy(slot, &val, sizeof(val));
                        idx += rb.next;
                    }
                } else {
                    // arm64e 格式：需要 ptrauth 签名，本骨架不做，直接失败暴露
                    return false;
                }
            }
        }
    }
    return true;
}

// ---------------- 主流程 ----------------
// backendPath: 容器内一个可写路径，用于给映射做 file-backed 后端
// entryName:   想调用的导出符号（可以是 "mod_init" 之类）
inline bool map(const char* dylibPath, const char* backendPath, const char* entryName,
                Mapped& out, void** entryFn) {
    if (entryFn) *entryFn = nullptr;

    int fd = open(dylibPath, O_RDONLY);
    if (fd < 0) return false;
    struct stat st{};
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) { close(fd); return false; }

    uint8_t* file = (uint8_t*)mmap(nullptr, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (file == MAP_FAILED) { close(fd); return false; }

    const struct mach_header_64* mh = (const struct mach_header_64*)file;
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM) {
        // CPU_TYPE_ARM 在 64 位下是 CPU_TYPE_ARM|CPU_ARCH_ABI64 = 0x0100000C
        if (!(mh->magic == MH_MAGIC_64 && (mh->cputype & 0x00FFFFFF) == CPU_TYPE_ARM)) {
            munmap(file, (size_t)st.st_size); close(fd); return false;
        }
    }

    // 1) 算总跨度
    uintptr_t lo = UINTPTR_MAX, hi = 0;
    const uint8_t* p = file + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command* lc = (const struct load_command*)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* s = (const struct segment_command_64*)lc;
            if (s->vmsize == 0) { p += lc->cmdsize; continue; }
            lo = (s->vmaddr < lo) ? (uintptr_t)s->vmaddr : lo;
            hi = (s->vmaddr + s->vmsize > hi) ? (uintptr_t)(s->vmaddr + s->vmsize) : hi;
        }
        p += lc->cmdsize;
    }
    if (lo >= hi) { munmap(file, (size_t)st.st_size); close(fd); return false; }

    size_t span = page_up(hi - lo);

    // 2) file-backed 后端（让 proc_regionfilename 报出容器内路径）
    int bfd = open(backendPath, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (bfd < 0) { munmap(file, (size_t)st.st_size); close(fd); return false; }
    if (ftruncate(bfd, (off_t)span) != 0) {
        close(bfd); munmap(file, (size_t)st.st_size); close(fd); return false;
    }
    void* baseMem = mmap(nullptr, span, PROT_READ | PROT_WRITE, MAP_SHARED, bfd, 0);
    if (baseMem == MAP_FAILED) {
        close(bfd); munmap(file, (size_t)st.st_size); close(fd); return false;
    }
    uintptr_t base = (uintptr_t)baseMem - lo;   // 使 base + vmaddr 指向真实地址

    // 3) 按段拷贝
    p = file + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command* lc = (const struct load_command*)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* s = (const struct segment_command_64*)lc;
            if (s->filesize && s->vmsize) {
                memcpy((void*)(base + s->vmaddr), file + s->fileoff, (size_t)s->filesize);
            }
        }
        p += lc->cmdsize;
    }

    // 4) 重定位 + 绑定
    bool fixed = apply_chained_fixups(mh, 0, base);
    // 注意：slide 传 0，因为我们是自定义基址，不需要 dyld 的 slide 语义

    // 5) 段权限
    p = file + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command* lc = (const struct load_command*)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* s = (const struct segment_command_64*)lc;
            if (s->initprot & VM_PROT_EXECUTE) {
                mprotect((void*)page_down(base + s->vmaddr), page_up(s->vmsize),
                         PROT_READ | PROT_EXEC);
            }
        }
        p += lc->cmdsize;
    }

    // 6) 跑 __mod_init_func
    const struct segment_command_64* data = nullptr;
    p = file + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command* lc = (const struct load_command*)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* s = (const struct segment_command_64*)lc;
            if (strcmp(s->segname, "__DATA") == 0) { data = s; break; }
        }
        p += lc->cmdsize;
    }
    (void)data;

    // 7) 导出入口
    if (entryName && entryFn) {
        const struct symtab_command* sym = (const struct symtab_command*)lc_find(mh, LC_SYMTAB);
        if (sym) {
            const struct nlist_64* nl = (const struct nlist_64*)(file + sym->symoff);
            const char* strs = (const char*)(file + sym->stroff);
            for (uint32_t i = 0; i < sym->nsyms; i++) {
                if (nl[i].n_un.n_strx == 0) continue;
                const char* nm = strs + nl[i].n_un.n_strx;
                if (nm[0] == '_') nm++;
                if (strcmp(nm, entryName) == 0) {
                    *entryFn = (void*)(base + nl[i].n_value);
                    break;
                }
            }
        }
    }

    munmap(file, (size_t)st.st_size);
    close(fd);

    out.base = base;
    out.size = span;
    out.fd   = bfd;
    out.ok   = fixed;
    return fixed;
}

} // namespace mmap64

// ============================================================================
// 未覆盖 / 未验证（实装前必须补齐）：
//   1. LC_DYLD_INFO_ONLY 的 bind opcodes 老格式（iOS 13 前的 dylib 才需要，
//      我们自己的 dylib 用新格式即可）
//   2. imports 表的正确偏移换算：hdr->imports_offset + import_offset，
//      本骨架里用 imports_pool + ordinal 是简化写法，实装必须按
//      dyld_chained_import 结构取 name_offset
//   3. __mod_init_func 的遍历（应当读 __DATA 段中 mod_init_func 对应的
//      section，逐个函数指针调用）
//   4. __LINKEDIT 的 dataoff 换算（必须从 segment 的 fileoff/vmaddr 差值算，
//      不能像我这里直接用 base + dataoff）
//   5. arm64e 的 DYLD_CHAINED_PTR_ARM64E：本骨架直接返回失败，
//      payload 编译成 plain arm64 即可完全规避
//   6. mprotect 之后必须 sys_icache_invalidate 对应范围
// ============================================================================
