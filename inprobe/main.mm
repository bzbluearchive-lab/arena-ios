// inprobe/main.mm - one-shot in-game probe (runs inside the game process)
//
// The game (ACE) kills the injected dylib ~60s after entering a match, so this
// must finish everything in a single pass:
//   1. locate FNamePool by scanning the whole __DATA segment
//   2. resolve GEngine class name (proves FName works)
//   3. scan GEngine fields for objects (World / GameViewport / GameInstance)
//   4. from World: find PersistentLevel (ULevel)
//   5. from Level: find the Actors TArray, print first actors' class names
//   6. from an actor: find SkeletalMeshComponent and its bone transforms
//
// Output: <container>/Documents/inprobe.log + UDP 127.0.0.1:45999. Read-only.

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

static const uint64_t kStaticBase = 0x100000000ULL;
static const uint64_t kOffGEngine = 0x10dbf9a58ULL;
static const int      kUdpPort   = 45999;

static uint64_t gBase = 0, gNames = 0;
static int gStride = 2;
static int gSock = -1;
static struct sockaddr_in gAddr;
static NSMutableString* gLog = nil;

static void flushFile(void) {
    if (!gLog) return;
    NSString* p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (p) [gLog writeToFile:[p stringByAppendingPathComponent:@"inprobe.log"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void L(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gLog) gLog = [NSMutableString new];
    [gLog appendString:s];
    [gLog appendString:@"\n"];
    if (gSock >= 0) {
        const char* c = [s UTF8String];
        sendto(gSock, c, strlen(c), 0, (struct sockaddr*)&gAddr, sizeof(gAddr));
    }
    flushFile();
}

// ---- local memory reads (our own address space) ----
static bool lrd(uint64_t a, void* out, size_t n) {
    if (!a || !out || !n) return false;
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)a, (vm_size_t)n,
                             (vm_address_t)out, &got) == KERN_SUCCESS && got == n;
}
static uint64_t lrd64(uint64_t a) { uint64_t v = 0; return lrd(a, &v, 8) ? v : 0; }
static uint32_t lrd32(uint64_t a) { uint32_t v = 0; return lrd(a, &v, 4) ? v : 0; }

static bool ptr_ok(uint64_t p) { return p >= 0x100000000ULL && p < 0x8000000000ULL && (p & 7) == 0; }

// ---- FName ----
static bool fname(uint32_t idx, char* out, size_t cap) {
    if (!out || cap < 2) return false;
    out[0] = 0;
    if (!gNames || (idx >> 16) >= 8192) return false;
    uint64_t block = lrd64(gNames + 0x10 + (uint64_t)(idx >> 16) * 8);
    if (!block) return false;
    uint64_t e = block + (uint64_t)gStride * (idx & 0xFFFF);
    uint16_t h = 0;
    if (!lrd(e, &h, 2)) return false;
    uint32_t len = (h >> 1) & 0x3FF;
    if (!len || len > 512) return false;
    uint32_t n = (len < cap - 1) ? len : (uint32_t)(cap - 1);
    if (h & 1) {
        for (uint32_t i = 0; i < n; i++) {
            uint16_t ch = 0;
            if (!lrd(e + 2 + (uint64_t)i * 2, &ch, 2)) { out[i] = 0; return i > 0; }
            out[i] = (ch < 0x80) ? (char)ch : '?';
        }
    } else {
        if (!lrd(e + 2, out, n)) return false;
    }
    out[n] = 0;
    return true;
}
static bool cls_of(uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    uint64_t c = lrd64(obj + 0x10);
    return c ? fname(lrd32(c + 0x18), out, cap) : false;
}
static bool own_of(uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    return fname(lrd32(obj + 0x18), out, cap);
}

