// probe/main.mm —— 跨进程偏移探针（不注入游戏、不需要游戏 IPA）
//
// 原理：
//   1. task_for_pid 拿游戏进程 task port（需要 TrollStore 的 entitlement）
//   2. 读游戏进程 dyld_all_image_infos → 找到 UAGame 主镜像加载地址
//   3. 读 GEngine（静态偏移 0x10dbf9a58 相对 0x100000000）
//   4. 在 __bss 里找 FNamePool（判据：Blocks[0] 的 entry0 解出 "None"）
//   5. 用 FName 解析对象类名，逐个验证候选偏移——类名对得上才算对
//
// 输出：界面报告 + Documents/probe.log

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// iPhoneOS SDK 里 <mach/mach_vm.h> 被标成 unsupported，<libproc.h> 也不存在，
// 这里直接声明要用的符号（libSystem 里都有实现）。
extern "C" kern_return_t mach_vm_read_overwrite(vm_map_t target_task,
                                               mach_vm_address_t address,
                                               mach_vm_size_t size,
                                               mach_vm_address_t data,
                                               mach_vm_size_t *outsize);
#define PROC_PIDPATHINFO_MAXSIZE 4096
extern "C" int proc_listallpids(void *buffer, int buffersize);
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

// ---------------- 静态已知量（相对主镜像 0x100000000） ----------------
static const uint64_t kStaticBase   = 0x100000000ULL;
static const uint64_t kOffGEngine   = 0x10dbf9a58ULL;   // 已验证
static const uint64_t kOffBssStart  = 0x10D32C880ULL;   // __DATA.__bss
static const uint64_t kOffBssEnd    = 0x10DACAF70ULL;   // __bss + __common

// ---------------- 日志 ----------------
static NSMutableString* gLog = nil;
static void L(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [gLog appendString:s];
    [gLog appendString:@"\n"];
    NSLog(@"[probe] %@", s);
}

// ---------------- 跨进程读 ----------------
struct Remote {
    task_t   task = MACH_PORT_NULL;
    pid_t    pid  = 0;
    bool     ok   = false;
    uint64_t base = 0;
};

static bool rd(Remote& r, uint64_t addr, void* out, size_t n) {
    if (!r.ok || !addr || !n) return false;
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(r.task, (mach_vm_address_t)addr,
                                              (mach_vm_size_t)n,
                                              (mach_vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == n;
}
static uint64_t rd64(Remote& r, uint64_t a) { uint64_t v = 0; return rd(r, a, &v, 8) ? v : 0; }
static uint32_t rd32(Remote& r, uint64_t a) { uint32_t v = 0; return rd(r, a, &v, 4) ? v : 0; }

static bool rdstr(Remote& r, uint64_t a, char* out, size_t cap) {
    out[0] = 0;
    if (!rd(r, a, out, cap - 1)) return false;
    out[cap - 1] = 0;
    return out[0] != 0;
}

static pid_t find_pid(const char* needle) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    pid_t* pids = (pid_t*)calloc((size_t)n, sizeof(pid_t));
    if (!pids) return 0;
    n = proc_listallpids(pids, n * (int)sizeof(pid_t));
    pid_t hit = 0;
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        if (strstr(path, needle)) { hit = pids[i]; break; }
    }
    free(pids);
    return hit;
}

static uint64_t find_image_base(Remote& r, const char* needle) {
    struct task_dyld_info tdi;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    if (task_info(r.task, TASK_DYLD_INFO, (task_info_t)&tdi, &cnt) != KERN_SUCCESS) return 0;

    uint64_t infos = tdi.all_image_info_addr;
    uint32_t count = rd32(r, infos + 4);
    uint64_t array = rd64(r, infos + 8);
    L(@"dyld: count=%u array=0x%llx", count, array);
    if (!count || count > 4096 || !array) return 0;

    for (uint32_t i = 0; i < count; i++) {
        uint64_t ent   = array + (uint64_t)i * 24;
        uint64_t hdr   = rd64(r, ent);
        uint64_t pathp = rd64(r, ent + 8);
        char path[512] = {0};
        if (!rdstr(r, pathp, path, sizeof(path))) continue;
        if (strstr(path, needle)) {
            L(@"image[%u] base=0x%llx %s", i, hdr, path);
            return hdr;
        }
    }
    return 0;
}

