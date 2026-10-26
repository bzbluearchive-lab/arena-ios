// inprobe/main.mm - one-shot in-game offset probe (runs inside the game process)
//
// All offsets below come from static analysis of UAGame_1.0.249_decrypted and are
// verified by the runtime log this file produces. ACE kills the dylib ~60s after
// entering a match, so everything runs in a single pass starting at 12s.
//
// Chain used:
//   GEngine (global 0x10dbf9a58)
//     -> UEngine::GetWorldFromContextObject (fn 0x104cb57b8) -> UWorld*
//        fallback: UEngine::GameViewport (0x788)
//     -> UWorld::PersistentLevel (0x30) -> ULevel*
//     -> ULevel::Actors (0x28) -> TArray<AActor*>
//     -> ACharacter::Mesh (0x418) -> USkeletalMeshComponent*
//     -> bone transforms TArray<FTransform> (0x30 stride) - located at runtime
//
// FName resolution (verified statically):
//   FNamePool global 0x10d90d840 (struct in __bss, NOT a pointer)
//   Entries.Blocks[] at +0xD8 ; entry header u16, bit0=wide, len=hdr>>6, text@+2
//   id split: block = id>>16, byte offset = (id & 0xFFFF) * 2
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
#include <dlfcn.h>
extern "C" int hide_self_image(void);

static const uint64_t kStaticBase = 0x100000000ULL;
static const uint64_t kOffGEngine = 0x10dbf9a58ULL;
static const uint64_t kOffGNames  = 0x10d90d840ULL;
static const uint32_t kGNamesBlocksOff = 0xD8;
static const uint64_t kOffGetWorld = 0x104cb57b8ULL;   // UEngine::GetWorldFromContextObject

static const uint32_t kOffEngineGameViewport = 0x788;
static const uint32_t kOffWorldPersistentLevel = 0x30;
static const uint32_t kOffLevelActors = 0x28;
static const uint32_t kOffCharacterMesh = 0x418;

static const int kUdpPort = 45999;

static uint64_t gBase = 0, gNames = 0, gEngine = 0;
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

