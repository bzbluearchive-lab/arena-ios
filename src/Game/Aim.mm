#include "Aim.hpp"
#include "Offsets.hpp"
#include "../Core/SafeMem.h"
#include <cmath>
#include <algorithm>

namespace aim {

static constexpr float PI = 3.14159265358979f;
static constexpr float RAD2DEG = 180.f / PI;
static constexpr float DEG2RAD = PI / 180.f;

bool w2s(const FMinimalViewInfo& pov, float vpW, float vpH,
         const FVector& w, float& sx, float& sy) {
    const float pitch = pov.Rotation.Pitch * DEG2RAD;
    const float yaw   = pov.Rotation.Yaw   * DEG2RAD;

    const float dx = w.X - pov.Location.X;
    const float dy = w.Y - pov.Location.Y;
    const float dz = w.Z - pov.Location.Z;

    const float cy = cosf(yaw),  sy_ = sinf(yaw);
    const float cp = cosf(pitch), sp = sinf(pitch);

    // 世界 -> 相机（UE4 是左手系，Y 轴朝向需要这样取）
    const float x1 =  cy * dx + sy_ * dy;
    const float y1 = -sy_ * dx + cy  * dy;
    const float z1 =  dz;

    const float x2 =  cp * x1 + sp * z1;
    const float z2 = -sp * x1 + cp * z1;

    if (z2 < 0.01f) return false;                 // 背后剔除

    const float tanHalf = tanf(pov.FOV * 0.5f * DEG2RAD);
    const float aspect  = (pov.AspectRatio > 0.1f) ? pov.AspectRatio : (vpW / vpH);

    sx = (x2 / (z2 * tanHalf * aspect) + 1.f) * 0.5f * vpW;
    sy = (1.f - y1 /* 注意：屏幕纵向用相机 y1，不是 x2 */ / (z2 * tanHalf)) * 0.5f * vpH;
    return true;
}

static float norm180(float a) {
    while (a >  180.f) a -= 360.f;
    while (a < -180.f) a += 360.f;
    return a;
}

static bool angle_to(const FVector& cam, const FVector& tgt, float& yawDeg, float& pitchDeg, float& dist) {
    const float dx = tgt.X - cam.X;
    const float dy = tgt.Y - cam.Y;
    const float dz = tgt.Z - cam.Z;
    const float flat = sqrtf(dx * dx + dy * dy);
    if (flat < 1.f) return false;
    if (std::fabsf(dx) > 1e7f || std::fabsf(dy) > 1e7f) return false;
    yawDeg   = atan2f(dy, dx) * RAD2DEG;
    pitchDeg = atan2f(dz, flat) * RAD2DEG;
    dist = sqrtf(flat * flat + dz * dz);
    return true;
}

bool tick(const world::Context& c, uintptr_t localActor,
          const std::vector<uintptr_t>& targets, const Settings& s) {
    if (!s.enabled || !c.pcam || targets.empty()) return false;

    FMinimalViewInfo pov{};
    if (!world::camera(c, pov)) return false;

    uint8_t localTeam = 0xFF;
    if (s.teamCheck && localActor) world::actor_team(localActor, localTeam);

    // 选角度最小且在 FOV 内的目标
    float bestAngle = s.fov;
    float bestYaw = 0, bestPitch = 0, bestDist = 0;
    bool found = false;

    for (uintptr_t a : targets) {
        if (a == localActor) continue;

        if (s.teamCheck && localTeam != 0xFF) {
            uint8_t t = 0xFF;
            if (world::actor_team(a, t) && t == localTeam) continue;
        }

        FVector pos{};
        if (!world::actor_location(a, pos)) continue;

        float yaw, pitch, dist;
        if (!angle_to(pov.Location, pos, yaw, pitch, dist)) continue;
        if (dist > 40000.f) continue;                 // 400m 外不理

        const float dYaw = fabsf(norm180(yaw - pov.Rotation.Yaw));
        const float dPitch = fabsf(pitch - pov.Rotation.Pitch);
        const float ang = sqrtf(dYaw * dYaw + dPitch * dPitch);
        if (ang > bestAngle) continue;

        bestAngle = ang;
        bestYaw = yaw;
        bestPitch = pitch;
        bestDist = dist;
        found = true;
    }
    if (!found) return false;

    // 写 APlayerCameraManager 之外的 ControlRotation：
    // 注意 UE4 里 APlayerController::ControlRotation 与 PCM 的 POV.Rotation 是两条路，
    // 优先写 Controller（下帧 POV 自己会跟上），失败再写 PCM 的 POV 旋转。
    FRotator cur{};
    uintptr_t rotAddr = c.pc ? (c.pc + off::PCAM_CONTROL_ROTATION) : 0;
    if (rotAddr && mem::rd(rotAddr, cur)) {
        cur.Yaw   += norm180(bestYaw - cur.Yaw) * s.smooth;
        cur.Pitch += (bestPitch - cur.Pitch) * s.smooth;
        cur.Pitch = std::clamp(cur.Pitch, -89.f, 89.f);
        return mem::wr(rotAddr, cur);
    }

    // 兜底：直接改 POV.Rotation（会被 PCM 下帧覆写，仅在 WriteController 不可用时用）
    uintptr_t povAddr = c.pcam + off::PCM_CAMERA_CACHE + off::POV_ROTATION;
    if (mem::rd(povAddr, cur)) {
        cur.Yaw   += norm180(bestYaw - cur.Yaw) * s.smooth;
        cur.Pitch += (bestPitch - cur.Pitch) * s.smooth;
        cur.Pitch = std::clamp(cur.Pitch, -89.f, 89.f);
        return mem::wr(povAddr, cur);
    }
    return false;
}

} // namespace aim
