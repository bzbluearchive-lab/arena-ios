// inprobe/main.mm - in-game offset probe (runs INSIDE the game process)
//
// Why: a sandboxed app cannot task_for_pid the game (verified on device: tfp(self)
// also fails, so the entitlement is not honoured). Inside the game process we are
// allowed to read our own memory directly - no entitlement, no injection of code
// into others, no writes.
//
// Behaviour: constructor waits N seconds (let GEngine come up), then:
//   1. resolve main image base via _dyld_get_image_header(0)
//   2. read GEngine (static offset 0x10dbf9a58 relative to 0x100000000)
//   3. locate FNamePool by scanning __bss (local memory, fast)
//   4. resolve class names of GEngine fields, print via UDP to 127.0.0.1:45999
//      and also append to <container>/Documents/inprobe.log
//
// Nothing is written to the game: read-only probing.

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const uint64_t kStaticBase  = 0x100000000ULL;
static const uint64_t kOffGEngine  = 0x10dbf9a58ULL;
static const uint64_t kOffBssStart = 0x10D32C880ULL;
static const uint64_t kOffBssEnd   = 0x10DACAF70ULL;
static const int      kUdpPort     = 45999;

static uint64_t gBase  = 0;
static uint64_t gNames = 0;
static int      gStride = 2;
static int      gSock  = -1;
static struct sockaddr_in gAddr;
static NSMutableString* gLog = nil;

static void flushFile(void) {
    if (!gLog) return;
    NSString* p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!p) return;
    [gLog writeToFile:[p stringByAppendingPathComponent:@"inprobe.log"]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void L(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gLog) gLog = [NSMutableString new];
    [gLog appendString:s];
    [gLog appendString:@"\n"];
    NSLog(@"[inprobe] %@", s);
    if (gSock >= 0) {
        const char* c = [s UTF8String];
        sendto(gSock, c, strlen(c), 0, (struct sockaddr*)&gAddr, sizeof(gAddr));
    }
    flushFile();
}

