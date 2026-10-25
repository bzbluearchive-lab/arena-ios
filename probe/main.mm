// probe/main.mm - cross-process offset probe (no injection, no game ipa needed)
//
// Flow:
//   1. task_for_pid on the game (needs the entitlements in entitlements.plist)
//   2. read dyld_all_image_infos from the target -> find the UAGame main image base
//   3. read GEngine (static offset 0x10dbf9a58 relative to 0x100000000)
//   4. locate FNamePool inside __bss (entry 0 must decode to "None")
//   5. resolve class names via FName and validate candidate offsets - name match is
//      the only thing we trust
//
// Output: on-screen report + Documents/probe.log (flushed after every step, so a
// crash still leaves the last completed step on disk).

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// iPhoneOS SDK marks <mach/mach_vm.h> unsupported and has no <libproc.h>,
// so declare the few symbols we need ourselves (all live in libSystem).
extern "C" kern_return_t mach_vm_read_overwrite(vm_map_t target_task,
                                               mach_vm_address_t address,
                                               mach_vm_size_t size,
                                               mach_vm_address_t data,
                                               mach_vm_size_t *outsize);
#define PROC_PIDPATHINFO_MAXSIZE 4096
extern "C" int proc_listallpids(void *buffer, int buffersize);
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

// ---- static facts (relative to main image 0x100000000) ----
static const uint64_t kStaticBase  = 0x100000000ULL;
static const uint64_t kOffGEngine  = 0x10dbf9a58ULL;   // verified: 1656 xrefs
static const uint64_t kOffBssStart = 0x10D32C880ULL;   // __DATA.__bss
static const uint64_t kOffBssEnd   = 0x10DACAF70ULL;   // __bss + __common

// ---- logging (flushed immediately) ----
static NSMutableString* gLog = nil;
static NSString* gLogPath = nil;

static void flushLog(void) {
    if (!gLogPath || !gLog) return;
    [gLog writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void L(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gLog) gLog = [NSMutableString new];
    [gLog appendString:s];
    [gLog appendString:@"\n"];
    NSLog(@"[probe] %@", s);
    flushLog();
}

// ---- remote read ----
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
    if (!out || cap < 2) return false;
    out[0] = 0;
    if (!rd(r, a, out, cap - 1)) return false;
    out[cap - 1] = 0;
    return out[0] != 0;
}

// Enumerate processes via sysctl(KERN_PROC_ALL). Works inside the sandbox and does
// not need proc_pidpath (which is often denied for other processes).
static pid_t find_pid_sysctl(const char* needle, int* outCount, char* sample, size_t sampleCap) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0) { if (outCount) *outCount = -1; return 0; }
    if (sz == 0 || sz > (64u << 20)) { if (outCount) *outCount = -2; return 0; }
    struct kinfo_proc* procs = (struct kinfo_proc*)malloc(sz);
    if (!procs) { if (outCount) *outCount = -3; return 0; }
    if (sysctl(mib, 4, procs, &sz, NULL, 0) != 0) { free(procs); if (outCount) *outCount = -4; return 0; }
    int n = (int)(sz / sizeof(struct kinfo_proc));
    if (outCount) *outCount = n;
    pid_t hit = 0;
    if (sample && sampleCap) sample[0] = 0;
    int shown = 0;
    for (int i = 0; i < n; i++) {
        char comm[17];
        memcpy(comm, procs[i].kp_proc.p_comm, 16);
        comm[16] = 0;
        if (comm[0] == 0) continue;
        if (sample && sampleCap && shown < 14) {
            size_t cur = strlen(sample);
            snprintf(sample + cur, sampleCap - cur, "%s(%d) ", comm, procs[i].kp_proc.p_pid);
            shown++;
        }
        if (hit == 0 && needle && needle[0] && strstr(comm, needle)) hit = procs[i].kp_proc.p_pid;
        if (hit == 0 && strstr(comm, "Arena")) hit = procs[i].kp_proc.p_pid;
        if (hit == 0 && strstr(comm, "UAGame")) hit = procs[i].kp_proc.p_pid;
    }
    free(procs);
    return hit;
}

static pid_t find_pid(const char* needle) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    pid_t* pids = (pid_t*)calloc((size_t)n, sizeof(pid_t));
    if (!pids) return 0;
    n = proc_listallpids(pids, n * (int)sizeof(pid_t));
    pid_t hit = 0;
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        memset(path, 0, sizeof(path));
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        if (strstr(path, needle)) { hit = pids[i]; break; }
    }
    free(pids);
    return hit;
}

