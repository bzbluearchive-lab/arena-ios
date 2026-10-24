# 只显示：骨骼 / 身上的装备 / 附近物资

功能边界：**只读**。不写游戏内存、不改视角、不发包、不注入额外进程。

这个边界不只是"少做点功能"，它直接决定了几件事：

---

## 1. 零写入 = 少一整类检测面

自瞄要写 `ControlRotation`，那是可被回看/回放分析抓到的动作。只显示则不写。

代码里对应的硬约束：[Makefile.legacy-tweak](../Makefile.legacy-tweak) 的 `ARCheat_FILES`
**不包含 `src/Game/Aim.mm`**。所以：

- 二进制里不存在 `vm_write` 调用点（不是"不调用"，是"没链接进来"）
- 拿 IDA 翻这个 dylib，看不到任何写游戏内存的符号或调用
- 不存在行为面（跟枪曲线、视角突变这些都不存在）

`mem::wr` 这个模板函数仍然在 `SafeMem.h` 里，但没有任何实例化点，编译器不会生成代码。

---

## 2. 数据从哪来：三条独立的路

| 显示内容 | 数据来源 | 依赖的偏移 |
|---|---|---|
| **玩家** | `UWorld → PersistentLevel → Actors` 里挑"有 SkeletalMeshComponent 且类名像玩家"的 | `UWORLD_PERSISTENT_LEVEL` / `ULEVEL_ACTORS` / `CHAR_MESH` / `ACTOR_ROOT_COMPONENT` |
| **骨骼** | 骨骼网格的 `ComponentSpaceTransforms`（FTransform 数组）+ 组件的 `ComponentToWorld` | `SKEL_BONE_ARRAY` / `SKEL_COMPONENT_TO_WORLD` |
| **装备** | 遍历所有 actor，`AActor::Owner` 指向玩家、且类名命中装备关键词的 | `OFF_OUTER`（UObject Outer）+ 类名 |
| **物资** | 遍历所有 actor，类名命中物资关键词、且不在玩家身上的 | 类名 + 根组件坐标 |

关键设计：**分类靠"它叫什么"，不靠知道装备/背包/物资类的字段布局。**

理由很实际：`Helmet`、`Vest`、`Backpack` 这些类在每个版本里字段都会动、会插新属性；
但 `UObject::NamePrivate` 和 `AActor::Owner` 这两个东西十年没变。所以：

- 版本更新后偏移崩了，可能只崩坐标/骨骼，**分类还在**
- 换一个新的 UE4 射击游戏，改 `scene::Keywords` 里的关键词就行，逻辑一行不动

---

## 3. FNamePool 是这套的根，且能自动定位

`UObject.hpp` 里实现了自动定位：扫 `__DATA`/`__DATA_CONST`，对每个候选指针检查
`*(p+0x10)` 指向的 entry 0 能不能解出 `"None"`。

UE4 的 FName 表前几个索引是固定的：

```
0=None  1=ByteProperty  2=IntProperty  3=BoolProperty
4=FloatProperty  5=ObjectProperty  6=NameProperty
```

所以这个自检既是定位手段，也是验收标准。跑 `ue::fname::self_check(log)` 打出来：

- 看到 `None / ByteProperty / IntProperty / BoolProperty ...` → GNames 拿到了，stride 也对了
- 全 `<fail>` → GNames 不在 `__DATA`（可能在 `__DATA_CONST` 之外，或被改建挪走），
  走静态分析手动 `set_base(pool地址)`

`stride` 会在 2 和 4 之间自动试错，因为含宽字符 entry 的池步长是 4。

---

## 4. 骨骼：为什么给的是"认领流程"而不是一串索引

骨骼索引和 rig 强绑定，抄别人的表 100% 是错的（换个角色模型就错位）。
所以工程里给的是：

```cpp
BonePair kBonePairs[32] = {{0,1},{1,2},...};   // 占位，连法本身是对的，编号是错的
void dump_bones(actor, log);                    // 打印 0..95 号骨骼的世界坐标
```

认领办法：站到一个已知朝向的位置，调 `dump_bones`，看坐标就能认出来 ——

- 某一号 Z 明显最高、且离原点最远 → 头
- Z 在腰部高度、X/Y 最接近角色中心 → 骨盆
- 左右两侧对称的一对 → 肩/肘/手、髋/膝/脚

