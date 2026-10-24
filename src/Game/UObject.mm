#include "UObject.hpp"
#include "Offsets.hpp"
#include "../Core/SafeMem.h"
#include <mach-o/dyld.h>
#include <string.h>
#include <stdio.h>
#include <string>

// Offsets.hpp 里 extern 声明的三个全局，定义放这里（全工程唯一一处定义）。
// 注意命名空间：Offsets.hpp 里是 **全局** namespace off，不是 ue::off。
namespace off {
uintptr_t GEngine = 0;
uintptr_t GNames  = 0;
uintptr_t GWorld  = 0;
}

namespace ue {
namespace fname {

static uintptr_t g_pool = 0;
static uint32_t  g_stride = 2;

// ---- entry 解析 ----
// FNameEntryHeader(uint16)：bit0 = bIsWide，其余 15 位 = Len（含结尾 0，单位为字符）
static bool entry_at(uintptr_t pool, uint32_t idx, char* out, size_t cap) {
    if (!pool || !out || cap < 2) return false;
    if ((idx >> 16) >= 8192) return false;

    uintptr_t block = mem::rdptr(pool + 0x10 + (uintptr_t)(idx >> 16) * sizeof(uintptr_t));
    if (!block) return false;

    uintptr_t entry = block + (uintptr_t)g_stride * (uintptr_t)(idx & 0xFFFF);
    uint16_t header = 0;
    if (!mem::rd(entry, header)) return false;

    const bool wide = (header & 1) != 0;
    const uint32_t len = (uint32_t)(header >> 1);
    if (len == 0 || len > 1024) return false;

    if (wide) {
        // UTF-16 -> ASCII 粗转换：绝大多数 UE 类名都是 ASCII
        uint32_t n = len < (cap - 1) ? len : (uint32_t)(cap - 1);
        for (uint32_t i = 0; i < n; i++) {
            uint16_t ch = 0;
            if (!mem::read(entry + 2 + (uintptr_t)i * 2, &ch, 2)) { out[i] = 0; return i > 0; }
            out[i] = (ch < 0x80) ? (char)ch : '?';
        }
        out[n] = 0;
        return true;
    }

    uint32_t n = len < (cap - 1) ? len : (uint32_t)(cap - 1);
    if (!mem::read(entry + 2, out, n)) return false;
    out[n] = 0;
    return true;
}

void set_base(uintptr_t pool, uint32_t stride) {
    g_pool = pool;
    g_stride = stride ? stride : 2;
    // 用一个已知索引验证 stride 选得对不对，不对就换另一个
    char buf[64];
    if (!entry_at(g_pool, 0, buf, sizeof(buf)) || strcmp(buf, "None") != 0) {
        uint32_t alt = (g_stride == 2) ? 4 : 2;
        if (entry_at(g_pool, 0, buf, sizeof(buf)) && strcmp(buf, "None") == 0) g_stride = alt;
    }
}

bool ready() { return g_pool != 0; }

bool get(uint32_t idx, char* out, size_t cap) {
    // 高位可能是比较方式标记，取低 32 位已经覆盖；这里再挡掉明显越界
    return entry_at(g_pool, idx, out, cap);
}

std::string get_str(uint32_t idx) {
    char buf[256];
    return get(idx, buf, sizeof(buf)) ? std::string(buf) : std::string();
}

// ---- 自动定位 ----
// 扫 __DATA / __DATA_CONST：候选是"指向 FNamePool 的指针"，
// 判定标准 = *(候选+0x10) 指向的 entry 0 解出 "None"。
uintptr_t locate() {
    if (g_pool) return g_pool;

    const struct mach_header_64* hdr =
        (const struct mach_header_64*)_dyld_get_image_header(0);
    if (!hdr) return 0;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);

    const struct load_command* lc =
        (const struct load_command*)((const uint8_t*)hdr + sizeof(*hdr));
    uint32_t strides[2] = {2, 4};

    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* seg = (const struct segment_command_64*)lc;
            if (strcmp(seg->segname, "__DATA") == 0 ||
                strcmp(seg->segname, "__DATA_CONST") == 0) {
                uintptr_t start = seg->vmaddr + slide;
                uintptr_t end = start + seg->vmsize;
                for (uintptr_t a = start; a + 8 <= end; a += 8) {
                    uintptr_t cand = mem::rdptr(a);
                    if (cand < 0x100000000ULL || cand > 0x00007FFFFFFFFFFFULL) continue;
                    uintptr_t block0 = mem::rdptr(cand + 0x10);
                    if (!block0) continue;
                    for (int k = 0; k < 2; k++) {
                        uint32_t saved = g_stride;
                        g_stride = strides[k];
                        char buf[16];
                        bool ok = entry_at(cand, 0, buf, sizeof(buf)) && strcmp(buf, "None") == 0;
                        if (ok) {
                            g_pool = cand;
                            return g_pool;
                        }
                        g_stride = saved;
                    }
                }
            }
        }
        lc = (const struct load_command*)((const uint8_t*)lc + lc->cmdsize);
    }
    return 0;
}

void self_check(void (*log)(const char*)) {
    if (!log) return;
    char line[128];
    char buf[64];
    snprintf(line, sizeof(line), "FNamePool=0x%lx stride=%u", (unsigned long)g_pool, g_stride);
    log(line);
    for (uint32_t i = 0; i < 8; i++) {
        if (get(i, buf, sizeof(buf))) snprintf(line, sizeof(line), "  [%u] %s", i, buf);
        else snprintf(line, sizeof(line), "  [%u] <fail>", i);
        log(line);
    }
}

} // namespace fname

namespace uobj {

bool name_of(uintptr_t obj, char* out, size_t cap) {
    if (!obj || !out || cap < 2) return false;
    uint32_t idx = 0;
    if (!mem::rd(obj + OFF_NAME, idx)) return false;
    return fname::get(idx, out, cap);
}

bool class_of(uintptr_t obj, char* out, size_t cap) {
    if (!obj) return false;
    uintptr_t cls = mem::rdptr(obj + OFF_CLASS);
    if (!cls) return false;
    return name_of(cls, out, cap);
}

uintptr_t outer_of(uintptr_t obj) {
    if (!obj) return 0;
    return mem::rdptr(obj + OFF_OUTER);
}

} // namespace uobj
} // namespace ue
