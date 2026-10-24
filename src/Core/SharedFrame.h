// SharedFrame.h —— 读写分离用的共享内存帧通道（架构 1）
//
// 两个进程：
//   生产者 = TrollStore app / 常驻进程（未沙盒，用 kfd 读游戏内存、算世界坐标）
//   消费者 = 游戏进程内的极薄渲染层（只读这块内存、画框、present）
//
// 设计要点：
//   ★ seqlock 而不是跨进程 mutex：写端崩溃不会把读端卡死，无优先级反转，无锁
//   ★ 传世界坐标 + 相机 POV，W2S 放渲染端（渲染端才知道 viewport 尺寸）
//   ★ magic + tick 双校验，任何一项不过就整帧丢弃，绝不画垃圾
//   ★ 名字伪装成缓存文件风格，生命周期短，用完 shm_unlink

#pragma once
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>

namespace shframe {

static constexpr uint32_t kMagic   = 0x41524631;  // "ARF1"
static constexpr uint32_t kVersion = 1;
static constexpr int      kMaxEnt  = 128;
static constexpr uint32_t kStaleMs = 500;         // 超过这个时间没更新视为断流

struct Ent {
    float   x, y, z;        // 世界坐标（UE4 单位 cm）
    float   hp;             // <=0 表示未知
    uint8_t team;
    uint8_t alive;
    uint8_t _pad[2];
};

struct Header {
    uint32_t magic;
    uint32_t version;
    uint32_t seq;           // seqlock：奇数=正在写，偶数=稳定
    uint32_t count;
    // 相机
    float    camX, camY, camZ;
    float    yaw, pitch, fov;
    // 元信息
    uint64_t tickMs;        // 生产者更新时刻
    uint32_t localTeam;
    uint32_t _pad2;
};

struct Frame {
    Header h;
    Ent    ents[kMaxEnt];
};

static inline uint64_t now_ms() {
    struct timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

// ---------------- 生产者 ----------------
struct Writer {
    Frame* f = nullptr;
    size_t size = 0;
    char   name[64] = {0};

    bool open_shm(const char* shmName) {
        snprintf(name, sizeof(name), "%s", shmName);
        size = sizeof(Frame);
        int fd = shm_open(name, O_CREAT | O_RDWR, 0600);
        if (fd < 0) return false;
        if (ftruncate(fd, (off_t)size) != 0) { close(fd); return false; }
        void* p = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) return false;
        f = (Frame*)p;
        memset(f, 0, size);
        f->h.magic = kMagic;
        f->h.version = kVersion;
        return true;
    }

    // 写一帧。内部自动做 seq 奇偶切换。
    void publish(const Header& meta, const Ent* ents, uint32_t n) {
        if (!f) return;
        if (n > (uint32_t)kMaxEnt) n = kMaxEnt;
        __atomic_fetch_add(&f->h.seq, 1, __ATOMIC_RELEASE);   // -> 奇数，开始写
        __atomic_thread_fence(__ATOMIC_RELEASE);

        f->h.magic   = kMagic;
        f->h.version = kVersion;
        f->h.count   = n;
        f->h.camX = meta.camX; f->h.camY = meta.camY; f->h.camZ = meta.camZ;
        f->h.yaw = meta.yaw;   f->h.pitch = meta.pitch; f->h.fov = meta.fov;
        f->h.localTeam = meta.localTeam;
        f->h.tickMs = now_ms();
        if (n && ents) memcpy(f->ents, ents, n * sizeof(Ent));

        __atomic_thread_fence(__ATOMIC_RELEASE);
        __atomic_fetch_add(&f->h.seq, 1, __ATOMIC_RELEASE);   // -> 偶数，写完
    }

    void close_shm() {
        if (f) { munmap(f, size); f = nullptr; }
        if (name[0]) { shm_unlink(name); name[0] = 0; }
    }
};

// ---------------- 消费者 ----------------
struct Reader {
    const Frame* f = nullptr;
    size_t size = 0;
    int    fd = -1;

    bool open_shm(const char* shmName) {
        size = sizeof(Frame);
        fd = shm_open(shmName, O_RDONLY, 0);
        if (fd < 0) return false;
        void* p = mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) { close(fd); fd = -1; return false; }
        f = (const Frame*)p;
        return true;
    }

    // 取一帧快照。返回 false 表示本帧不可用（未就绪/断流/正在写）。
    bool snapshot(Frame& out) {
        if (!f) return false;
        uint32_t s1 = __atomic_load_n(&f->h.seq, __ATOMIC_ACQUIRE);
        if (s1 & 1) return false;                     // 正在写
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        memcpy(&out, (const void*)f, sizeof(Frame));
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        uint32_t s2 = __atomic_load_n(&f->h.seq, __ATOMIC_ACQUIRE);
        if (s1 != s2) return false;                   // 读期间被写，丢弃

        if (out.h.magic != kMagic || out.h.version != kVersion) return false;
        if (out.h.count > (uint32_t)kMaxEnt) return false;
        if (now_ms() - out.h.tickMs > kStaleMs) return false;   // 断流
        return true;
    }

    void close_shm() {
        if (f) { munmap((void*)f, size); f = nullptr; }
        if (fd >= 0) { close(fd); fd = -1; }
    }
};

} // namespace shframe
