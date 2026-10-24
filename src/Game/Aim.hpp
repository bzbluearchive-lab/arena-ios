// Aim.hpp —— 世界坐标 -> 屏幕、以及视角自瞄。
//
// 不读 ViewMatrix 偏移：用 POV(Location, Rotation, FOV) 自己算投影。
// 理由：ViewMatrix/ProjectionMatrix 在 FCameraCacheEntry 里的位置随版本漂，
// 而且 UE4 iOS 上常被改为在 GameThread 里按需构建；自己算只依赖三个稳定字段。

#pragma once
#include "World.hpp"

namespace aim {

// 世界坐标 -> 屏幕坐标。返回 false 表示在背后/被剔除。
bool w2s(const FMinimalViewInfo& pov, float vpW, float vpH,
         const FVector& w, float& sx, float& sy);

struct Settings {
    bool  enabled   = false;
    float fov       = 25.f;    // 判定半径（度）
    float smooth    = 0.25f;   // 0.15~0.35 之间，越低越"手抖"，越像人
    int   bone      = 0;       // 0=头(可用骨骼索引替换)
    bool  teamCheck = true;
    bool  visCheck  = false;   // 需要射线检测偏移，未验证前保持关闭
};

// 每帧调用。返回是否写入了视角。
bool tick(const world::Context& c, uintptr_t localActor,
          const std::vector<uintptr_t>& targets, const Settings& s);

} // namespace aim