// ---- FNamePool discovery: scan whole __DATA, try both header layouts ----
static uint64_t find_gnames(void) {
    const struct mach_header_64* mh = (const struct mach_header_64*)_dyld_get_image_header(0);
    const uint8_t* p = (const uint8_t*)mh;
    // vmaddr in load commands is the LINK-TIME address; add the slide to get the
    // runtime address (slide = image header addr - 0x100000000)
    const uint64_t slide = (uint64_t)mh - kStaticBase;
    L(@"slide = 0x%llx", slide);
    uint64_t segStart = 0, segEnd = 0;
    {
        const struct load_command* lc = (const struct load_command*)(p + sizeof(*mh));
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64* s = (const struct segment_command_64*)lc;
                if (strcmp(s->segname, "__DATA") == 0) { segStart = s->vmaddr + slide; segEnd = s->vmaddr + s->vmsize + slide; }
            }
            lc = (const struct load_command*)((const uint8_t*)lc + lc->cmdsize);
        }
    }
    if (!segStart) return 0;
    L(@"gnames scan __DATA 0x%llx..0x%llx", segStart, segEnd);

    // __DATA is fully mapped in our own address space: walk it in 1MB blocks
    // with direct memory access (vm_read per 8 bytes would be ~4.5M syscalls).
    const size_t kChunk = 1u << 20;
    int tried = 0;
    for (uint64_t base = segStart; base + 8 <= segEnd; base += kChunk) {
        size_t n = (size_t)((segEnd - base) < kChunk ? (segEnd - base) : kChunk);
        uint8_t* chunk = (uint8_t*)malloc(n);
        if (!chunk) { L(@"oom"); return 0; }
        if (!lrd(base, chunk, n)) { free(chunk); continue; }
        for (size_t o = 0; o + 8 <= n; o += 8) {
            uint64_t v;
            memcpy(&v, chunk + o, 8);
            if (!ptr_ok(v)) continue;
            if (++tried > 400000) { L(@"gnames: cap 400000"); return 0; }
            uint64_t b0 = lrd64(v + 0x10);            // Entries.Blocks[0]
            if (!ptr_ok(b0)) continue;
            char probe[24];
            if (!lrd(b0, probe, sizeof(probe))) continue;
            for (int st = 2; st <= 4; st += 2) {
                int hdr = (st == 2) ? 2 : 4;
                if (memcmp(probe + hdr, "None", 4) == 0) {
                    gStride = st;
                    L(@"GNames = 0x%llx (stride=%d, slot=0x%llx)", v, st, base + o);
                    free(chunk);
                    return v;
                }
            }
        }
        free(chunk);
    }
    L(@"gnames not found (tried=%d)", tried);
    return 0;
}

// ---- chain discovery ----
static void scan_fields_for(uint64_t obj, uint64_t maxOff, const char* want, const char* tag) {
    for (uint64_t off = 0; off < maxOff; off += 8) {
        uint64_t q = lrd64(obj + off);
        if (!ptr_ok(q)) continue;
        char c[128];
        if (!cls_of(q, c, sizeof(c))) continue;
        if (strstr(c, want)) {
            char o[128] = {0};
            own_of(q, o, sizeof(o));
            L(@"[%s] +0x%llx -> 0x%llx class=%s name=%s", tag, off, q, c, o);
        }
    }
}

// find a TArray<ptr> inside obj: {Data,Num,Max} with plausible Num
static void find_ptr_array(uint64_t obj, uint64_t maxOff, const char* tag) {
    for (uint64_t off = 0; off + 16 < maxOff; off += 8) {
        uint64_t data = lrd64(obj + off);
        uint32_t num  = lrd32(obj + off + 8);
        uint32_t max  = lrd32(obj + off + 12);
        if (!ptr_ok(data) || num == 0 || num > 20000 || max < num || max > num + 4096) continue;
        uint64_t e0 = lrd64(data);
        if (!ptr_ok(e0)) continue;
        char c0[128] = {0}, o0[128] = {0};
        if (!cls_of(e0, c0, sizeof(c0))) continue;
        if (strcmp(c0, "Object") == 0 || c0[0] == 0) continue;
        own_of(e0, o0, sizeof(o0));
        L(@"[%s] TArray +0x%llx  Num=%u Max=%u  [0]=%s/%s", tag, off, num, max, c0, o0);
        // dump a few more
        for (int k = 1; k < 4 && k < (int)num; k++) {
            uint64_t ek = lrd64(data + (uint64_t)k * 8);
            char ck[128] = {0};
            if (ptr_ok(ek) && cls_of(ek, ck, sizeof(ck))) L(@"    [%d] %s", k, ck);
        }
    }
}