// ---------------- UE FName ----------------
static uint64_t gNames  = 0;
static int      gStride = 2;

static bool fname_get(Remote& r, uint32_t idx, char* out, size_t cap) {
    out[0] = 0;
    if (!gNames || cap < 2) return false;
    if ((idx >> 16) >= 8192) return false;
    uint64_t block = rd64(r, gNames + 0x10 + (uint64_t)(idx >> 16) * 8);
    if (!block) return false;
    uint64_t entry = block + (uint64_t)gStride * (idx & 0xFFFF);
    uint16_t hdr = 0;
    if (!rd(r, entry, &hdr, 2)) return false;
    const bool wide = (hdr & 1) != 0;
    uint32_t len = hdr >> 1;
    if (!len || len > 512) return false;
    uint32_t n = (len < (cap - 1)) ? len : (uint32_t)(cap - 1);
    if (wide) {
        for (uint32_t i = 0; i < n; i++) {
            uint16_t ch = 0;
            if (!rd(r, entry + 2 + (uint64_t)i * 2, &ch, 2)) { out[i] = 0; return i > 0; }
            out[i] = (ch < 0x80) ? (char)ch : '?';
        }
    } else {
        if (!rd(r, entry + 2, out, n)) return false;
    }
    out[n] = 0;
    return true;
}

static uint64_t locate_gnames(Remote& r) {
    const uint64_t lo = r.base + (kOffBssStart - kStaticBase);
    const uint64_t hi = r.base + (kOffBssEnd   - kStaticBase);
    const size_t   chunk = 1u << 20;
    char* buf = (char*)malloc(chunk);
    if (!buf) return 0;
    int tried = 0;

    for (uint64_t a = lo; a < hi; a += chunk) {
        size_t n = (size_t)((hi - a) < chunk ? (hi - a) : chunk);
        if (!rd(r, a, buf, n)) continue;
        for (size_t off = 0; off + 8 <= n; off += 8) {
            uint64_t v = *(uint64_t*)(buf + off);
            if (v < 0x100000000ULL || v > 0x8000000000ULL) continue;
            if (v & 0xF) continue;
            if (++tried > 20000) { L(@"GNames 扫描到 20000 次上限"); free(buf); return 0; }
            uint64_t block0 = rd64(r, v + 0x10);
            if (!block0) continue;
            uint16_t h = 0;
            if (!rd(r, block0, &h, 2)) continue;
            uint32_t len = h >> 1;
            if ((h & 1) == 0 && len >= 4 && len <= 8) {
                char s[16] = {0};
                if (rd(r, block0 + 2, s, len) && strcmp(s, "None") == 0) {
                    gStride = 2;
                    L(@"GNames = 0x%llx (stride=%d)", v, gStride);
                    free(buf);
                    return v;
                }
            }
        }
    }
    L(@"GNames 未找到 (tried=%d)", tried);
    free(buf);
    return 0;
}

static bool obj_class_name(Remote& r, uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    uint64_t cls = rd64(r, obj + 0x10);
    if (!cls) return false;
    return fname_get(r, rd32(r, cls + 0x18), out, cap);
}
static bool obj_own_name(Remote& r, uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    return fname_get(r, rd32(r, obj + 0x18), out, cap);
}

// 在对象里扫指针字段：找类名匹配 key 的成员
static void scan_fields(Remote& r, uint64_t obj, const char* key,
                        uint64_t maxOff, const char* tag) {
    for (uint64_t off = 0; off < maxOff; off += 8) {
        uint64_t p = rd64(r, obj + off);
        if (p < 0x100000000ULL || p > 0x8000000000ULL) continue;
        char cls[128] = {0};
        if (!obj_class_name(r, p, cls, sizeof(cls))) continue;
        if (strstr(cls, key)) {
            char own[128] = {0};
            obj_own_name(r, p, own, sizeof(own));
            L(@"  [%s] +0x%llx -> 0x%llx  class=%s name=%s", tag, off, p, cls, own);
        }
    }
}

