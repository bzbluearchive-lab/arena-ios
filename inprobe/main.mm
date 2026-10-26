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

    // FNamePool::Entries.Blocks[] offset differs by platform: on Darwin FRWLock is
    // pthread_rwlock_t (200 bytes) so Blocks lands near +0xD0, not +0x10.
    static const int kBlockOffs[] = { 0xD0, 0xD8, 0x10, 0x18, 0x08, 0xC8, 0x108, 0x110 };
    const int nOffs = (int)(sizeof(kBlockOffs) / sizeof(kBlockOffs[0]));
    const size_t kChunk = 1u << 20;
    int tried = 0;
    uint64_t lastA = 0;

    for (uint64_t base = segStart; base + 8 <= segEnd; base += kChunk) {
        size_t n = (size_t)((segEnd - base) < kChunk ? (segEnd - base) : kChunk);
        uint8_t* chunk = (uint8_t*)malloc(n);
        if (!chunk) { L(@"oom"); return 0; }
        if (!lrd(base, chunk, n)) { free(chunk); continue; }

        for (size_t o = 0; o + 8 <= n; o += 8) {
            for (int k = 0; k < nOffs; k++) {
                size_t bo = o + kBlockOffs[k];
                if (bo + 8 > n) continue;
                uint64_t b0;
                memcpy(&b0, chunk + bo, 8);
                if (!ptr_ok(b0)) continue;
                if (++tried > 3000000) { L(@"gnames: cap"); free(chunk); return 0; }
                char probe[24];
                if (!lrd(b0, probe, sizeof(probe))) continue;
                for (int st = 2; st <= 4; st += 2) {
                    int hdr = (st == 2) ? 2 : 4;
                    if (memcmp(probe + hdr, "None", 4) == 0) {
                        gStride = st;
                        L(@"GNames = 0x%llx (blocksOff=0x%x stride=%d slot=0x%llx)",
                          base + o, kBlockOffs[k], st, base + o);
                        free(chunk);
                        return base + o;
                    }
                }
            }
        }
        free(chunk);
        lastA = base;
    }
    L(@"gnames scan ended at 0x%llx", lastA);    L(@"gnames not found (tried=%d)", tried);
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
            // ---- name-free structural discovery ----
            // A UWorld holds TArray<ULevel*> (tiny Num) and a ULevel holds
            // TArray<AActor*> (large Num, many distinct vtables). Walk engine
            // fields one level down and report such arrays with their numbers.
            L(@"--- structural scan (no names needed) ---");
            uint64_t imgLo2 = gBase, imgHi2 = gBase + 0x14000000ULL;
            for (uint64_t eo = 0; eo < 0x1400; eo += 8) {
                uint64_t obj = lrd64(engine + eo);
                if (!ptr_ok(obj)) continue;
                uint64_t vt = lrd64(obj);
                if (vt < imgLo2 || vt >= imgHi2) continue;

                for (uint64_t ao = 0; ao + 16 < 0x1000; ao += 8) {
                    uint64_t data = lrd64(obj + ao);
                    uint32_t num  = lrd32(obj + ao + 8);
                    uint32_t max  = lrd32(obj + ao + 12);
                    if (!ptr_ok(data) || num < 8 || num > 40000 || max < num || max > num + 8192) continue;
                    uint64_t e0 = lrd64(data);
                    if (!ptr_ok(e0)) continue;
                    uint64_t v0 = lrd64(e0);
                    if (v0 < imgLo2 || v0 >= imgHi2) continue;

                    // count distinct vtables in the first 64 elements
                    uint64_t seen[8];
                    int nseen = 0;
                    uint32_t lim = num < 64 ? num : 64;
                    for (uint32_t k = 0; k < lim && nseen < 8; k++) {
                        uint64_t ek = lrd64(data + (uint64_t)k * 8);
                        if (!ptr_ok(ek)) continue;
                        uint64_t vk = lrd64(ek);
                        if (vk < imgLo2 || vk >= imgHi2) continue;
                        bool dup = false;
                        for (int s = 0; s < nseen; s++) if (seen[s] == vk) { dup = true; break; }
                        if (!dup) seen[nseen++] = vk;
                    }
                    L(@"[S] E+0x%llx obj=0x%llx +0x%llx Num=%u Max=%u distinctVT=%d vt0=0x%llx",
                      eo, obj, ao, num, max, nseen, v0);

                    // one more level: look for a big array inside the element
                    for (uint64_t bo = 0; bo + 16 < 0x1000; bo += 8) {
                        uint64_t d2 = lrd64(e0 + bo);
                        uint32_t n2 = lrd32(e0 + bo + 8);
                        uint32_t m2 = lrd32(e0 + bo + 12);
                        if (!ptr_ok(d2) || n2 < 8 || n2 > 40000 || m2 < n2 || m2 > n2 + 8192) continue;
                        uint64_t f0 = lrd64(d2);
                        if (!ptr_ok(f0)) continue;
                        uint64_t vf = lrd64(f0);
                        if (vf < imgLo2 || vf >= imgHi2) continue;
                        L(@"[S2]   elem+0x%llx inner Num=%u Max=%u vt=0x%llx", bo, n2, m2, vf);
                    }
                }
            }

            // ================= deep scan: actor -> component -> bones =================
            // No names needed. FTransform is 0x30 bytes: FQuat(16) + FVector(12) + FVector(12).
            // A skeletal mesh component holds TArray<FTransform> with Num in the 40..400 range.
            L(@"--- deep scan: bone arrays (FTransform stride 0x30) ---");

            int actorArrays = 0;
            for (uint64_t eo = 0; eo < 0x1400 && actorArrays < 4; eo += 8) {
                uint64_t world = lrd64(engine + eo);
                if (!ptr_ok(world)) continue;
                uint64_t wvt = lrd64(world);
                if (wvt < imgLo2 || wvt >= imgHi2) continue;

                for (uint64_t ao = 0; ao + 16 < 0x1000; ao += 8) {
                    uint64_t data = lrd64(world + ao);
                    uint32_t num  = lrd32(world + ao + 8);
                    uint32_t max  = lrd32(world + ao + 12);
                    if (!ptr_ok(data) || num < 8 || num > 40000 || max < num || max > num + 8192) continue;
                    uint64_t e0 = lrd64(data);
                    if (!ptr_ok(e0)) continue;
                    uint64_t v0 = lrd64(e0);
                    if (v0 < imgLo2 || v0 >= imgHi2) continue;

                    // distinct vtables -> actor-like array?
                    uint64_t seen[8]; int nseen = 0;
                    uint32_t lim = num < 64 ? num : 64;
                    for (uint32_t k = 0; k < lim && nseen < 8; k++) {
                        uint64_t ek = lrd64(data + (uint64_t)k * 8);
                        if (!ptr_ok(ek)) continue;
                        uint64_t vk = lrd64(ek);
                        if (vk < imgLo2 || vk >= imgHi2) continue;
                        bool dup = false;
                        for (int s = 0; s < nseen; s++) if (seen[s] == vk) { dup = true; break; }
                        if (!dup) seen[nseen++] = vk;
                    }
                    if (nseen < 3) continue;             // actors come in many classes
                    actorArrays++;
                    L(@"[A] GEngine+0x%llx -> 0x%llx  arr+0x%llx Num=%u distinctVT=%d", eo, world, ao, num, nseen);

                    // inspect up to 3 actors
                    for (uint32_t ai = 0; ai < 3 && ai < num; ai++) {
                        uint64_t act = lrd64(data + (uint64_t)ai * 8);
                        if (!ptr_ok(act)) continue;
                        uint64_t avt = lrd64(act);
                        if (avt < imgLo2 || avt >= imgHi2) continue;
                        L(@"[A%d] actor=0x%llx vt=0x%llx", ai, act, avt);

                        // components: objects inside the actor
                        int comps = 0;
                        for (uint64_t co = 0; co < 0x1000 && comps < 40; co += 8) {
                            uint64_t comp = lrd64(act + co);
                            if (!ptr_ok(comp)) continue;
                            uint64_t cvt = lrd64(comp);
                            if (cvt < imgLo2 || cvt >= imgHi2) continue;
                            comps++;

                            // does this component hold a bone transform array?
                            for (uint64_t bo = 0; bo + 16 < 0x1000; bo += 8) {
                                uint64_t bd = lrd64(comp + bo);
                                uint32_t bn = lrd32(comp + bo + 8);
                                uint32_t bm = lrd32(comp + bo + 12);
                                if (!ptr_ok(bd) || bn < 20 || bn > 600 || bm < bn || bm > bn + 1024) continue;
                                // verify 3 transforms look like FTransform (quat + pos + scale)
                                uint8_t tf[0x30 * 3];
                                if (!lrd(bd, tf, sizeof(tf))) continue;
                                float* f0 = (float*)(tf);
                                float* f1 = (float*)(tf + 0x30);
                                float* f2 = (float*)(tf + 0x60);
                                bool okq = true;
                                float* fs[3] = { f0, f1, f2 };
                                for (int s2 = 0; s2 < 3 && okq; s2++) {
                                    float x = fs[s2][0], y = fs[s2][1], z = fs[s2][2], w = fs[s2][3];
                                    if (!(x > -2 && x < 2 && y > -2 && y < 2 && z > -2 && z < 2 && w > -2 && w < 2)) okq = false;
                                    float sx = fs[s2][12], sy = fs[s2][13], sz = fs[s2][14];
                                    if (!(sx > 0.01f && sx < 100 && sy > 0.01f && sy < 100 && sz > 0.01f && sz < 100)) okq = false;
                                }
                                if (!okq) continue;
                                L(@"[B]   comp+0x%llx boneArray Num=%u Max=%u pos=(%.1f,%.1f,%.1f)",
                                  bo, bn, bm, f0[4], f0[5], f0[6]);
                            }
                        }
                        L(@"[A%d] components=%d", ai, comps);
                    }
                    if (actorArrays >= 4) break;
                }
            }
            if (actorArrays == 0) L(@"[A] no multi-vtable array found");

            L(@"=== done ===");
        });
    }
}
