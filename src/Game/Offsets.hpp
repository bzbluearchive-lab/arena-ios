// Offsets.hpp —— 版本相关的全部数字都在这一个文件里。
//
// ！！除标注 VERIFIED 的以外，以下全部为占位符，必须在目标二进制上实测后填入。
// ！！禁止凭"别人写过的某某偏移"直接抄：UE4 每个小版本的类布局都会动，
// ！！抄错的偏移表现为"实体数量 0 或 4 亿"，浪费的是整天的时间。
//
// 定位顺序（依据 ios-ue4-re 流程）：
//   1. GNames / FNamePool 先从 dump 里白拿，用来按名字校验后面找到的东西
//   2. GEngine 全局 -> GameViewportClient -> World（比裸 GWorld 全局可靠，
//      ACE 保护的构建上裸 GWorld 常被换成解密/校验型访问器）
//   3. 校验：PersistentLevel 的 Actors.Num 落在 几十~几百 之间才算对上
//   4. 再读一个 actor 的坐标，坐标有限且量级合理才算真的进来了

#pragma once
#include <stdint.h>

namespace off {

// ==================== 全局（.data 里的指针，运行时扫特征码定位） ====================
// 特征码需在 arm64 slice 上用 IDA/Ghidra 自扫。这里是"待填"，不是值。
extern uintptr_t GEngine;        // UNVERIFIED  UEngine*
extern uintptr_t GNames;         // UNVERIFIED  FNamePool*（4.23+）
extern uintptr_t GWorld;         // UNVERIFIED  UWorld*（受保护构建上可能是诱饵）

// ==================== 引擎链 ====================
constexpr uintptr_t UENGINE_GAMEVIEWPORT = 0x000;   // UNVERIFIED -> UGameViewportClient*
constexpr uintptr_t UENGINE_GAMEINSTANCE  = 0x000;   // UNVERIFIED -> UGameInstance*
constexpr uintptr_t GVC_WORLD             = 0x000;   // UNVERIFIED -> UWorld*
constexpr uintptr_t GI_LOCALPLAYERS        = 0x000;  // UNVERIFIED -> TArray<ULocalPlayer*>
constexpr uintptr_t GI_WORLD               = 0x000;  // UNVERIFIED -> UWorld*

// ==================== UWorld ====================
constexpr uintptr_t UWORLD_PERSISTENT_LEVEL = 0x000; // UNVERIFIED ULevel*
constexpr uintptr_t UWORLD_OWNING_GAME_INSTANCE = 0x000; // UNVERIFIED
constexpr uintptr_t UWORLD_GAME_STATE        = 0x000; // UNVERIFIED AGameStateBase*

// ==================== ULevel ====================
constexpr uintptr_t ULEVEL_ACTORS = 0x000;           // UNVERIFIED TArray<AActor*>

// ==================== AActor / 角色 ====================
constexpr uintptr_t ACTOR_ROOT_COMPONENT = 0x000;    // UNVERIFIED USceneComponent*
constexpr uintptr_t ACTOR_OWNER          = 0x000;    // UNVERIFIED
constexpr uintptr_t ACTOR_INSTIGATOR     = 0x000;    // UNVERIFIED APawn*/AController*
constexpr uintptr_t SCENE_RELATIVE_LOC   = 0x000;    // UNVERIFIED FVector（相对父组件）
constexpr uintptr_t SCENE_COMPONENT_TO_WORLD = 0x000;// UNVERIFIED FTransform（组件->世界）
constexpr uintptr_t PAWN_PLAYER_STATE    = 0x000;    // UNVERIFIED
constexpr uintptr_t PSC_PAWN_PRIVATE     = 0x000;    // UNVERIFIED
constexpr uintptr_t PSC_TEAM_ID          = 0x000;    // UNVERIFIED uint8
constexpr uintptr_t PSC_HEALTH           = 0x000;    // UNVERIFIED float（位置随版本/字段布局变）

// ==================== 骨骼 / 网格 ====================
constexpr uintptr_t CHAR_MESH            = 0x000;    // UNVERIFIED USkeletalMeshComponent*
constexpr uintptr_t SKEL_BONE_ARRAY      = 0x000;    // UNVERIFIED TArray<FTransform>（ComponentSpace）
constexpr uintptr_t SKEL_COMPONENT_TO_WORLD = 0x000;// UNVERIFIED FTransform
// UE4 ComponentSpace 是 3x4（FTransform 的 48 字节布局：R[3][4] + T[4]），索引 boneIndex*0x30

// ==================== 相机 ====================
constexpr uintptr_t PC_PLAYER_CAMERA_MANAGER = 0x000; // UNVERIFIED APlayerCameraManager*
constexpr uintptr_t PCM_CAMERA_CACHE         = 0x000; // UNVERIFIED FCameraCacheEntry{POV}
constexpr uintptr_t PCAM_CONTROL_ROTATION    = 0x000; // UNVERIFIED FRotator（自瞄写这里）

// ==================== FMinimalViewInfo 字段 ====================
// 这几个是 UE4 公开源码里的字段顺序，可以信任；偏移随版本累积填充变化，仍需核对。
constexpr uintptr_t POV_LOCATION   = 0x00;   // FVector
constexpr uintptr_t POV_ROTATION   = 0x0C;   // FRotator (Pitch, Yaw, Roll)
constexpr uintptr_t POV_FOV        = 0x18;   // float
constexpr uintptr_t POV_ASPECT     = 0x1C;   // float
constexpr uintptr_t POV_PROJ_MODE  = 0x20;   // uint8

} // namespace off
