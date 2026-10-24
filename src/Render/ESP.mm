#include "ESP.hpp"
#include "../Game/Scene.hpp"
#include "../Game/UObject.hpp"
#include "../Game/Offsets.hpp"
#include "../Core/Obfs.hpp"
#include <string.h>
#include <stdio.h>
#include <math.h>

#include "imgui.h"

namespace esp {

static Settings g_set;
static world::Context g_ctx;

Settings& settings() { return g_set; }

// ---- 类名瘦身：BP_PlayerCharacter_C -> PlayerCharacter ----
static void shorten(const char* in, char* out, size_t cap) {
    const char* p = in;
    if (!p) { out[0] = 0; return; }
    while (strncmp(p, "BP_", 3) == 0) p += 3;
    if (p[0] == 'A' && p[1] >= 'A' && p[1] <= 'Z') p += 1;   // A 前缀类名
    size_t n = strlen(p);
    size_t cut = n;
    if (n > 2 && strcmp(p + n - 2, "_C") == 0) cut = n - 2;
    if (cut >= cap) cut = cap - 1;
    memcpy(out, p, cut);
    out[cut] = 0;
}

// ---- 世界坐标 -> 屏幕（与 Aim.mm 同一套公式，只读）----
static bool w2s(const FMinimalViewInfo& pov, float vpW, float vpH,
                const FVector& w, float& sx, float& sy) {
    const float D2R = 3.14159265358979f / 180.f;
    const float px = pov.Rotation.Pitch * D2R;
    const float yw = pov.Rotation.Yaw * D2R;

    const float dx = w.X - pov.Location.X;
    const float dy = w.Y - pov.Location.Y;
    const float dz = w.Z - pov.Location.Z;

    const float cy = cosf(yw), syw = sinf(yw);
    const float cp = cosf(px), sp = sinf(px);

    const float x1 =  cy * dx + syw * dy;
    const float y1 = -syw * dx + cy * dy;
    const float z1 =  dz;

    const float x2 =  cp * x1 + sp * z1;
    const float z2 = -sp * x1 + cp * z1;
    if (z2 < 0.01f) return false;

    const float tanHalf = tanf(pov.FOV * 0.5f * D2R);
    const float aspect = (pov.AspectRatio > 0.1f) ? pov.AspectRatio : (vpW / vpH);

    sx = (x2 / (z2 * tanHalf * aspect) + 1.f) * 0.5f * vpW;
    sy = (1.f - y1 / (z2 * tanHalf)) * 0.5f * vpH;
    return true;
}

// ---- 骨骼 ----
static void draw_skeleton(ImDrawList* dl, uintptr_t actor,
                         const FMinimalViewInfo& pov, float vpW, float vpH, ImU32 col) {
    for (int i = 0; i < scene::kBonePairCount; i++) {
        const scene::BonePair& bp = scene::kBonePairs[i];
        FVector wa{}, wb{};
        if (!scene::bone_world(actor, bp.a, wa)) continue;
        if (!scene::bone_world(actor, bp.b, wb)) continue;
        float ax, ay, bx, by;
        if (!w2s(pov, vpW, vpH, wa, ax, ay)) continue;
        if (!w2s(pov, vpW, vpH, wb, bx, by)) continue;
        dl->AddLine(ImVec2(ax, ay), ImVec2(bx, by), col, g_set.thick);
    }
}

static bool any_bone_visible(uintptr_t actor, const FMinimalViewInfo& pov, float vpW, float vpH) {
    FVector w{};
    if (!scene::bone_world(actor, 0, w)) return false;
    float x, y;
    return w2s(pov, vpW, vpH, w, x, y);
}

// ---- 主渲染 ----
void render(float vpW, float vpH) {
    if (vpW < 2.f || vpH < 2.f) return;

    world::refresh(g_ctx);
    FMinimalViewInfo pov{};
    if (!world::camera(g_ctx, pov)) return;

    scene::Scene sc;
    if (!scene::scan(g_ctx, pov, g_set.maxDistM * 100.f, sc)) return;

    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    const ImU32 colPlayer = IM_COL32(0, 255, 120, 220);
    const ImU32 colLoot   = IM_COL32(255, 210, 60, 220);
    const ImU32 colGear   = IM_COL32(120, 200, 255, 200);
    char text[192], shortName[96];

    // ---- 玩家：骨骼 + 装备 ----
    if (g_set.skeleton || g_set.gear) {
        for (auto& p : sc.players) {
            float sx, sy;
            if (!w2s(pov, vpW, vpH, p.loc, sx, sy)) continue;

            float headY = sy;
            if (g_set.skeleton && any_bone_visible(p.addr, pov, vpW, vpH)) {
                draw_skeleton(dl, p.addr, pov, vpW, vpH, colPlayer);
                FVector h{};
                if (scene::bone_world(p.addr, 0, h)) {
                    float hx, hy;
                    if (w2s(pov, vpW, vpH, h, hx, hy)) headY = hy;
                }
            } else if (g_set.box) {
                const float m = p.dist / 100.f;
                const float h = (1800.f / (m + 1.f)) * (vpH / 800.f);
                const float w = h * 0.42f;
                dl->AddRect(ImVec2(sx - w * 0.5f, sy - h), ImVec2(sx + w * 0.5f, sy),
                            colPlayer, 1.5f, 0, g_set.thick);
                headY = sy - h;
            }

            float ty = headY - 16.f;
            if (g_set.gear) {
                // 同一个玩家的装备拼一行，最多 4 件
                int shown = 0;
                for (auto& g : sc.gear) {
                    if (g.player != p.addr) continue;
                    if (shown >= 4) break;
                    shorten(g.label, shortName, sizeof(shortName));
                    snprintf(text, sizeof(text), "%s", shortName);
                    dl->AddText(ImVec2(sx + 6.f, ty), colGear, text);
                    ty += 14.f;
                    shown++;
                }
            }

            if (g_set.distance) {
                shorten(p.cls, shortName, sizeof(shortName));
                snprintf(text, sizeof(text), "%s %.0fm", shortName, p.dist / 100.f);
                dl->AddText(ImVec2(sx - 20.f, ty), colPlayer, text);
            }
        }
    }

    // ---- 物资 ----
    if (g_set.loot) {
        for (auto& it : sc.loot) {
            float sx, sy;
            if (!w2s(pov, vpW, vpH, it.loc, sx, sy)) continue;
            if (sx < -60.f || sy < -60.f || sx > vpW + 60.f || sy > vpH + 60.f) continue;
            shorten(it.cls, shortName, sizeof(shortName));
            if (g_set.distance) snprintf(text, sizeof(text), "%s  %.0fm", shortName, it.dist / 100.f);
            else                snprintf(text, sizeof(text), "%s", shortName);
            // 小点 + 文字，避免满屏框影响判断
            dl->AddCircleFilled(ImVec2(sx, sy), 3.f, colLoot);
            dl->AddText(ImVec2(sx + 5.f, sy - 7.f), colLoot, text);
        }
    }
}

void debug_dump(void (*log)(const char*)) {
    if (!log) return;
    FMinimalViewInfo pov{};
    if (!world::camera(g_ctx, pov)) { log("camera: fail"); return; }

    scene::Scene sc;
    if (!scene::scan(g_ctx, pov, 0.f, sc)) { log("scan: fail"); return; }

    char line[192];
    snprintf(line, sizeof(line), "players=%zu loot=%zu gear=%zu",
             sc.players.size(), sc.loot.size(), sc.gear.size());
    log(line);
    for (auto& p : sc.players) {
        char sn[96]; shorten(p.cls, sn, sizeof(sn));
        snprintf(line, sizeof(line), " P %-28s %.0fm", sn, p.dist / 100.f);
        log(line);
    }
    for (auto& it : sc.loot) {
        char sn[96]; shorten(it.cls, sn, sizeof(sn));
        snprintf(line, sizeof(line), " L %-28s %.0fm", sn, it.dist / 100.f);
        log(line);
    }
    for (auto& g : sc.gear) {
        char sn[96]; shorten(g.label, sn, sizeof(sn));
        snprintf(line, sizeof(line), " G %-28s -> 0x%lx", sn, (unsigned long)g.player);
        log(line);
    }
}

} // namespace esp
