// Tweak.x —— 入口。
//
// 时序（很重要）：
//   0.0s  constructor 立刻装最便宜的反调试/环境清理，此时 anogs 还没 init
//   ?.??  等 anogs 的 AnoSDKInit 走完（我们不去 hook 它，只用轮询等 GEngine 出现）
//   就绪  装 Metal 挂点，开始每帧驱动
//
// 不在这里创建线程。轮询用 dispatch_after 挂在主队列上，逐步退避。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>

#include "src/Core/Stealth.hpp"
#include "src/Game/World.hpp"
#include "src/Game/Offsets.hpp"
#include "src/Render/Overlay.hpp"

static int g_attempts = 0;
static const int kMaxAttempts = 40;

static NSString* logPath() {
    static NSString* p = nil;
    if (p) return p;
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* base = dirs.count ? dirs[0] : NSTemporaryDirectory();
    p = [base stringByAppendingPathComponent:@"archeat.log"];
    return p;
}

static void ARLog(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString* line = [NSString stringWithFormat:@"[%@] %@\n",
                      [NSDate date], s];
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:logPath()];
    if (!fh) {
        [line writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"[ARCheat] %@", s);
}

// 特征码扫描：GEngine 在 .data 里，先按"指针落在本进程可读区且指向的结构
// 首个字段像 vtable"来粗筛，再用 uid 链校验。这一步是给"还没做静态分析"时用的
// 探测模式；静态分析完成后直接填 off::GEngine，把探测关掉。
static uintptr_t probe_gengine() {
    const struct mach_header_64* hdr =
        (const struct mach_header_64*)_dyld_get_image_header(0);
    if (!hdr) return 0;

    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const uint8_t* p = (const uint8_t*)hdr;
    uint32_t ncmds = hdr->ncmds;
    const struct load_command* lc = (const struct load_command*)(p + sizeof(*hdr));

    // 遍历 __DATA / __DATA_CONST 段：这些段里全是指针，扫 GEngine 候选
    for (uint32_t i = 0; i < ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* seg = (const struct segment_command_64*)lc;
            const char* name = seg->segname;
            bool candidate = (strcmp(name, "__DATA") == 0 || strcmp(name, "__DATA_CONST") == 0);
            if (candidate) {
                uintptr_t start = seg->vmaddr + slide;
                uintptr_t end   = start + seg->vmsize;
                for (uintptr_t a = start; a + 8 <= end; a += 8) {
                    uintptr_t v = 0;
                    memcpy(&v, (void*)a, 8);
                    if (v < 0x100000000ULL || v > 0x00007FFFFFFFFFFFULL) continue;
                    uintptr_t vt = 0;
                    if (mem::read(v, &vt, 8) && vt > 0x100000000ULL && vt < 0x00007FFFFFFFFFFFULL) {
                        // 指向的对象首字段是 vtable，且 vtable 首项落在 __TEXT
                        // 这里只做"像 UObject"的粗判，真正的确认交给 world::resolve 的
                        // actor 数量校验
                        return a;
                    }
                }
            }
        }
        lc = (const struct load_command*)((uint8_t*)lc + lc->cmdsize);
    }
    return 0;
}

static void try_bringup();

static void schedule_retry() {
    if (g_attempts++ >= kMaxAttempts) {
        ARLog(@"bring-up 放弃：%d 次尝试后仍未拿到世界（多半是偏移没填）", kMaxAttempts);
        return;
    }
    // 退避：前 10 次 200ms，之后 500ms
    int64_t ms = (g_attempts < 10) ? 200 : 500;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ try_bringup(); });
}

static void try_bringup() {
    @autoreleasepool {
        world::Context c = world::resolve();
        std::vector<uintptr_t> list;
        bool ok = c.world && world::actors(c, list) && !list.empty();

        if (!ok) {
            ARLog(@"未就绪 attempt=%d world=0x%lx level=0x%lx",
                  g_attempts, (unsigned long)c.world, (unsigned long)c.level);
            schedule_retry();
            return;
        }
        ARLog(@"就绪：world=0x%lx level=0x%lx actors=%zu", (unsigned long)c.world,
              (unsigned long)c.level, list.size());
        overlay_install();   // 只在真正拿到世界后才挂渲染点
    }
}

__attribute__((constructor))
static void archeat_init(void) {
    @autoreleasepool {
        ARLog(@"load pid=%d", getpid());

        stealth::Options o;
        o.filter_dyld_view = false;   // 默认关：粗暴过滤比不隐藏更像攻击面
        o.deny_ptrace      = true;
        o.clear_p_traced   = true;
        o.scrub_env        = true;
        o.hide_trollstore  = true;
        stealth::install(o);

        if (!off::GEngine) {
            uintptr_t cand = probe_gengine();
            ARLog(@"GEngine 探测候选=0x%lx（需静态分析确认，勿直接采信）",
                  (unsigned long)cand);
            // 探测值只写进日志，不写进 off::GEngine —— 未验证的全局变量写进去
            // 会让后面所有偏移全部 garbage，且症状极像"偏移错"
        }

        // 引擎初始化完成前不要碰 render hook；等世界出现
        schedule_retry();
    }
}
