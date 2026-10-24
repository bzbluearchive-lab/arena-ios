#include "Scene.hpp"
#include "Offsets.hpp"
#include "UObject.hpp"
#include "../Core/SafeMem.h"
#include <string.h>
#include <stdio.h>
#include <math.h>

namespace scene {

// ---- 骨架连线（占位：dump_bones 认领后替换）----
// 典型 UE4 人形 rig 的连法：骨盆-脊柱、脊柱-头、肩-肘-手、髋-膝-脚
BonePair kBonePairs[32] = {
    { 0, 1 }, { 1, 2 }, { 2, 3 },       // 脊柱链（占位）
    { 3, 4 }, { 4, 5 },                 // 头颈（占位）
    { 6, 7 }, { 7, 8 },                 // 左臂（占位）
    { 9, 10 }, { 10, 11 },              // 右臂（占位）
    { 12, 13 }, { 13, 14 },             // 左腿（占位）
    { 15, 16 }, { 16, 17 },             // 右腿（占位）
};
int kBonePairCount = 13;

// ---- 字符串小工具 ----
static bool contains_ci(const char* hay, const char* needle) {
    if (!hay || !needle || !*needle) return false;
    size_t hn = strlen(hay), nn = strlen(needle);
    if (nn > hn) return false;
    for (size_t i = 0; i + nn <= hn; i++) {
        size_t j = 0;
        for (; j < nn; j++) {
            char a = hay[i + j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) break;
        }
        if (j == nn) return true;
    }
    return false;
}

static bool match_any(const char* s, const char* const* list, int n) {
    for (int i = 0; i < n; i++) {
        if (!list[i]) continue;
        if (contains_ci(s, list[i])) return true;
    }
    return false;
}

// ---- 四元数旋转（UE4 FQuat 内存序 X,Y,Z,W）----
static FVector quat_rotate(const float q[4], const FVector& v) {
    const float qx = q[0], qy = q[1], qz = q[2], qw = q[3];
    // t = 2 * cross(q.xyz, v)
    const float tx = 2.f * (qy * v.Z - qz * v.Y);
    const float ty = 2.f * (qz * v.X - qx * v.Z);
    const float tz = 2.f * (qx * v.Y - qy * v.X);
    FVector r;
    r.X = v.X + qw * tx + (qy * tz - qz * ty);
    r.Y = v.Y + qw * ty + (qz * tx - qx * tz);
    r.Z = v.Z + qw * tz + (qx * ty - qy * tx);
    return r;
}

bool bone_world(uintptr_t actor, int boneIndex, FVector& out) {
    if (boneIndex < 0) return false;

    uintptr_t mesh = mem::rdptr(actor + off::CHAR_MESH);
    if (!mesh) return false;

    TArrayRaw bones{};
    if (!mem::rd(mesh + off::SKEL_BONE_ARRAY, bones)) return false;
    if (boneIndex >= bones.Num || !bones.Data) return false;

    // 组件空间里的骨骼变换
    const uintptr_t bt = bones.Data + (uintptr_t)boneIndex * BONE_STRIDE;
    FVector local{};
    if (!mem::rd(bt + BONE_TRANSLATION, local)) return false;

    // 组件的 ComponentToWorld
    const uintptr_t c2w = mesh + off::SKEL_COMPONENT_TO_WORLD;
    float rq[4] = {0, 0, 0, 1};
    FVector ct{};
    if (!mem::read(c2w + XFORM_ROTATION, rq, sizeof(rq))) return false;
    if (!mem::rd(c2w + XFORM_TRANSLATION, ct)) return false;

    FVector rot = quat_rotate(rq, local);
    out.X = rot.X + ct.X;
    out.Y = rot.Y + ct.Y;
    out.Z = rot.Z + ct.Z;
    return isfinite(out.X) && isfinite(out.Y) && isfinite(out.Z);
}

void dump_bones(uintptr_t actor, void (*log)(const char*)) {
    if (!log) return;
    char line[160];
    for (int i = 0; i < 96; i++) {
        FVector w{};
        if (!bone_world(actor, i, w)) break;
        snprintf(line, sizeof(line), "bone[%02d] %.1f %.1f %.1f", i, w.X, w.Y, w.Z);
        log(line);
    }
}

// ---- 主扫描 ----
bool scan(const world::Context& c, const FMinimalViewInfo& pov,
          float maxDistCm, Scene& out, const Keywords& kw) {
    out.players.clear();
    out.loot.clear();
    out.gear.clear();

    std::vector<uintptr_t> actors;
    if (!world::actors(c, actors) || actors.empty()) return false;

    if (!ue::fname::ready()) {
        uintptr_t pool = ue::fname::locate();
        if (pool) ue::fname::set_base(pool);
    }

    // 第一遍：认玩家（有 SkeletalMeshComponent 且类名像玩家）
    for (uintptr_t a : actors) {
        char cls[96] = {0};
        ue::uobj::class_of(a, cls, sizeof(cls));
        if (!*cls) continue;

        const bool hasMesh = mem::rdptr(a + off::CHAR_MESH) != 0;
        const bool nameOK  = match_any(cls, kw.player, 3);
        // 有骨骼网格 + 类名像玩家 → 玩家；只要类名像玩家也收，便于在日志里发现漏的
        if (!hasMesh && !nameOK) continue;
        if (!nameOK && !hasMesh) continue;

        FVector loc{};
        if (!world::actor_location(a, loc)) continue;

        Entity e;
        e.addr = a;
        e.kind = Kind::Player;
        strncpy(e.cls, cls, sizeof(e.cls) - 1);
        e.loc = loc;
        const float dx = loc.X - pov.Location.X, dy = loc.Y - pov.Location.Y, dz = loc.Z - pov.Location.Z;
        e.dist = sqrtf(dx * dx + dy * dy + dz * dz);
        if (maxDistCm > 0 && e.dist > maxDistCm) continue;
        out.players.push_back(e);
    }

    // 玩家集合用于归属判定
    auto is_player = [&](uintptr_t p) {
        for (auto& e : out.players) if (e.addr == p) return true;
        return false;
    };

    // 第二遍：装备（Owner 是玩家）与物资（无玩家 Owner + 类名像物资）
    for (uintptr_t a : actors) {
        const bool alreadyPlayer = is_player(a);
        if (alreadyPlayer) continue;

        char cls[96] = {0};
        ue::uobj::class_of(a, cls, sizeof(cls));
        if (!*cls) continue;

        FVector loc{};
        if (!world::actor_location(a, loc)) continue;
        const float dx = loc.X - pov.Location.X, dy = loc.Y - pov.Location.Y, dz = loc.Z - pov.Location.Z;
        const float dist = sqrtf(dx * dx + dy * dy + dz * dz);

        // 装备：Owner 指向玩家（部分 rig 是 Owner->Owner，允许一跳）
        uintptr_t owner = ue::uobj::outer_of(a);
        if (owner && is_player(owner)) {
            if (match_any(cls, kw.gear, 10)) {
                GearTag g;
                g.player = owner;
                strncpy(g.label, cls, sizeof(g.label) - 1);
                out.gear.push_back(g);
            }
            continue;
        }

        // 物资：类名像物资、且不在玩家身上
        if (match_any(cls, kw.loot, 12)) {
            if (maxDistCm > 0 && dist > maxDistCm) continue;
            Entity e;
            e.addr = a;
            e.kind = Kind::Loot;
            strncpy(e.cls, cls, sizeof(e.cls) - 1);
            e.loc = loc;
            e.dist = dist;
            out.loot.push_back(e);
        }
    }
    return true;
}

} // namespace scene
