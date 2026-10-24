// ESP.hpp —— 只读显示：骨骼 / 身上的装备 / 附近物资
//
// 这个工程的功能边界就到这里：不写游戏内存、不改视角、不发包。
// 对应地，整个 dylib 里不存在任何 mem::wr 调用点 —— 见 Docs/ESP-ONLY.md。

#pragma once

namespace esp {

struct Settings {
    bool  skeleton  = true;    // 骨骼线
    bool  gear      = true;    // 玩家身上的装备名
    bool  loot      = true;    // 附近物资名
    bool  distance  = true;    // 距离数字
    bool  box       = false;   // 骨骼取不到时的兜底方框
    float maxDistM  = 300.f;   // 显示半径（米）
    float thick     = 1.6f;
};

// 每帧调用一次（在 Metal present 之前）。内部自己 refresh 世界、取相机、扫描、绘制。
void render(float vpW, float vpH);

// 开关（由 Overlay 的菜单写入）
Settings& settings();

// 调试：把当前场景分类结果打进日志（用来确认关键词表对不对）
void debug_dump(void (*log)(const char*));

} // namespace esp
