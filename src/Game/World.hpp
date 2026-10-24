// World.hpp —— 从 GEngine 链到世界、实体列表、相机。
//
// 设计要点（全都是踩过的坑）：
//   1. 不信任裸 GWorld 全局：ACE 保护的构建上它可能是诱饵或需解密
//   2. 每帧校验实体数量，超出 [1, 4096] 就当链路失效，本帧直接放弃绘制
//   3. 全部经 SafeMem 读，坏指针 = 读失败，不是崩

#pragma once
#include <stdint.h>
#include <vector>

struct FVector { float X, Y, Z; };
struct FRotator { float Pitch, Yaw, Roll; };

struct FMinimalViewInfo {
    FVector  Location;
    FRotator Rotation;
    float    FOV;
    float    AspectRatio;
    uint8_t  ProjectionMode;
    uint8_t  _pad[3];
};

struct TArrayRaw {
    uintptr_t Data;
    int32_t   Num;
    int32_t   Max;
};

namespace world {

// 引擎/世界指针。全部为运行时解析结果，0 表示没拿到。
struct Context {
    uintptr_t gengine = 0;
    uintptr_t world   = 0;
    uintptr_t level   = 0;
    uintptr_t pc      = 0;   // 本地 APlayerController
    uintptr_t pcam    = 0;   // APlayerCameraManager
};

// 解析一次（引擎初始化完成后调用，别每帧调）
Context resolve();

// 每帧刷新（世界会重载，world/level 会变）
void refresh(Context& c);

// 取相机 POV，失败返回 false
bool camera(const Context& c, FMinimalViewInfo& pov);

// 取实体列表
bool actors(const Context& c, std::vector<uintptr_t>& out);

// 直接从组件世界变换取世界坐标（比 RelativeLocation 可靠，角色有父组件）
bool actor_location(uintptr_t actor, FVector& out);

// 角色血量/队伍（字段布局随版本，未验证时返回 false，别拿垃圾数据判断）
bool actor_health(uintptr_t actor, float& hp);
bool actor_team(uintptr_t actor, uint8_t& team);

// 骨骼：0 = 失败；返回 3x4 变换数组的长度
int  bone_transforms(uintptr_t actor, std::vector<float>& out /*48B each*/);

} // namespace world