// ---- memory ----
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
static bool fname(uint32_t id, char* out, size_t cap) {
    if (!out || cap < 2) return false;
    out[0] = 0;
    if (!gNames) return false;
    uint32_t blk = id >> 16;
    if (blk >= 8192) return false;
    uint64_t blkPtr = lrd64(gNames + kGNamesBlocksOff + (uint64_t)blk * 8);
    if (!ptr_ok(blkPtr)) return false;
    uint64_t entry = blkPtr + (uint64_t)(id & 0xFFFF) * 2;
    uint16_t h = 0;
    if (!lrd(entry, &h, 2)) return false;
    uint32_t len = (h >> 6) & 0x3FF;
    if (!len) { out[0] = 0; return true; }
    uint32_t n = (len < cap - 1) ? len : (uint32_t)(cap - 1);
    if (h & 1) {
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
static bool cls_of(uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    uint64_t c = lrd64(obj + 0x10);          // UObject::ClassPrivate
    return c ? fname(lrd32(c + 0x18), out, cap) : false;
}
static bool own_of(uint64_t obj, char* out, size_t cap) {
    out[0] = 0;
    return fname(lrd32(obj + 0x18), out, cap);
}

// ---- bone array detection: TArray<FTransform>, stride 0x30 ----
__attribute__((unused)) static bool looks_transform_array(uint64_t comp, uint64_t off, uint32_t* outNum) {
    uint64_t data = lrd64(comp + off);
    uint32_t num  = lrd32(comp + off + 8);
    uint32_t max  = lrd32(comp + off + 12);
    if (!ptr_ok(data) || num < 20 || num > 600 || max < num || max > num + 2048) return false;
    uint8_t tf[0x30 * 3];
    if (!lrd(data, tf, sizeof(tf))) return false;
    for (int s = 0; s < 3; s++) {
        float* f = (float*)(tf + 0x30 * s);
        // FTransform: FQuat(16) + FVector Translation(12) + FVector Scale(12)
        if (!(f[0] > -2 && f[0] < 2 && f[1] > -2 && f[1] < 2 &&
              f[2] > -2 && f[2] < 2 && f[3] > -2 && f[3] < 2)) return false;
        if (!(f[12] > 0.01f && f[12] < 100 && f[13] > 0.01f && f[13] < 100 &&
              f[14] > 0.01f && f[14] < 100)) return false;
    }
    *outNum = num;
    return true;
}

// ---- world acquisition ----
static uint64_t world_via_engine_fn(void) {
    uint64_t fn = gBase + (kOffGetWorld - kStaticBase);
    if (!fn) return 0;
    typedef uint64_t (*getworld_t)(uint64_t, uint64_t, int);
    getworld_t f = (getworld_t)fn;
    uint64_t w = 0;
    @try { w = f(gEngine, gEngine, 0); } @catch (...) { w = 0; }
    return ptr_ok(w) ? w : 0;
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

        // ---- mode switch: Documents/probe_mode.txt ----
        //   "noop"    : do nothing but log (test whether injection itself is detected)
        //   "stealth" : hide our image from dyld enumeration, then probe
        //   (missing) : same as stealth
        {
            NSString* docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString* modePath = [docs stringByAppendingPathComponent:@"probe_mode.txt"];
            NSString* mode = @"stealth";
            if ([[NSFileManager defaultManager] fileExistsAtPath:modePath]) {
                NSString* s = [NSString stringWithContentsOfFile:modePath encoding:NSUTF8StringEncoding error:nil];
                if (s) {
                    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (s.length) mode = s;
                }
            }
            L(@"mode = %@", mode);
            if ([mode isEqualToString:@"noop"]) {
                L(@"noop mode: no hooks, no probing, no threads");
                return;
            }
            int patched = hide_self_image();
            L(@"image hiding: patched %d pointers (selfIndex=%u)", patched, 0u);
        }

        // optional hot-reload of logic from Documents (cheap iteration if allowed)
        {
            NSString* docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString* ext = [docs stringByAppendingPathComponent:@"probe2.dylib"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:ext]) {
                void* h = dlopen([ext UTF8String], RTLD_NOW);
                if (h) L(@"external probe2.dylib loaded");
                else   L(@"external dlopen failed: %s", dlerror() ?: "?");
            }
        }

        L(@"=== inprobe v9 pid=%d base=0x%llx slide=0x%llx ===", getpid(), gBase, gBase - kStaticBase);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            gNames  = gBase + (kOffGNames  - kStaticBase);
            gEngine = lrd64(gBase + (kOffGEngine - kStaticBase));
            L(@"GNames=0x%llx GEngine=0x%llx", gNames, gEngine);
            if (!gEngine) { L(@"no engine"); return; }

            char nm[160];
            memset(nm, 0, sizeof(nm));
            if (cls_of(gEngine, nm, sizeof(nm))) L(@"GEngine class=%s", nm);
            memset(nm, 0, sizeof(nm));
            if (own_of(gEngine, nm, sizeof(nm))) L(@"GEngine name=%s", nm);

            // ---- world ----
            uint64_t world = world_via_engine_fn();
            L(@"world via GetWorldFromContextObject = 0x%llx", world);
            if (!world) {
                uint64_t vp = lrd64(gEngine + kOffEngineGameViewport);
                L(@"fallback GameViewport(+0x%x) = 0x%llx", kOffEngineGameViewport, vp);
                if (ptr_ok(vp)) {
                    memset(nm, 0, sizeof(nm));
                    if (cls_of(vp, nm, sizeof(nm))) L(@"  viewport class=%s", nm);
                }
            }
            if (!world) { L(@"=== no world ==="); return; }
            memset(nm, 0, sizeof(nm));
            if (cls_of(world, nm, sizeof(nm))) L(@"world class=%s", nm);

            // ---- level ----
            uint64_t level = lrd64(world + kOffWorldPersistentLevel);
            L(@"PersistentLevel(world+0x%x) = 0x%llx", kOffWorldPersistentLevel, level);
            if (!ptr_ok(level)) { L(@"=== no level ==="); return; }
            memset(nm, 0, sizeof(nm));
            if (cls_of(level, nm, sizeof(nm))) L(@"level class=%s", nm);

            // ---- actors ----
            uint64_t data = lrd64(level + kOffLevelActors);
            uint32_t num  = lrd32(level + kOffLevelActors + 8);
            uint32_t max  = lrd32(level + kOffLevelActors + 12);
            L(@"Actors(level+0x%x) data=0x%llx Num=%u Max=%u", kOffLevelActors, data, num, max);
            if (!ptr_ok(data) || num == 0 || num > 40000) { L(@"=== bad actors ==="); return; }

            // class distribution of the first 200 actors
            int withMesh = 0, boneFound = 0;
            uint32_t limit = num < 200 ? num : 200;
            for (uint32_t i = 0; i < limit; i++) {
                uint64_t act = lrd64(data + (uint64_t)i * 8);
                if (!ptr_ok(act)) continue;
                char ac[160];
                memset(ac, 0, sizeof(ac));
                if (!cls_of(act, ac, sizeof(ac))) continue;
                if (i < 8) {
                    char ao[160];
                    memset(ao, 0, sizeof(ao));
                    own_of(act, ao, sizeof(ao));
                    L(@"[A%u] 0x%llx class=%s name=%s", i, act, ac, ao);
                }

                uint64_t mesh = lrd64(act + kOffCharacterMesh);
                if (!ptr_ok(mesh)) continue;
                char mc[160];
                memset(mc, 0, sizeof(mc));
                if (!cls_of(mesh, mc, sizeof(mc))) continue;
                withMesh++;

                // Bone arrays verified statically on this build:
                //   0x9B8 CachedComponentSpaceTransforms {Data,Num@0x9C0,Max@0x9C4}
                //   0x940 BoneSpaceTransforms (live)     {Data,Num@0x948}
                //   0x9A8 CachedBoneSpaceTransforms      {Data,Num@0x9B0}
                // element = FTransform, 0x30 bytes: FQuat16 + Translation12 + Scale12
                static const uint64_t kBoneOffs[] = { 0x9B8, 0x940, 0x9A8 };
                uint32_t bn = 0;
                uint64_t hit = 0;
                for (int bi = 0; bi < 3; bi++) {
                    uint32_t n2 = lrd32(mesh + kBoneOffs[bi] + 8);
                    uint64_t d2 = lrd64(mesh + kBoneOffs[bi]);
                    if (ptr_ok(d2) && n2 >= 8 && n2 <= 1200) { hit = kBoneOffs[bi]; bn = n2; break; }
                }
                if (hit) {
                    boneFound++;
                    uint64_t bd = lrd64(mesh + hit);
                    uint8_t tf[0x30];
                    memset(tf, 0, sizeof(tf));
                    lrd(bd, tf, sizeof(tf));
                    float* f = (float*)tf;
                    L(@"[B] actor[%u] mesh=0x%llx(%s) boneOff=0x%llx Num=%u bone0.quat=(%.2f,%.2f,%.2f,%.2f) bone0.pos=(%.1f,%.1f,%.1f)",
                      i, mesh, mc, hit, bn, f[0], f[1], f[2], f[3], f[4], f[5], f[6]);

                    // verify ComponentToWorld candidate (0x270 unproven): a real C2W must be a
                    // unit-quaternion FTransform with sane scale, and its translation should be
                    // within world bounds. Scan a window and report all plausible candidates.
                    for (uint64_t co = 0x200; co < 0x400; co += 0x10) {
                        uint8_t ct[0x30];
                        memset(ct, 0, sizeof(ct));
                        if (!lrd(mesh + co, ct, sizeof(ct))) continue;
                        float* g = (float*)ct;
                        float qn = g[0]*g[0] + g[1]*g[1] + g[2]*g[2] + g[3]*g[3];
                        if (!(qn > 0.9f && qn < 1.1f)) continue;
                        if (!(g[12] > 0.01f && g[12] < 100 && g[13] > 0.01f && g[13] < 100 && g[14] > 0.01f && g[14] < 100)) continue;
                        if (!(g[4] > -2000000 && g[4] < 2000000 && g[5] > -2000000 && g[5] < 2000000 && g[6] > -2000000 && g[6] < 2000000)) continue;
                        if (g[4] == 0 && g[5] == 0 && g[6] == 0) continue;
                        L(@"[C2W] mesh+0x%llx quat=(%.2f,%.2f,%.2f,%.2f) pos=(%.1f,%.1f,%.1f) scale=(%.2f,%.2f,%.2f)",
                          co, g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[12], g[13], g[14]);
                    }
                } else if (withMesh <= 6) {
                    L(@"[M] actor[%u] mesh=0x%llx(%s) none of 0x9B8/0x940/0x9A8 has a valid array", i, mesh, mc);
                }                if (boneFound >= 6) break;
            }
            L(@"summary: actors=%u scanned=%u withMesh=%d boneArrays=%d", num, limit, withMesh, boneFound);
            L(@"=== done ===");
        });
    }
}
