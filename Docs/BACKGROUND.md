# arena-ios

目标：`com.proximabeta.mf.uamo`（Arena Breakout / 暗区突围国际服，UE4）
设备：iPad Pro 11" (2022, M2) · iOS 16.1.1 · 反作弊 ACE (anogs/AnoSDK)

本地研究的叠加层工程骨架。Theos tweak → dylib → TrollFools 注入 app 包。
**全部代码只在 app 沙盒内运行，不触碰 rootfs / /var/jb / launchd / 内核缓存。**

---

## 0. 先做这一个检查：这个 app 的二进制到底是 arm64 还是 arm64e

这一步决定后面能不能用 inline hook。

```bash
# 在你自己的机器上，对解密后的二进制
otool -arch all -hv Arena | grep -E 'cputype|cpusubtype|LC_BUILD_VERSION'
# cpusubtype 0  = arm64（无 PAC）
# cpusubtype 2  = arm64e（有 PAC，inline hook 需要额外处理）
```

绝大多数 App Store 二进制即使在 arm64e 硬件上也仍带 plain arm64 slice。
**判为 arm64** → 本工程的 `install_inline` 直接用；
**判为 arm64e** → 优先走 vtable 槽替换 / ObjC 方法交换（本工程主干就是这么设计的），
只有拿不到 vtable 时才考虑 inline，且需要 ptrauth strip。

---

## 1. 环境与构建

Windows 上也能跑，用 WSL2：

```bash
# WSL2 (Ubuntu 22.04)
sudo apt install -y git make clang-14 lld ld64 ldid
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS
# 需要 iOS SDK（把 Xcode 的 iPhoneOS*.sdk 拷进 $THEOS/sdks/）
```

macOS 上就一条：

```bash
export THEOS=~/theos
make package          # 产出 packages/*.deb（TrollFools 可以不用 deb，直接吃 dylib）
ls .theos/obj/arm64e/ARCheat.dylib
```

ImGui 要自己放：

```bash
git clone --depth=1 https://github.com/ocornut/imgui vendor/imgui
# 需要：imgui.h / imgui_draw.cpp / imgui.cpp / imgui_tables.cpp / imgui_widgets.cpp
#       backends/imgui_impl_metal.{h,mm}
# 把 backends 里的两个文件与核心 cpp 一起加进 ARCheat_FILES
```

---

## 2. 拿解密后的 IPA（FairPlay 这一关绕不过去）

App Store 装的 app 是加密的，TrollFools 注入一个还带 FairPlay 加密段的二进制会跑不起来。

| 路线 | 前提 | 说明 |
|---|---|---|
| Dopamine 越狱 + bagbak / frida-ios-dump | iOS 16.1.1 arm64e，Dopamine 覆盖 15.0–16.6.1 | 解完把越狱环境清掉，再回 TrollStore |
| TrollStore 侧解密工具（TrollDecrypt 类） | 已装 TrollStore 2 | 可用性需实测，别当既定事实 |
| 已解密的 IPA 来源 | — | 校验 `cryptid == 0` 再用 |

验证解密：

```bash
otool -l Arena | grep -A4 LC_ENCRYPTION_INFO
# cryptid 0 = 已解密
```

---

## 3. 注入

```bash
# TrollFools（TrollStore 生态，免越狱）：选 app -> 选 dylib -> Inject
# 它会：拷贝 app bundle -> 加 LC_LOAD_DYLIB -> ldid fakesign -> 写回
```

注入后 dylib 落在：

```
/var/containers/Bundle/Application/<UUID>/Arena.app/PlugIns/ARCheat.dylib
```

→ 删 app 即完全清除（回滚就是这个）。

---

## 4. 填偏移（唯一真正花时间的部分）

`src/Game/Offsets.hpp` 里除 `POV_*` 以外全是 `0x000` 占位符。
**填错的表现不是崩溃，是"实体数量 0 或 4 亿"，会浪费整天。** 按这个顺序走：

1. **GNames 先拿**（dump 里白给），用来把 FName 索引翻译成类名 → 后面所有按名字校验都靠它
2. **GEngine**：不要盯裸 `GWorld` 全局。ACE 保护的构建上裸全局常是诱饵或需解密。
   走 `GEngine → GameViewportClient → World` 或 `GEngine → GameInstance → World`
3. **校验本轮定位**（这一步不做等于白干）：
   - `PersistentLevel.Actors.Num` 落在 几十 ~ 几百（不是 0，不是 4 亿）
   - 随便取一个 actor 读 RootComponent 的 ComponentToWorld 平移 → 坐标有限、量级像米
   - 上两条都过，才算真的进来了
4. 相机 `PlayerCameraManager.CameraCache[0].POV` 的 Location/Rotation/FOV 三个字段
   （`POV_*` 这几个在 UE4 公开布局里是稳定顺序，但仍要按版本核对）

本工程的 `Tweak.x` 带一个**探测模式**：拿不到世界时会退避重试并写日志，
日志在 app 容器 `Library/Caches/archeat.log`，用 Filza 或 `idevicesyslog` 看。

---

## 5. 验收顺序（按这个顺序测，不然查不出是哪一层错）

