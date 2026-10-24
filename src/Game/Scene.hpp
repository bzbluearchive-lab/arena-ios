// Scene.hpp —— 一次扫描，分出三类东西：玩家 / 玩家身上的装备 / 地上的物资
//
// 分类**不依赖任何游戏私有结构体**，只依赖两样东西：
//   1. UObject 的类名（走 FNamePool）
//   2. AActor::Owner（把"挂在玩家身上的装备"归到玩家）
// 这样做的原因：装备/背包/头盔这些类在每个版本里字段布局都会动，
// 但"它叫什么"和"它的 Owner 是谁"这两个东西十年没变过。
//
// 纯读取，全程无写入 —— 见 Docs/ESP-ONLY.md「零写入」一节。

#pragma once
#include <stdint.h>
#include <vector>
#include <string>
#include "World.hpp"

namespace scene {

enum class Kind { Other, Player, Loot, Gear };

struct Entity {
    uintptr_t addr = 0;
    Kind      kind = Kind::Other;
    char      cls[96] = {0};      // 类名，如 BP_PlayerCharacter_C / AWorldPickup_C
    FVector   loc{};
    float     dist = 0.f;         // 到相机的水平距离（UE4 单位 cm）
    bool      isLocal = false;
};

struct GearTag {
    uintptr_t player = 0;         // 归属玩家 actor
    char      label[96] = {0};    // 装备类名（Helmet/Armor/Backpack/Weapon…）
};

struct Scene {
    std::vector<Entity>    players;
    std::vector<Entity>    loot;
    std::vector<GearTag>   gear;
};

// 关键词表（按实际类名改这里，不用改逻辑）
struct Keywords {
    const char* player[6] = { "PlayerCharacter", "PlayerPawn", "Character", nullptr, nullptr, nullptr };
    const char* gear[10]  = { "Helmet", "Armor", "Vest", "Backpack", "Rig", "Weapon",
                              "Gun", "Magazine", "Scope", "Attachment" };
    const char* loot[12]  = { "Pickup", "Loot", "Supply", "Container", "Crate", "Box",
                              "Ammo", "Medic", "Valuab", "Collect", "Item", "Bag" };
};

// 扫描。maxDistCm <= 0 表示不限距离。返回 false = 世界还没就绪。
bool scan(const world::Context& c, const FMinimalViewInfo& pov,
          float maxDistCm, Scene& out, const Keywords& kw = Keywords());

// 骨骼：组件空间 -> 世界坐标
// FTransform 布局（UE4）：+0x00 FQuat Rotation(16) / +0x10 FVector Translation(12)
//                         +0x20 FVector Scale3D(12)，sizeof = 0x30
constexpr uintptr_t BONE_STRIDE     = 0x30;
constexpr uintptr_t BONE_TRANSLATION = 0x10;
constexpr uintptr_t XFORM_ROTATION  = 0x00;
constexpr uintptr_t XFORM_TRANSLATION = 0x10;

bool bone_world(uintptr_t actor, int boneIndex, FVector& out);

// 骨骼索引 -> 世界坐标的调试转储（用来人工认领 head/pelvis/hand 是哪一号）
void dump_bones(uintptr_t actor, void (*log)(const char*));

// 骨架连线表：{boneA, boneB}。索引与具体 rig 绑定，这里给的是占位，
// 用 dump_bones 认领后填。填错不会崩，只会画出奇怪的连法。
struct BonePair { int a, b; };
extern BonePair kBonePairs[32];
extern int       kBonePairCount;

} // namespace scene