static uint64_t find_image_base(Remote& r, const char* needle) {
    struct task_dyld_info tdi;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(r.task, TASK_DYLD_INFO, (task_info_t)&tdi, &cnt);
    if (kr != KERN_SUCCESS) { L(@"task_info failed: %s", mach_error_string(kr)); return 0; }

    uint64_t infos = tdi.all_image_info_addr;
    uint32_t count = rd32(r, infos + 4);
    uint64_t array = rd64(r, infos + 8);
    L(@"dyld: count=%u array=0x%llx", count, array);
    if (!count || count > 4096 || !array) return 0;

    for (uint32_t i = 0; i < count; i++) {
        uint64_t ent   = array + (uint64_t)i * 24;
        uint64_t hdr   = rd64(r, ent);
        uint64_t pathp = rd64(r, ent + 8);
        char path[512];
        memset(path, 0, sizeof(path));
        if (!rdstr(r, pathp, path, sizeof(path))) continue;
        if (strstr(path, needle)) {
            L(@"image[%u] base=0x%llx %s", i, hdr, path);
            return hdr;
        }
    }
    return 0;
}

// ---- UE FName ----
static uint64_t gNames  = 0;
static int      gStride = 2;

static bool fname_get(Remote& r, uint32_t idx, char* out, size_t cap) {
    if (!out || cap < 2) return false;
    out[0] = 0;
    if (!gNames) return false;
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
    if (!buf) { L(@"malloc failed"); return 0; }
    int tried = 0;

    for (uint64_t a = lo; a < hi; a += chunk) {
        size_t n = (size_t)((hi - a) < chunk ? (hi - a) : chunk);
        L(@"scan 0x%llx (%zu bytes)", a, n);
        if (!rd(r, a, buf, n)) continue;
        for (size_t off = 0; off + 8 <= n; off += 8) {
            uint64_t v;
            memcpy(&v, buf + off, 8);
            if (v < 0x100000000ULL || v > 0x8000000000ULL) continue;
            if (v & 0xF) continue;
            if (++tried > 20000) { L(@"gnames: hit 20000 candidates, stop"); free(buf); return 0; }
            uint64_t block0 = rd64(r, v + 0x10);
            if (!block0) continue;
            uint16_t h = 0;
            if (!rd(r, block0, &h, 2)) continue;
            uint32_t len = h >> 1;
            if ((h & 1) == 0 && len >= 4 && len <= 8) {
                char s[16];
                memset(s, 0, sizeof(s));
                if (rd(r, block0 + 2, s, len) && strcmp(s, "None") == 0) {
                    gStride = 2;
                    L(@"GNames = 0x%llx (stride=%d)", v, gStride);
                    free(buf);
                    return v;
                }
            }
        }
    }
    L(@"gnames not found (tried=%d)", tried);
    free(buf);
    return 0;
}

static bool obj_class_name(Remote& r, uint64_t obj, char* out, size_t cap) {
    if (out && cap) out[0] = 0;
    uint64_t cls = rd64(r, obj + 0x10);          // UObject::ClassPrivate
    if (!cls) return false;
    return fname_get(r, rd32(r, cls + 0x18), out, cap);   // UClass::NamePrivate
}
static bool obj_own_name(Remote& r, uint64_t obj, char* out, size_t cap) {
    if (out && cap) out[0] = 0;
    return fname_get(r, rd32(r, obj + 0x18), out, cap);   // UObject::NamePrivate
}

static void scan_fields(Remote& r, uint64_t obj, const char* key,
                        uint64_t maxOff, const char* tag) {
    for (uint64_t off = 0; off < maxOff; off += 8) {
        uint64_t p = rd64(r, obj + off);
        if (p < 0x100000000ULL || p > 0x8000000000ULL) continue;
        char cls[128];
        memset(cls, 0, sizeof(cls));
        if (!obj_class_name(r, p, cls, sizeof(cls))) continue;
        if (strstr(cls, key)) {
            char own[128];
            memset(own, 0, sizeof(own));
            obj_own_name(r, p, own, sizeof(own));
            L(@"[%s] +0x%llx -> 0x%llx class=%s name=%s", tag, off, p, cls, own);
        }
    }
}

