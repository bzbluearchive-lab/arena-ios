#include "World.hpp"
#include "Offsets.hpp"
#include "../Core/SafeMem.h"
#include <cmath>

namespace world {

static Context g_ctx;

// ---------------- 引擎链解析 ----------------
// 优先走 GEngine -> GameViewportClient/GameInstance -> World 的链，
// 裸 off::GWorld 只作为兜底，且必须通过与链式结果对比才采信。
Context resolve() {
    Context c;

    // 1) GEngine
    uintptr_t ge = off::GEngine ? mem::rdptr(off::GEngine) : 0;
    if (!ge) ge = 0;                 // 特征码没填时保持 0，由上层日志提示
    c.gengine = ge;

    // 2) GameViewportClient -> World
    if (ge) {
        uintptr_t gvc = mem::rdptr(ge + off::UENGINE_GAMEVIEWPORT);
        if (gvc) c.world = mem::rdptr(gvc + off::GVC_WORLD);
    }

    // 3) GameInstance -> World（上一条失败时）
    if (ge && !c.world) {
        uintptr_t gi = mem::rdptr(ge + off::UENGINE_GAMEINSTANCE);
        if (gi) {
            c.world = mem::rdptr(gi + off::GI_WORLD);
            // LocalPlayers[0] -> PlayerController
            TArrayRaw lps{};
            if (mem::rd(gi + off::GI_LOCALPLAYERS, lps) && lps.Num > 0 && lps.Num < 8) {
                uintptr_t lp = mem::rdptr(lps.Data);
                if (lp) {
                    uintptr_t pc = mem::rdptr(lp + 0x00); // UNVERIFIED ULocalPlayer::PlayerController
                    c.pc = pc;
                }
            }
        }
    }

    // 4) 裸 GWorld 兜底 + 交叉校验
    if (!c.world && off::GWorld) {
        uintptr_t w = mem::rdptr(off::GWorld);
        TArrayRaw probe{};
        uintptr_t lvl = w ? mem::rdptr(w + off::UWORLD_PERSISTENT_LEVEL) : 0;
        if (lvl && mem::rd(lvl + off::ULEVEL_ACTORS, probe) && probe.Num > 0 && probe.Num < 4096)
            c.world = w;
    }

    if (c.world) c.level = mem::rdptr(c.world + off::UWORLD_PERSISTENT_LEVEL);

    // 5) 相机管理器
    if (c.pc) c.pcam = mem::rdptr(c.pc + off::PC_PLAYER_CAMERA_MANAGER);

    g_ctx = c;
    return c;
}

void refresh(Context& c) {
    // 世界重载（进出对局）后 world/level 会换，每帧重新解一次 level 很便宜
    if (!c.world) { c = resolve(); return; }
    uintptr_t lvl = mem::rdptr(c.world + off::UWORLD_PERSISTENT_LEVEL);
    if (lvl) c.level = lvl;
    if (!c.level) c = resolve();
    if (c.pc && !c.pcam) c.pcam = mem::rdptr(c.pc + off::PC_PLAYER_CAMERA_MANAGER);
}

// ---------------- 相机 ----------------
bool camera(const Context& c, FMinimalViewInfo& pov) {
    if (!c.pcam) return false;
    uintptr_t entry = c.pcam + off::PCM_CAMERA_CACHE;   // FCameraCacheEntry
    uintptr_t base  = entry + 0x00;                     // POV 在 entry 起始
    if (!mem::rd(base + off::POV_LOCATION, pov.Location)) return false;
    if (!mem::rd(base + off::POV_ROTATION, pov.Rotation)) return false;
    if (!mem::rd(base + off::POV_FOV, pov.FOV)) return false;
    mem::rd(base + off::POV_ASPECT, pov.AspectRatio);
    mem::rd(base + off::POV_PROJ_MODE, pov.ProjectionMode);

    // 合理性校验：FOV 在 (1,179)、坐标有限
    if (!(pov.FOV > 1.f && pov.FOV < 179.f)) return false;
    if (!std::isfinite(pov.Location.X) || !std::isfinite(pov.Location.Y) ||
        !std::isfinite(pov.Location.Z)) return false;
    if (std::fabsf(pov.Location.X) > 1e7f || std::fabsf(pov.Location.Z) > 1e7f) return false;
    return true;
}

// ---------------- 实体 ----------------
bool actors(const Context& c, std::vector<uintptr_t>& out) {
    out.clear();
    if (!c.level) return false;
    TArrayRaw arr{};
    if (!mem::rd(c.level + off::ULEVEL_ACTORS, arr)) return false;
    if (arr.Num <= 0 || arr.Num > 4096) return false;   // 链路失效的典型症状
    if (!arr.Data) return false;

    out.reserve((size_t)arr.Num);
    for (int32_t i = 0; i < arr.Num; i++) {
        uintptr_t a = mem::rdptr(arr.Data + (uintptr_t)i * sizeof(uintptr_t));
        if (!a) continue;
        // 至少要有一个可读的 RootComponent 才算活对象
        if (!mem::rdptr(a + off::ACTOR_ROOT_COMPONENT)) continue;
        out.push_back(a);
    }
    return !out.empty();
}

bool actor_location(uintptr_t actor, FVector& out) {
    uintptr_t root = mem::rdptr(actor + off::ACTOR_ROOT_COMPONENT);
    if (!root) return false;

    // 优先用 ComponentToWorld 的平移部分（FTransform: R[3][4] + T[4]，T 在 +0x30）
    uintptr_t xform = root + off::SCENE_COMPONENT_TO_WORLD;
    if (mem::read(xform + 0x30, &out, sizeof(FVector))) {
        if (std::isfinite(out.X) && std::isfinite(out.Y) && std::isfinite(out.Z) &&
            std::fabsf(out.X) < 1e7f && std::fabsf(out.Z) < 1e7f)
            return true;
    }
    // 兜底：RelativeLocation（平级组件时等价）
    return mem::rd(root + off::SCENE_RELATIVE_LOC, out);
}

bool actor_health(uintptr_t actor, float& hp) {
    if (!off::PSC_HEALTH) return false;
    uintptr_t ps = mem::rdptr(actor + off::PAWN_PLAYER_STATE);
    if (!ps) return false;
    float v = 0;
    if (!mem::rd(ps + off::PSC_HEALTH, v)) return false;
    if (!(v >= 0.f && v <= 1e6f)) return false;
    hp = v;
    return true;
}

bool actor_team(uintptr_t actor, uint8_t& team) {
    if (!off::PSC_TEAM_ID) return false;
    uintptr_t ps = mem::rdptr(actor + off::PAWN_PLAYER_STATE);
    if (!ps) return false;
    return mem::rd(ps + off::PSC_TEAM_ID, team);
}

int bone_transforms(uintptr_t actor, std::vector<float>& out) {
    out.clear();
    TArrayRaw bones{};
    uintptr_t mesh = mem::rdptr(actor + off::CHAR_MESH);
    if (!mesh) return 0;
    if (!mem::rd(mesh + off::SKEL_BONE_ARRAY, bones)) return 0;
    if (bones.Num <= 0 || bones.Num > 512 || !bones.Data) return 0;

    out.resize((size_t)bones.Num * 12);   // 3x4 float
    if (!mem::read(bones.Data, out.data(), out.size() * sizeof(float))) {
        out.clear();
        return 0;
    }
    return bones.Num;
}

} // namespace world
