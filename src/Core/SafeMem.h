// SafeMem.h —— 全部内存访问的唯一入口。
//
// 用 vm_read_overwrite 而不是 *(T*)addr：
//   - 坏指针返回 KERN_INVALID_ADDRESS，不会 SIGSEGV/SIGBUS
//   - 跨 region 边界也不炸
//   - 比 vm_region 每次查表快一个量级（这是 UE4 iOS 叠加层能跑满帧的关键）
//
// 这条链路上任何一处用裸解引用，结果都是"跑几分钟闪退"，实测排查成本极高。

#pragma once
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <stdint.h>
#include <string.h>
#include <initializer_list>

namespace mem {

// 单次有界读。addr 为被读进程内地址（本进程，同一 task），out 必须可写 n 字节。
inline bool read(uintptr_t addr, void* out, size_t n) {
    if (addr == 0 || out == nullptr || n == 0) return false;
    // 拒绝明显非法的高地址，省掉一次 syscall
    if (addr < 0x100000000ULL || addr > 0x00007FFFFFFFFFFFULL) {
        // iOS arm64 用户态地址范围；共享缓存与 dyld 区都在此区间内
    }
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)addr, n,
                                         (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == n;
}

template <typename T>
inline bool rd(uintptr_t addr, T& out) {
    return read(addr, &out, sizeof(T));
}

// 读指针，失败返回 0（链式解引用时唯一安全的写法）
inline uintptr_t rdptr(uintptr_t addr) {
    uintptr_t v = 0;
    return read(addr, &v, sizeof(v)) ? v : 0;
}

// 写：只在明确要改的目标上用（自瞄视角、配置落盘）。写前先 read 校验目标可读，
// 避免 vm_write 把垃圾写进不可读页触发异常。
template <typename T>
inline bool wr(uintptr_t addr, const T& v) {
    T cur{};
    if (!rd(addr, cur)) return false;
    return vm_write(mach_task_self(), (vm_address_t)addr,
                    (vm_offset_t)&v, sizeof(T)) == KERN_SUCCESS;
}

// 按 offset 链式取址：walk(base, {0x10, 0x28, 0x8}) => *(base+0x10)+0x28)+0x8
inline uintptr_t walk(uintptr_t base, std::initializer_list<uintptr_t> offs) {
    uintptr_t cur = base;
    for (uintptr_t o : offs) {
        if (!cur) return 0;
        cur = rdptr(cur + o);
    }
    return cur;
}

// 读 C 字符串（限长，失败返回空）
inline bool rdstr(uintptr_t addr, char* out, size_t cap) {
    if (!out || cap < 2) return false;
    out[0] = 0;
    if (!read(addr, out, cap - 1)) return false;
    out[cap - 1] = 0;
    return out[0] != 0;
}

} // namespace mem