// ---- main probe ----
static NSString* runProbe(BOOL deep) {
    Remote r;
    // 1) enumerate with sysctl (works in sandbox, gives p_comm)
    int nproc = 0;
    char sample[1024];
    memset(sample, 0, sizeof(sample));
    r.pid = find_pid_sysctl("UAGame", &nproc, sample, sizeof(sample));
    L(@"step1a sysctl procs=%d sample: %s", nproc, sample);
    if (!r.pid) {
        // 2) fall back to libproc (needs path access, may be denied)
        r.pid = find_pid("/UAGame");
        if (!r.pid) r.pid = find_pid("/Arena");
        if (r.pid) L(@"step1b libproc fallback hit pid=%d", r.pid);
    }
    L(@"step1 target pid = %d", r.pid);
    if (!r.pid) { L(@"no game process found (is the game running?)"); return gLog; }

    kern_return_t kr = task_for_pid(mach_task_self(), r.pid, &r.task);
    L(@"step2 task_for_pid -> %s (%d)", mach_error_string(kr), kr);
    if (kr != KERN_SUCCESS) { L(@"tfp denied"); return gLog; }
    r.ok = true;

    r.base = find_image_base(r, "UAGame");
    if (!r.base) r.base = find_image_base(r, "Arena");
    L(@"step3 image base = 0x%llx", r.base);
    if (!r.base) { L(@"main image not found"); return gLog; }

    if (deep) { gNames = locate_gnames(r); }
    else      { L(@"light mode: skip FName scan"); }

    uint64_t slot   = r.base + (kOffGEngine - kStaticBase);
    uint64_t engine = rd64(r, slot);
    L(@"step4 GEngine slot 0x%llx -> 0x%llx", slot, engine);
    if (!engine) { L(@"GEngine is null (still on loading screen?)"); return gLog; }

    char nm[128];
    memset(nm, 0, sizeof(nm));
    if (gNames && obj_class_name(r, engine, nm, sizeof(nm))) L(@"   GEngine class = %s", nm);
    L(@"   GEngine vtable = 0x%llx", rd64(r, engine));

    const uint64_t cands[] = { 0x10, 0x50, 0x178, 0x370, 0x388, 0x680, 0x788,
                               0xb50, 0xb60, 0xb80, 0xcb8, 0xe80, 0x2a8, 0x5f8 };
    L(@"step5 GEngine field candidates");
    for (unsigned i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        uint64_t p = rd64(r, engine + cands[i]);
        if (p < 0x100000000ULL || p > 0x8000000000ULL) continue;
        char cls[128], own[128];
        memset(cls, 0, sizeof(cls));
        memset(own, 0, sizeof(own));
        bool have = gNames && obj_class_name(r, p, cls, sizeof(cls));
        if (gNames) obj_own_name(r, p, own, sizeof(own));
        L(@"   +0x%llx -> 0x%llx class=%s name=%s", cands[i], p,
          have ? cls : "?", own[0] ? own : "-");
        if (have && strstr(cls, "World")) scan_fields(r, p, "Level", 0x400, "World");
    }
    L(@"probe done");
    return gLog;
}

// ---- UI ----
@interface ProbeVC : UIViewController
@end

@implementation ProbeVC {
    UITextView* _tv;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 130, self.view.bounds.size.width,
                                                       self.view.bounds.size.height - 130)];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.backgroundColor = [UIColor blackColor];
    _tv.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1.0];
    _tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _tv.editable = NO;
    _tv.text = [NSString stringWithFormat:@"build %@\n1) start the game, wait until you are in the lobby\n2) tap Light first, then Deep\n3) send Documents/probe.log", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"];
    [self.view addSubview:_tv];

    UIButton* b1 = [UIButton buttonWithType:UIButtonTypeSystem];
    b1.frame = CGRectMake(16, 60, 150, 44);
    [b1 setTitle:@"1 Light" forState:UIControlStateNormal];
    [b1 addTarget:self action:@selector(runLight:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b1];

    UIButton* b2 = [UIButton buttonWithType:UIButtonTypeSystem];
    b2.frame = CGRectMake(180, 60, 150, 44);
    [b2 setTitle:@"2 Deep" forState:UIControlStateNormal];
    [b2 addTarget:self action:@selector(runDeep:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b2];
}

- (void)runLight:(id)sender { [self start:NO]; }
- (void)runDeep:(id)sender  { [self start:YES]; }

- (void)start:(BOOL)deep {
    _tv.text = @"probing...";
    if (!gLogPath) {
        gLogPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                    stringByAppendingPathComponent:@"probe.log"];
    }
    if (!gLog) gLog = [NSMutableString new];
    [gLog setString:@""];
    L(@"=== probe start (deep=%d) ===", (int)deep);

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString* rep = runProbe(deep);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_tv.text = [NSString stringWithFormat:@"%@\n\nwritten to Documents/probe.log", rep];
        });
    });
}

@end

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeDelegate { UIWindow* _w; }
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)o {
    gLogPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                stringByAppendingPathComponent:@"probe.log"];
    if (!gLog) gLog = [NSMutableString new];
    [gLog setString:@""];
    NSString* ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";\
    NSString* disp = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"?";\
    L(@"launch ok pid=%d uid=%d ver=%@ name=%@", getpid(), getuid(), ver, disp);

    _w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _w.rootViewController = [ProbeVC new];
    [_w makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        {
            // write immediately: if this file is missing we died before main (dyld/AMFI)
            NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString* d0 = [dirs firstObject];
            NSString* s0 = [NSString stringWithFormat:@"main entered pid=%d uid=%d", getpid(), getuid()];
            [s0 writeToFile:[d0 stringByAppendingPathComponent:@"main.log"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeDelegate class]));
    }
}
