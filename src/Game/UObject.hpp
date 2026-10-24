// UObject.hpp —— FNamePool 解析 + UObject 名字读取
//
// 为什么把这一层排在 GWorld 偏移前面：
//   "只显示"这套功能（骨骼/装备/物资）全部靠"这个东西叫什么"来分类，
//   而不是靠知道每个类的字段布局。类名走 FNamePool，一个全局 + 一条解析公式，
//   不依赖任何游戏的私有结构体。定位一次，全场景受益。
//
// 校验手段（很重要）：UE4 的 FName 表前几个索引是固定的 ——
//   0=None 1=ByteProperty 2=IntProperty 3=BoolProperty 4=FloatProperty
// 所以 GNames 可以**自动定位**：扫 __DATA 里的指针，看 *(p+0x10) 指向的
//   第 0 项是不是 "None"。这一步成了，后面全部成立；不成，说明 GNames 不在那。

#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string>

namespace ue {

// ==================== FNamePool ====================
// UE4.23+ 布局（8 字节对齐后）：
//   +0x00  FRWLock Lock            (4)
//   +0x04  uint32  CurrentBlock    (4)
//   +0x08  uint32  CurrentByteCursor (4)
//   +0x0C  padding
//   +0x10  uint8*  Blocks[8192]
// entry(index) = Blocks[index >> 16] + stride * (index & 0xFFFF)
// stride = 2（普通）/ 4（含宽字符 entry 的池）
namespace fname {

// 自动扫描 __DATA/__DATA_CONST 找 GNames，并用 "None" 自检。
// 成功返回 FNamePool 的地址（写进 Offsets.hpp 的 off::GNames 后就不必再扫）。
uintptr_t locate();

// 手动指定（静态分析已经拿到 GNames 时用这个，跳过扫描）
void set_base(uintptr_t pool, uint32_t stride = 2);

bool ready();

// 取字符串。idx 为 FName 的 ComparisonIndex（uint32）。
// 返回 false = 该索引解析失败（越界 / 指针坏 / 名字不像字符串）
bool get(uint32_t idx, char* out, size_t cap);

// 便捷版（会分配 std::string，仅用于低频调用：分类、日志；不要放在逐帧内层循环）
std::string get_str(uint32_t idx);

// 自检：把 0..7 号索引打出来，正常应看到 None/ByteProperty/IntProperty/...
void self_check(void (*log)(const char*));

} // namespace fname

// ==================== UObject ====================
// UE4 UObjectBase 布局（arm64，指针 8 字节；int32 不影响对齐）
//   +0x00 vtable
//   +0x08 EObjectFlags (int32)
//   +0x0C InternalIndex (int32)
//   +0x10 UClass* ClassPrivate
//   +0x18 FName  NamePrivate   (ComparisonIndex int32 / Number int32)
//   +0x20 UObject* OuterPrivate
// 以上标 UNVERIFIED：UE5 与部分改建把 ClassPrivate 挪过位，用前先按名字校验一次。
namespace uobj {

constexpr uintptr_t OFF_VTABLE = 0x00;
constexpr uintptr_t OFF_FLAGS  = 0x08;
constexpr uintptr_t OFF_INDEX  = 0x0C;
constexpr uintptr_t OFF_CLASS  = 0x10;   // UNVERIFIED
constexpr uintptr_t OFF_NAME   = 0x18;   // UNVERIFIED
constexpr uintptr_t OFF_OUTER  = 0x20;   // UNVERIFIED

// 任意 UObject 的名字（如 "BP_PlayerCharacter_C"）
bool name_of(uintptr_t obj, char* out, size_t cap);

// 该对象的类名（先取 ClassPrivate 再取名字），分类判定的主力
bool class_of(uintptr_t obj, char* out, size_t cap);

// 取 Outer（用于把"挂在玩家身上的装备"归到玩家）
uintptr_t outer_of(uintptr_t obj);

} // namespace uobj

} // namespace ue