认完把编号填进 `kBonePairs`，把 `kBonePairCount` 改成实际条数（最多 32 对）。
填错不会崩，只会画出奇怪的连法。

骨骼世界坐标的算法（`bone_world`）：

```
world = quat_rotate(ComponentToWorld.Rotation, boneTranslation)
      + ComponentToWorld.Translation
```

FTransform 布局按 `+0x00 FQuat(16) / +0x10 Translation(12) / +0x20 Scale(12)`，`sizeof = 0x30`。
**这个 0x30 和 0x10 要按你的版本核对**，标 `UNVERIFIED`。

---

## 5. 装备：为什么不从玩家结构里读

因为"玩家身上有哪些装备"这件事，在 UE4 射击游戏里没有任何统一实现：

- 有的游戏是独立 item actor 挂在骨骼 socket 上
- 有的是 `UInventoryComponent` 里一堆 `FPrimaryAssetId`
- 有的是自定义 `FEquipmentSlot` 数组

三条路都是版本相关的，且都没法通吃。而 **`Actor::Owner` 是引擎级字段**，
"这个头盔 actor 的 Owner 是那个玩家"这个关系一定成立。

所以做法是反过来的：

```
遍历世界所有 actor
  → 类名命中装备关键词（Helmet/Armor/Vest/Backpack/Rig/Weapon/...）
  → 它的 Owner 是某个已识别的玩家
  → 归到这个玩家名下显示
```

代价：武器如果是"组件内的 mesh 段"而不是独立 actor，就抓不到。那时候补
`CHAR_MESH → socket 上的 attached actor` 这一跳，或者读 inventory 组件——两个都可选，
先跑通 Actor.Owner 这条。

---

## 6. 物资：关键词表是唯一需要调的地方

`scene::Keywords::loot` 默认是：

```
Pickup Loot Supply Container Crate Box Ammo Medic Valuab Collect Item Bag
```

跑一次 `esp::debug_dump(log)`，日志会打出 `L players=... loot=... gear=...`
以及每一类具体类名。**看日志里真实类名，按它改关键词表**，不要猜。

典型的调整：全部物资都叫 `BP_XX_Item_XXX_C`，那就把 `Item` 留在表里；
如果捡拾物是 `AWorldPickup_C`，`Pickup` 就够。

---

## 7. 验收顺序

| 步 | 期望 | 失败指向 |
|---|---|---|
| 1 | `fname::self_check` 打出 None/ByteProperty/... | GNames 定位失败 → 手动 `set_base` |
| 2 | `debug_dump` 打出 `players=N`（N>0） | `CHAR_MESH` 或玩家关键词错 |
| 3 | 打出的玩家类名看着对 | 分类关键词太窄/太宽 |
| 4 | 屏幕上出现骨骼线 | 骨骼索引没认领，或 `SKEL_BONE_ARRAY` 偏移错 |
| 5 | 骨骼线跟着人动、不抖不飘 | `ComponentToWorld` 的旋转/平移偏移错 |
| 6 | 玩家头顶出现装备名 | `OFF_OUTER` 错，或装备关键词缺 |
| 7 | 地上物资点出来 | loot 关键词缺，或物资有 Owner 被误判成装备 |
| 8 | 帧率掉 < 10% | 每帧扫描太重 → 把 `scan` 降到每 3 帧一次，位置插值 |

---

## 8. 这一步之后还剩多少可上报面

只显示形态下，anogs 可能看到的信号收敛到这几条：

| 信号 | 状态 |
|---|---|
| `_dyld_image_name` 里多一个 dylib | **存在，消不掉** |
| 两个 ObjC 方法 IMP 落在我们 image 内 | **存在，消不掉**（只 swizzle 了 2 个） |
| 匿名可执行区域 | ✅ 无（inline hook 编译期关闭） |
| 明文 cheat 字符串 | ✅ 无（XOR 常量） |
| 多余的 vm_write | ✅ 无（Aim 未链接） |
| 行为面（视角写入） | ✅ 无 |
| 额外线程 / 定时器 | ✅ 无 |
| 落盘配置 / 网络 | ✅ 无 |
| TrollStore / 越狱痕迹 | ✅ 已拦 |

剩下两条消不掉，这是注入路线的物理下限。要继续压只能换形态（跨进程读 + 外部画），
而那条路的成本见 [ARCH.md](ARCH.md)。
