# 跨进程可行性与形态（不做自瞄）

## 先把问题拆准

"不做自瞄"省掉的只有**写**（`ControlRotation` / `POV.Rotation`）。
**读**一点没省：跨进程读另一个 app 的内存，在 iOS 上依然要内核原语。
而透视最难的从来不是读，是**把像素画到游戏画面上**。

所以判断不是"能不能跨进程"，是"你要画面还是要数据"：

| 你要的 | 跨进程能不能给 |
|---|---|
| 屏幕上的 ESP 框/骨骼 | ❌ 给不了（iOS 没有跨 app 悬浮窗；SpringBoard 是 Apple 签名的平台二进制，TrollStore 注入不进去） |
| 旁边一个窗口看雷达/敌人列表 | ✅ 能（iPad + Stage Manager 分屏，见 B1） |
| 只拿数据（外置显示、语音播报、日志、录像分析） | ✅ 能 |
| 自瞄 | 需要写，你要不要都回到内核 |

## 三条落得下来的形态

### B1. kfd 跨进程读 + 独立 app 的雷达窗（iPad Stage Manager 分屏）

```
[TrollStore app: Radar]  --kfd-->  内核物理内存  --读-->  [游戏进程 vm_map]
         |
         +--> iPad 分屏（Stage Manager）显示 2D 雷达图 / 敌人列表
```

- 游戏进程 dyld 表**干净**，包内无 dylib，静态面无痕
- iPad Pro 2022 (M2) 支持 Stage Manager 分屏 —— 这是 iOS 上唯一不需要越狱、
  又能"同时看到游戏和作弊画面"的正规路径
- 代价：不是叠加在画面上，是并排。对 FPS 的实用性远低于 overlay ESP

### B2. kfd 读 + 仍然注入画 ESP

技术上成立，但**跨进程这一步变成纯负收益**：读走内核（更慢、更危险），画还得靠注入，
ACE 暴露面一点没少。不建议。

### B3. kfd 读 + 外置显示（形态 C 的软件版）

读出数据后通过局域网/蓝牙送到另一台设备或小屏显示。适合"看雷达不给画面"。

## kfd 在这台设备上的可行性

`kfd`（felix-pb/kfd）是**用户态**内核物理内存读写，不需要完整越狱，TrollStore 的
未沙盒 app 就能跑，正好对应"形态 B 但不越狱"。

- 你的环境：iOS 16.1.1 / arm64e (M2)
- kfd 的 exploit 分支（physpuppet / landa / kqueue workloop race 等）覆盖 14.x–16.x，
  16.1.1 通常在里面
- **需实测**：对着 kfd 仓库当前的支持表核对你这个具体版本+设备；不要默认通过

调用面（以仓库当前 `libkfd.h` 为准，名字可能有出入）：

```c
kfd_init(exploit_type);
uint64_t selftask = kfd_get_selftask();
uint64_t task     = kfd_get_task(pid);              // 目标 app 的 task
uint64_t vmmap    = kfd_get_vm_map(task);
kfd_read_mem(task, addr, buf, len);                 // 跨进程读
```

## 唯一真正危险的地方

形态 B 的所有风险都集中在一点：**内核物理读写出错 → panic / 内核数据损坏**。
这是全程唯一能把设备搞到起不来的操作面，和注入 dylib 完全两码事。

必须做的三件事：

1. **canary 校验后再采信任何读数**：读到的第一件事是校验目标 app 的 `mach_header`
   魔数（`0xFEEDFACF`）与 cputype，对不上就整条链路作废，绝不拿它去解引用
2. **物理地址范围白名单**：kfd 给的 pte 只对已解析且有 `VM_PROT_READ` 的页使用
3. **首轮只在快照/可恢复状态下测**：先跑只读路径压测 30 分钟不 panic，再谈功能

## 代码缝

- 同进程读：`src/Core/SafeMem.h` 的 `mem::read()`
- 跨进程读：`src/Core/XRead.h` 的 `xmem::read()`（kfd 后端，含 canary + 自进程回退）
- 上层 `World` / `Aim` / `Overlay` 只依赖 `rd / rdptr / wr` 语义，换后端不动

## 选择建议（按你的目标）

| 目标 | 选哪条 |
|---|---|
| 屏幕上要看到框/人 | 同进程注入（当前工程） |
| 只要能看敌人位置、可接受分屏 | B1，kfd + Stage Manager 雷达 |
| 完全不想让游戏进程里有东西 | B1 或 B3 |
| 想彻底不碰内核 | 只有同进程注入，或形态 C 硬件 |