__attribute__((constructor))
static void inprobe_init(void) {
    @autoreleasepool {
        gSock = socket(AF_INET, SOCK_DGRAM, 0);
        memset(&gAddr, 0, sizeof(gAddr));
        gAddr.sin_family = AF_INET;
        gAddr.sin_port = htons(kUdpPort);
        gAddr.sin_addr.s_addr = inet_addr("127.0.0.1");

        gBase = (uint64_t)_dyld_get_image_header(0);
        L(@"=== inprobe v3 pid=%d base=0x%llx ===", getpid(), gBase);

        // engine needs time; ACE kills us around 60s, so start at 12s and be quick
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            uint64_t engine = lrd64(gBase + (kOffGEngine - kStaticBase));
            L(@"GEngine = 0x%llx (vtable 0x%llx)", engine, lrd64(engine));
            if (!engine) { L(@"no engine yet"); return; }

            gNames = find_gnames();
            if (gNames) {
                char e[128] = {0};
                if (cls_of(engine, e, sizeof(e))) L(@"GEngine class = %s", e);
            }

            // 1) GEngine -> World / GameViewport / GameInstance
            L(@"--- scan GEngine 0x0..0x1400 ---");
            scan_fields_for(engine, 0x1400, "World", "GEngine");
            scan_fields_for(engine, 0x1400, "Viewport", "GEngine");
            scan_fields_for(engine, 0x1400, "GameInstance", "GEngine");

            // Fallback that does not need FName: any field pointing at an object
            // whose vtable lives inside the image is a UObject.
            if (!gNames) {
                L(@"--- fallback: engine fields with vtable in image ---");
                uint64_t imgLo = gBase, imgHi = gBase + 0x14000000ULL;
                for (uint64_t off = 0; off < 0x1400; off += 8) {
                    uint64_t q = lrd64(engine + off);
                    if (!ptr_ok(q)) continue;
                    uint64_t vt = lrd64(q);
                    if (vt < imgLo || vt >= imgHi) continue;
                    L(@"+0x%llx -> 0x%llx vt=0x%llx", off, q, vt);
                }
            }

            // 2) from each World-ish field, look for Level
            for (uint64_t off = 0; off < 0x1400; off += 8) {
                uint64_t q = lrd64(engine + off);
                if (!ptr_ok(q)) continue;
                char c[128];
                if (!cls_of(q, c, sizeof(c))) continue;
                if (strcmp(c, "World") != 0) continue;
                L(@"=== World at GEngine+0x%llx -> 0x%llx ===", off, q);
                scan_fields_for(q, 0x800, "Level", "World");
                for (uint64_t o2 = 0; o2 < 0x800; o2 += 8) {
                    uint64_t lv = lrd64(q + o2);
                    if (!ptr_ok(lv)) continue;
                    char c2[128];
                    if (!cls_of(lv, c2, sizeof(c2))) continue;
                    if (strcmp(c2, "Level") != 0) continue;
                    L(@"=== Level at World+0x%llx -> 0x%llx ===", o2, lv);
                    find_ptr_array(lv, 0x600, "Level");
                    // actor -> mesh
                    uint64_t data = lrd64(lv + 0x0);   // filled below by scan
                    (void)data;
                    for (uint64_t o3 = 0; o3 < 0x600; o3 += 8) {
                        uint64_t d = lrd64(lv + o3);
                        uint32_t n = lrd32(lv + o3 + 8);
                        uint32_t mx = lrd32(lv + o3 + 12);
                        if (!ptr_ok(d) || n < 5 || n > 20000 || mx < n || mx > n + 4096) continue;
                        uint64_t a0 = lrd64(d);
                        if (!ptr_ok(a0)) continue;
                        char ac[128] = {0};
                        if (!cls_of(a0, ac, sizeof(ac))) continue;
                        if (!strstr(ac, "Actor") && !strstr(ac, "Character")) continue;
                        L(@"=== Actors array at Level+0x%llx Num=%u first=%s ===", o3, n, ac);
                        scan_fields_for(a0, 0x800, "SkeletalMesh", "Actor");
                        scan_fields_for(a0, 0x800, "Mesh", "Actor");
                        break;
                    }
                }
            }
            L(@"=== done ===");
        });
    }
}