| 步 | 期望 | 失败说明 |
|---|---|---|
| 1 | 启动不闪退，`archeat.log` 有 `load pid=` | 注入/签名问题，回 TrollFools 重做 |
| 2 | 日志里出现 `就绪：world=... actors=N` | 偏移错，或撞上反篡改指针链（读一次对、下一帧全 null） |
| 3 | 三指双击出现菜单，帧率掉 <10% | 渲染挂点没挂上，见下节「挂点回退」 |
| 4 | ESP 框跟着真人移动 | W2S 的 Y 轴或 aspect 取错 |
| 5 | 自瞄平滑跟随 | 写错了字段（ControlRotation vs POV.Rotation） |

---

## 6. 挂点回退（引擎不走 CAMetalLayer 时）

`nextDrawable` 拿不到 drawable 的话，按这个顺序退：

1. 先确认 `CAMetalLayer` 类存在：`objc_getClass("CAMetalLayer")`
2. 退到 `-[MTLCommandBuffer presentDrawable:]`（这是 ObjC 方法，可交换）
3. 再退到引擎自己的 Present：Unity 找 `-[UnityAppController drawView]`，
   UE4 找 `FMetalViewport` 的 Present 调用点（IDA 里从 `nextDrawable` 的交叉引用往上翻）
4. 最后才用 `install_inline`，且必须先跑 `prologue_copyable()` 检查

---

## 7. 未验证清单（别当已知事实用）

- [ ] `off::GEngine` / `GNames` / `GWorld` 特征码 —— 需在你这份 arm64 二进制上扫
- [ ] 所有 `UNVERIFIED` 结构体偏移 —— 需 IDA 核对 `UWorld::PersistentLevel`、`ULevel::Actors`
- [ ] `FCameraCacheEntry` 里 POV 的起始偏移 —— 4.2x 与 4.27 不同，必须实测
- [ ] Metal pass 的呈现顺序 —— 我们的 pass 会不会被游戏后续 pass 覆盖，需真机验帧
- [ ] FTransform 的 ComponentToWorld 平移偏移（按 0x30 写的，需核对是否 3x4+平移的排布）
- [ ] 骨骼 TArray 的 stride（按 0x30 写的，需核对 ComponentSpace 布局）
- [ ] 自瞄写 `ControlRotation` 与 `POV.Rotation` 哪条在本作生效 —— 两条都写了兜底，需实测哪条管用
- [ ] TrollStore 痕迹拦截是否触发 anogs 的"异常枚举"判定 —— 需抓 anogs 上报对比注入前后
- [ ] 解密 IPA 的获取路线在 16.1.1 arm64e 上哪条可用

---

## 8. 关于 ACE (anogs) 的硬约束 —— 写进代码里的设计决定

依据对 anogs 架构的公开分析：

| anogs 的机制 | 本工程对应的设计决定 |
|---|---|
| 自校验自己的 `__text` | **绝不 patch anogs 的任何字节**。hook 只落在 libc 入口和 ObjC 方法上 |
| `kill(getpid(), 9)` 看门狗 | 不做"让检测函数返回 clean"这类操作，那会 desync 整个报告 |
| 交叉比对 `_dyld_get_image_name` / `TASK_DYLD_INFO` / `proc_regionfilename` | dyld 视图过滤**默认关闭**。粗暴隐藏产生的自相矛盾比"存在一个陌生 dylib"更显眼 |
| 检测脚本走服务端下发的字节码 VM | 不假设"改本地就能骗过"。判定在服务端，本地只控制异常面大小 |
| 上报经 TLS，可能是 pull 模型 | 不尝试阻断网络，没意义 |
| 会统计线程数 / 时序 | 不新建线程、不开 CADisplayLink，全部逻辑挂在游戏自己的 present 回调里 |

对应的代码位置：

- `src/Core/Stealth.hpp` 顶部注释 = 上面这张表的实现说明
- `Stealth::Options::filter_dyld_view = false` 是**故意**的默认值
- `install_inline` 前必过 `prologue_copyable()`，防止搬 PC 相对指令

---

## 9. 回滚与白苹果边界

**回滚**：TrollStore 里卸载 / 系统里删 app → `Application/<UUID>/` 整目录消失，dylib 随之清空。
改之前先 `cp -a Arena.app Arena.app.bak`。

**白苹果的唯一来源是系统层动作，本工程不碰任何一处**：

```
✗ remount / 改 /System/Library
✗ 往 /var/jb 推包、launchctl 装守护进程
✗ 改 dyld shared cache / 内核缓存
✗ 越狱中途断电或 OTA 更新
```

这四类以外的最坏结果是**游戏闪退 / 被服务端判定 / 账号异常**，设备照常开机。

---

## 10. 文件结构

```
Makefile                     Theos 工程（ARCHS = arm64 arm64e，不链 substrate）
control                      deb 元数据
Tweak.x                      入口：stealth 安装 + 世界探测 + 退避重试
src/Core/SafeMem.h           vm_read_overwrite 封装，所有读数唯一入口
src/Core/Hook.hpp            自带 hook 引擎：四陷阱防护 + ObjC 交换 + vtable 槽
src/Core/Stealth.hpp/.mm     dyld 视图 / P_TRACED / TrollStore 痕迹
src/Game/Offsets.hpp         全部版本相关数字（占位符 + UNVERIFIED 标注）
src/Game/World.hpp/.mm       GEngine 链 → 世界 → 实体 → 相机 → 骨骼
src/Game/Aim.hpp/.mm         W2S（自己算投影，不读 ViewMatrix）+ 自瞄
src/Render/Overlay.hpp/.mm   Metal 挂点 + ImGui 叠加 + 每帧驱动
```
