// Tweak.x —— 入口（全系统注入形态）
//
// 与 per-app 注入（PlugIns 静态加载）的区别，在这份代码里体现为三件事：
//   1. 可能被载入任意进程（SpringBoard / backboardd / 别的 app）——第一件事是判定
//      自己是不是目标进程，不是就立刻返回，一个 hook 都不装、一个字都不写
//   2. 加载时机可能早于 UIKit / 早于引擎初始化 —— 保留退避重试
//   3. 日志与开关不能假设自己一定在游戏进程里 —— 路径按持有者区分
//
// 仍然遵守的硬约束：不创建线程、不 patch anogs 的 __text、默认不开 dyld 视图过滤。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <unistd.h>

#include "src/Core/Obfs.hpp"
#include "src/Core/SafeMem.h"
#include "src/Core/Stealth.hpp"
#include "src/Game/World.hpp"
#include "src/Game/Offsets.hpp"
#include "src/Render/Overlay.hpp"

// ==================== 目标进程守卫 ====================
static NSString* const kTargetBundle = @"com.proximabeta.mf.uamo";

static bool is_target_process(void) {
    NSBundle* mb = [NSBundle mainBundle];
    NSString* bid = mb.bundleIdentifier;
    if (!bid) {
        // SpringBoard / backboardd / launchd 这类系统进程取不到 mainBundle 的
        // bundleIdentifier，一律不是目标
        return false;
    }
    if ([bid isEqualToString:kTargetBundle]) return true;
    // 探针 app：用来在没有任何注入工具的设备上验证挂点链路（见 probe/）
    if ([bid isEqualToString:@"com.local.arprobe"]) return true;
    return false;
}

// ==================== 全局 kill switch ====================
// 放一个文件就全停：不用卸载、不用重装。
// 文件名刻意取中性名（不带 cheat/ar 字样），且以 XOR 形式存在二进制里 —— anogs 会
// 扫内存里的明文字符串，路径本身也是个指纹。
static bool kill_switch_on(void) {
    const char* offs[] = {
        XSTR("/var/mobile/Library/Preferences/.sbx.state"),
        XSTR("/var/mobile/Documents/.sbx.state"),
    };
    for (int i = 0; i < 2; i++) {
        if (access(offs[i], F_OK) == 0) return true;
    }
    return false;
}

// ==================== 日志 ====================
// 全系统形态下不能固定写"游戏容器的 Caches"：先写进程自己的 Caches，取不到退到
// 沙盒内 /tmp，都失败就只走 NSLog。
static NSString* logPath(void) {
    static NSString* p = nil;
    if (p) return p;
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* base = dirs.count ? dirs[0] : NSTemporaryDirectory();
    NSString* bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    // 日志文件名也走 XOR：明文 "archeat" 会躺在 __cstring 里被 strings 抓到
    p = [base stringByAppendingPathComponent:
            [NSString stringWithFormat:XNS("%@-%@.log"), XNS("m"), bid]];
    return p;
}

static void ARLog(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString* line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:logPath()];
    if (!fh) {
        [line writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"[%@] %@", XNS("m"), s);   // 系统日志里不留可识别的标签
}

// ==================== GEngine 探测 ====================
// 用 _dyld_get_image_header(0) 取主二进制，全系统注入下同样成立（索引 0 永远是被
// exec 的那个可执行文件）。探测值只写日志，不写进 off::GEngine。
static uintptr_t probe_gengine(void) {
    const struct mach_header_64* hdr =
        (const struct mach_header_64*)_dyld_get_image_header(0);
    if (!hdr) return 0;

    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const uint8_t* p = (const uint8_t*)hdr;
    const struct load_command* lc = (const struct load_command*)(p + sizeof(*hdr));

    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* seg = (const struct segment_command_64*)lc;
            if (strcmp(seg->segname, "__DATA") == 0 ||
                strcmp(seg->segname, "__DATA_CONST") == 0) {
                uintptr_t start = seg->vmaddr + slide;
                uintptr_t end   = start + seg->vmsize;
                for (uintptr_t a = start; a + 8 <= end; a += 8) {
                    uintptr_t v = 0;
                    memcpy(&v, (void*)a, 8);
                    if (v < 0x100000000ULL || v > 0x00007FFFFFFFFFFFULL) continue;
                    uintptr_t vt = 0;
                    if (mem::read(v, &vt, 8) &&
                        vt > 0x100000000ULL && vt < 0x00007FFFFFFFFFFFULL) {
                        return a;
                    }
                }
            }
        }
        lc = (const struct load_command*)((uint8_t*)lc + lc->cmdsize);
    }
    return 0;
}

// ==================== 世界就绪后挂渲染点 ====================
static int  g_attempts = 0;
static const int kMaxAttempts = 40;
static bool g_overlayInstalled = false;

static void try_bringup(void);

static void schedule_retry(void) {
    if (g_attempts++ >= kMaxAttempts) {
        ARLog(@"bring-up 放弃：%d 次尝试后仍未拿到世界（偏移没填 / 反篡改指针链）", kMaxAttempts);
        return;
    }
    int64_t ms = (g_attempts < 10) ? 200 : 500;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ try_bringup(); });
}

static void try_bringup(void) {
    @autoreleasepool {
        if (g_overlayInstalled) return;
        if (kill_switch_on()) { ARLog(@"kill switch 命中，停止"); return; }

        world::Context c = world::resolve();
        std::vector<uintptr_t> list;
        if (!(c.world && world::actors(c, list) && !list.empty())) {
            ARLog(@"未就绪 attempt=%d world=0x%lx level=0x%lx",
                  g_attempts, (unsigned long)c.world, (unsigned long)c.level);
            schedule_retry();
            return;
        }
        ARLog(@"就绪 world=0x%lx actors=%zu", (unsigned long)c.world, list.size());
        overlay_install();
        g_overlayInstalled = true;
    }
}

// ==================== 入口 ====================
__attribute__((constructor))
static void archeat_init(void) {
    @autoreleasepool {
        // 全系统注入的第一道闸：不是目标进程就当场退出。
        // 这一句是全系统形态能安全存在的前提——SpringBoard 里装 hook 等于自爆。
        if (!is_target_process()) return;
        if (kill_switch_on()) return;

        ARLog(@"load pid=%d bundle=%@", getpid(), [[NSBundle mainBundle] bundleIdentifier]);

        stealth::Options o;
        // 默认值已在 Stealth.hpp 里改成"生产形态"：不 deny_ptrace、不清 P_TRACED、
        // 不开 dyld 视图过滤。理由见 Docs/STEALTH.md Tier 2——没有调试器时做这些
        // 动作本身是多余信号，而抹 dyld 视图会制造视图间矛盾。
        o.filter_dyld_view = false;
        o.deny_ptrace      = false;
        o.clear_p_traced   = false;
        o.scrub_env        = true;
        o.hide_trollstore  = true;
        stealth::install(o);

        if (!off::GEngine) {
            uintptr_t cand = probe_gengine();
            ARLog(@"GEngine 探测候选=0x%lx（需静态分析确认）", (unsigned long)cand);
        }

        schedule_retry();
    }
}