// local reads: the address belongs to our own process, so a guarded memcpy is enough
static bool lrd(uint64_t addr, void* out, size_t n) {
    if (!addr || !out || !n) return false;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                                         (vm_size_t)n, (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == n;
}
static uint64_t lrd64(uint64_t a) { uint64_t v = 0; return lrd(a, &v, 8) ? v : 0; }
static uint32_t lrd32(uint64_t a) { uint32_t v = 0; return lrd(a, &v, 4) ? v : 0; }

static bool fname_get(uint32_t idx, char* out, size_t cap) {
    if (!out || cap < 2) return false;
    out[0] = 0;
    if (!gNames || (idx >> 16) >= 8192) return false;
    uint64_t block = lrd64(gNames + 0x10 + (uint64_t)(idx >> 16) * 8);
    if (!block) return false;
    uint64_t entry = block + (uint64_t)gStride * (idx & 0xFFFF);
    uint16_t hdr = 0;
    if (!lrd(entry, &hdr, 2)) return false;
    uint32_t len = hdr >> 1;
    if (!len || len > 512) return false;
    uint32_t n = (len < cap - 1) ? len : (uint32_t)(cap - 1);
    if (hdr & 1) {                       // wide (UTF-16)
        for (uint32_t i = 0; i < n; i++) {
            uint16_t ch = 0;
            if (!lrd(entry + 2 + (uint64_t)i * 2, &ch, 2)) { out[i] = 0; return i > 0; }
            out[i] = (ch < 0x80) ? (char)ch : '?';
        }
    } else {
        if (!lrd(entry + 2, out, n)) return false;
    }
    out[n] = 0;
    return true;
}

static uint64_t locate_gnames(void) {
    uint64_t lo = gBase + (kOffBssStart - kStaticBase);
    uint64_t hi = gBase + (kOffBssEnd   - kStaticBase);
    L(@"gnames scan 0x%llx..0x%llx", lo, hi);
    int tried = 0;
    for (uint64_t a = lo; a + 8 <= hi; a += 8) {
        uint64_t v = lrd64(a);
        if (v < 0x100000000ULL || v > 0x8000000000ULL) continue;
        if (v & 0xF) continue;
        if (++tried > 200000) { L(@"gnames: cap reached"); return 0; }
        uint64_t b0 = lrd64(v + 0x10);
        if (!b0) continue;
        uint16_t h = 0;
        if (!lrd(b0, &h, 2)) continue;
        uint32_t len = h >> 1;
        if ((h & 1) == 0 && len >= 4 && len <= 8) {
            char s[16] = {0};
            if (lrd(b0 + 2, s, len) && strcmp(s, "None") == 0) {
                gStride = 2;
                L(@"GNames = 0x%llx", v);
                return v;
            }
        }
    }
    L(@"gnames not found (tried=%d)", tried);
    return 0;
}

static bool cls_name(uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    uint64_t cls = lrd64(obj + 0x10);
    if (!cls) return false;
    return fname_get(lrd32(cls + 0x18), out, cap);
}
static bool own_name(uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    return fname_get(lrd32(obj + 0x18), out, cap);
}

static void scan_for(uint64_t obj, const char* key, uint64_t maxOff, const char* tag) {
    for (uint64_t off = 0; off < maxOff; off += 8) {
        uint64_t p = lrd64(obj + off);
        if (p < 0x100000000ULL || p > 0x8000000000ULL) continue;
        char c[128] = {0};
        if (!cls_name(p, c, sizeof(c))) continue;
        if (strstr(c, key)) {
            char o[128] = {0};
            own_name(p, o, sizeof(o));
            L(@"[%s] +0x%llx -> 0x%llx class=%s name=%s", tag, off, p, c, o);
        }
    }
}

static void probe_once(void) {
    uint64_t engine = lrd64(gBase + (kOffGEngine - kStaticBase));
    L(@"base=0x%llx GEngine=0x%llx", gBase, engine);
    if (!engine) { L(@"GEngine null, retry later"); return; }

    char nm[128] = {0};
    if (gNames && cls_name(engine, nm, sizeof(nm))) L(@"GEngine class=%s", nm);
    L(@"GEngine vtable=0x%llx", lrd64(engine));

    const uint64_t cands[] = { 0x10, 0x50, 0x178, 0x370, 0x388, 0x680, 0x788,
                               0xb50, 0xb60, 0xb80, 0xcb8, 0xe80, 0x2a8, 0x5f8 };
    for (unsigned i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        uint64_t p = lrd64(engine + cands[i]);
        if (p < 0x100000000ULL || p > 0x8000000000ULL) continue;
        char c[128] = {0}, o[128] = {0};
        bool have = gNames && cls_name(p, c, sizeof(c));
        if (gNames) own_name(p, o, sizeof(o));
        L(@"+0x%llx -> 0x%llx class=%s name=%s", cands[i], p, have ? c : "?", o[0] ? o : "-");
        if (have && strstr(c, "World")) scan_for(p, "Level", 0x400, "World");
    }
    L(@"probe pass done");
}

__attribute__((constructor))
static void inprobe_init(void) {
    @autoreleasepool {
        gSock = socket(AF_INET, SOCK_DGRAM, 0);
        memset(&gAddr, 0, sizeof(gAddr));
        gAddr.sin_family = AF_INET;
        gAddr.sin_port = htons(kUdpPort);
        gAddr.sin_addr.s_addr = inet_addr("127.0.0.1");

        const struct mach_header_64* h = (const struct mach_header_64*)_dyld_get_image_header(0);
        gBase = (uint64_t)h;

        L(@"inprobe loaded pid=%d base=0x%llx", getpid(), gBase);

        // wait for the engine, then do 3 passes a few seconds apart
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{
            gNames = locate_gnames();
            probe_once();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(0, 0), ^{
                probe_once();
            });
        });
    }
}