// ---------------- 主探测 ----------------
static NSString* runProbe(void) {
    Remote r;
    r.pid = find_pid("/UAGame");
    if (!r.pid) r.pid = find_pid("/Arena");
    L(@"target pid = %d", r.pid);
    if (!r.pid) { L(@"没找到游戏进程，先启动游戏并进大厅"); return gLog; }

    kern_return_t kr = task_for_pid(mach_task_self(), r.pid, &r.task);
    L(@"task_for_pid -> %s (%d)", mach_error_string(kr), kr);
    if (kr != KERN_SUCCESS) { L(@"tfp 失败：entitlement 不足"); return gLog; }
    r.ok = true;

    r.base = find_image_base(r, "UAGame");
    if (!r.base) r.base = find_image_base(r, "Arena");
    L(@"image base = 0x%llx", r.base);
    if (!r.base) { L(@"没定位到主镜像"); return gLog; }

    gNames = locate_gnames(r);

    uint64_t slot   = r.base + (kOffGEngine - kStaticBase);
    uint64_t engine = rd64(r, slot);
    L(@"GEngine 槽 0x%llx -> 0x%llx", slot, engine);
    if (!engine) { L(@"GEngine 为空（可能还在启动界面）"); return gLog; }

    char nm[128] = {0};
    if (gNames && obj_class_name(r, engine, nm, sizeof(nm))) L(@"GEngine class = %s", nm);
    L(@"GEngine vtable = 0x%llx", rd64(r, engine));

    const uint64_t cands[] = { 0x10, 0x50, 0x178, 0x370, 0x388, 0x680, 0x788,
                               0xb50, 0xb60, 0xb80, 0xcb8, 0xe80, 0x2a8, 0x5f8 };
    L(@"--- GEngine 字段探测 ---");
    for (unsigned i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        uint64_t p = rd64(r, engine + cands[i]);
        if (p < 0x100000000ULL || p > 0x8000000000ULL) continue;
        char cls[128] = {0}, own[128] = {0};
        bool have = gNames && obj_class_name(r, p, cls, sizeof(cls));
        if (gNames) obj_own_name(r, p, own, sizeof(own));
        L(@"+0x%llx -> 0x%llx class=%s name=%s", cands[i], p,
          have ? cls : "?", own[0] ? own : "-");
        if (have && strstr(cls, "World")) {
            L(@"  ^^^ 这是 World，开始扫它的字段");
            scan_fields(r, p, "Level", 0x400, "World");
        }
    }
    return gLog;
}

// ---------------- UI ----------------
@interface ProbeVC : UIViewController
@end

@implementation ProbeVC {
    UITextView* _tv;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 120, self.view.bounds.size.width,
                                                       self.view.bounds.size.height - 120)];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.backgroundColor = [UIColor blackColor];
    _tv.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1.0];
    _tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _tv.editable = NO;
    _tv.text = @"先启动游戏并进到大厅，再点「开始探测」";
    [self.view addSubview:_tv];

    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(16, 60, 180, 44);
    [b setTitle:@"开始探测" forState:UIControlStateNormal];
    [b addTarget:self action:@selector(run:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
}

- (void)run:(id)sender {
    _tv.text = @"探测中…";
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (!gLog) gLog = [NSMutableString new];
        [gLog setString:@""];
        NSString* rep = runProbe();
        NSString* path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                          stringByAppendingPathComponent:@"probe.log"];
        [rep writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_tv.text = [NSString stringWithFormat:@"%@\n\n已写入 Documents/probe.log", rep];
        });
    });
}

@end

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeDelegate { UIWindow* _w; }
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)o {
    _w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _w.rootViewController = [ProbeVC new];
    [_w makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeDelegate class]));
    }
}
