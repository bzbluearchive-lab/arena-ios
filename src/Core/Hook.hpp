// Hook.hpp —— 自带 hook 引擎（不依赖 substrate / Dobby）
//
// 为什么自己写：TrollStore 注入的 dylib 里没有 CydiaSubstrate；Dobby 在 arm64e
// 上对带 PAC 的指针会踩坑。这里只做三件事，每一件都对应一个已知会崩的陷阱：
//   Trap1 W^X      -> vm_protect 必须带 VM_PROT_COPY
//   Trap2 relocation -> 前 4 条指令只要含 PC 相对指令就拒绝安装
//   Trap3 icache   -> 打完补丁对补丁点与 trampoline 都 flush
//   Trap4 PAC      -> 只在 cpusubtype==2 时才走 ptrauth 分支（本工程默认 arm64 slice）
//
// 优先顺序（避免 inline hook，命中率从高到低）：
//   1. ObjC 方法交换 swizzle_class_method()   —— CAMetalLayer/CAMetalDrawable 全是 ObjC
//   2. vtable 槽替换  swap_vtable_slot()      —— UE4 的 virtual（UObject 一堆）
//   3. inline hook    install_inline()        —— 最后手段

#pragma once
#include <stdint.h>
#include <string.h>
#include <objc/runtime.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>

namespace hook {

// ---------------- Trap1: 页权限 ----------------
inline bool protect(uintptr_t addr, size_t len, vm_prot_t prot) {
    vm_address_t page = addr & ~(uintptr_t)(vm_page_size - 1);
    size_t off = addr - page;
    return vm_protect(mach_task_self(), page, off + len, false, prot) == KERN_SUCCESS;
}

// ---------------- Trap2: 前 4 条指令是否可搬 ----------------
inline bool prologue_copyable(uintptr_t a) {
    for (int i = 0; i < 4; i++) {
        uint32_t w = 0;
        memcpy(&w, (void*)(a + i * 4), 4);
        if ((w & 0x9F000000) == 0x90000000) return false; // ADRP
        if ((w & 0x9F000000) == 0x10000000) return false; // ADR
        if ((w & 0x7C000000) == 0x14000000) return false; // B / BL
        if ((w & 0x7E000000) == 0x34000000) return false; // CBZ / CBNZ
        if ((w & 0x7E000000) == 0x36000000) return false; // TBZ / TBNZ
        if ((w & 0xFF000000) == 0x54000000) return false; // B.cond
        if ((w & 0x3B000000) == 0x18000000) return false; // LDR (literal)
    }
    return true;
}

// 16 字节绝对跳转：LDR X17,#8 ; BR X17 ; .quad target
inline void emit_abs_jump(uint32_t* p, uintptr_t target) {
    p[0] = 0x58000051;  // ldr x17, #8
    p[1] = 0xD61F0220;  // br  x17
    ((uintptr_t*)p)[1] = target;
}

// ---------------- Trap3: icache ----------------
inline void flush(uintptr_t addr, size_t len) {
    sys_icache_invalidate((void*)addr, len);
}

// ================= 用法 1：ObjC 方法交换（本工程主力） =================
// 不需要 substrate。返回原 IMP，调用它即执行原实现。
inline IMP swizzle_class_method(const char* cls, SEL sel, IMP newImp) {
    Class c = objc_getClass(cls);
    if (!c) return nullptr;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return nullptr;
    IMP old = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return old;
}

// ================= 用法 2：vtable 槽替换 =================
// ueObj 为对象地址，vtableOff 一般 0x00（UE4 UObject vtable 在偏移 0）。
inline bool swap_vtable_slot(uintptr_t ueObj, int idx, void* fn, void** outOld) {
    uintptr_t vt = 0;
    if (!ueObj) return false;
    memcpy(&vt, (void*)ueObj, sizeof(vt));      // 取 vtable
    if (!vt) return false;
    uintptr_t slot = vt + idx * sizeof(void*);
    void* old = nullptr;
    memcpy(&old, (void*)slot, sizeof(old));
    if (!old) return false;
    if (!protect(slot, sizeof(void*), VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY))
        return false;
    memcpy((void*)slot, &fn, sizeof(fn));
    protect(slot, sizeof(void*), VM_PROT_READ);
    if (outOld) *outOld = old;
    return true;
}

// ================= 用法 3：inline hook（最后手段） =================
struct InlineHook {
    uintptr_t target = 0;
    void*     trampoline = nullptr;
    uint32_t  orig[4] = {0};
};

// 已安装 hook 的登记表（供卸载与一致性检查），上限 64 条足够
struct Registry { InlineHook slots[64]; int n = 0; };
inline Registry& registry() { static Registry r; return r; }

// 安装 inline hook。成功后 orig 指向 trampoline，调用 orig 等于调原函数。
// keep 里保存原始 4 条指令，卸载时用它复原。
inline bool install_inline(uintptr_t target, void* hookFn, InlineHook& out) {
    if (!target || !hookFn) return false;
    if (!prologue_copyable(target)) return false;   // Trap2：脏序言直接放弃

    // 1) trampoline = 4 条原指令 + 回跳
    size_t tsize = 64;
    void* tramp = mmap(nullptr, tsize, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
    if (tramp == MAP_FAILED) return false;

    for (int i = 0; i < 4; i++) memcpy(&out.orig[i], (void*)(target + i * 4), 4);
    memcpy(tramp, (void*)target, 16);
    emit_abs_jump((uint32_t*)((uintptr_t)tramp + 16), target + 16);

    if (!vm_protect(mach_task_self(), (vm_address_t)tramp, tsize, false,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)) {
        munmap(tramp, tsize);
        return false;
    }
    flush((uintptr_t)tramp, tsize);                  // Trap3

    // 2) 打补丁到目标
    uint32_t patch[4] = {0};
    emit_abs_jump(patch, (uintptr_t)hookFn);

    if (!protect(target, 16, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) {  // Trap1
        munmap(tramp, tsize);
        return false;
    }
    memcpy((void*)target, patch, 16);
    protect(target, 16, VM_PROT_READ | VM_PROT_EXECUTE);
    flush(target, 16);                               // Trap3

    out.target = target;
    out.trampoline = tramp;
    return true;
}

// 便捷重载：不关心 trampoline 结构时用这个，orig 直接拿到"调原函数"的入口。
// 失败时 *orig 保持 nullptr —— 调用方必须判空，否则会跳到空地址。
inline bool install_inline(uintptr_t target, void* hookFn, void** orig) {
    Registry& r = registry();
    if (r.n >= 64) return false;
    InlineHook& slot = r.slots[r.n];
    if (!install_inline(target, hookFn, slot)) return false;
    r.n++;
    if (orig) *orig = slot.trampoline;
    return true;
}

inline void uninstall_inline(InlineHook& h) {
    if (!h.target) return;
    if (protect(h.target, 16, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) {
        memcpy((void*)h.target, h.orig, 16);
        protect(h.target, 16, VM_PROT_READ | VM_PROT_EXECUTE);
        flush(h.target, 16);
    }
    if (h.trampoline) munmap(h.trampoline, 64);
    h.target = 0;
    h.trampoline = nullptr;
}

} // namespace hook
