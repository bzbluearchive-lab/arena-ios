# 全系统同进程注入（system-wide in-process）

## 先说清楚这台设备上"全系统"意味着什么

TrollStore 本身**没有**全系统注入能力。它给你的是：
- 任意签名的 app 能跑（CoreTrust）
- 任意 entitlement 能被 AMFI 接受
- 单个 app bundle 可以被改写注入（TrollFools 那条路）

它**没有**给你"其他进程启动时自动加载我的 dylib"这个能力。那个能力必须由一个
在 launchd 侧的注入器提供。所以"全系统同进程"= 先装一个注入器，本题只有三条路：

| 路线 | 需要 | 系统级注入 | 与内核漏洞 | 这台设备 |
|---|---|---|---|---|
| **A. roothide Bootstrap**（TrollStore 生态的半越狱） | TrollStore 2 | ✅ ellekit + MobileSubstrate 兼容 | 不需要内核 exploit | 覆盖 14.0–16.6.1，**16.1.1 arm64e 需实测确认** |
| B. Dopamine 越狱 + ellekit/Substrate | 内核 exploit | ✅ 最正统 | 需要 | 15.0–16.6.1 arm64e 覆盖内 |
| C. `DYLD_INSERT_LIBRARIES` 环境变量 | — | ❌ 走不通 | — | 见下 |

### 为什么 C 走不通（这是硬事实，不是选择）

iOS 的 App Store 二进制是 hardened 签名。`DYLD_INSERT_LIBRARIES` 只对
带 `get-task-allow` 的调试构建生效；对平台二进制，dyld 与 AMFI 会直接拒绝加载
外部注入的库。改 `launchd.plist` 去设这个环境变量需要写 rootfs —— 那是越狱动作，
不是 TrollStore 动作。所以"用环境变量做全系统"这条路在 16.1.1 + TrollStore 上不存在。

## 推荐形态：A + 严格 filter

装好 Bootstrap 后，落两个文件：

```
/var/containers/Bundle/tweaksupport/Library/MobileSubstrate/DynamicLibraries/
    ARCheat.dylib
    ARCheat.plist          <- Filter.Bundles = com.proximabeta.mf.uamo
```

然后 respring。

**`Filter.Bundles` 必须留着。** 删掉它等于注入所有进程，包括 SpringBoard 与
backboardd：我们的 constructor 会在每个系统进程里跑一遍、在每个进程的镜像表里
各留一条记录、把日志写得到处都是。对 anogs 来说这是把异常面放大几十倍；
对设备来说，SpringBoard 被影响的表现是"卡在转圈/黑屏"，看着像白苹果（可恢复，
但排查极痛苦）。

这也是本工程 `Tweak.x` 里 `is_target_process()` 存在的理由：filter 是"别进那些进程"，
守卫是"万一进来了也立刻滚"。两道闸，缺一不可。

## 走全系统到底图什么

| 收益 | 说明 |
|---|---|
| **更新免疫** | 游戏版本更新后不用重新注入、不用重新签名 app。这是最大收益 |
| 多目标 | 国际服 + 国服 + 其他 UE4 游戏共用一份 dylib，filter 里加一行 |
| 加载时机更早 | dylib 在 `main()` 之前就进来了，比 PlugIns 静态加载更早一点 |

| 代价 | 说明 |
|---|---|
| **环境痕迹** | Bootstrap 会留下 `/var/containers/Bundle/tweaksupport`、`ellekit`、`dpkg` 状态、Sileo。**anogs 明确在找这些**。这是比"app 包里多一个 dylib"严重得多的暴露面 |
| 回滚不再是"删 app" | 要卸载 Bootstrap 本体（它有 uninstall），回滚面从"一个 app 目录"变成"一个系统环境" |
| 白苹果边界移动 | 见下 |

## 白苹果边界的变化（必须如实知道）

per-app 注入时，风险面是 0：所有文件都在 `Application/<UUID>/` 里，删 app 即清空。

换成 Bootstrap 之后，多出来的是这几样：

```
/var/containers/Bundle/tweaksupport/...      注入环境本体
launchd 侧的注入钩子                           启动链上多一环
/Library/... 或 mobile 侧的支持文件
```

这一层**能**把设备搞成卡开机（不是永久性砖：Bootstrap 自带 uninstall，且它刻意避开
rootfs 写入以支持无线更新，所以恢复路径是"进得去系统 → 跑 uninstall"）。
真正会导致不可恢复的是 B（内核 exploit 越狱）和内核 r/w 原语，不是 A。

判断标准很简单：
- 出问题时**还能进得去桌面** → Bootstrap uninstall → 回 TrollStore 单 app 注入
- 进不去桌面 → 只能走恢复模式/DFU，数据丢失

所以操作顺序建议：先放 kill switch 文件（`/var/mobile/Library/Preferences/archeat.off`），
确认"有它在，注入即静默"，再开始跑检测——保证任何时候都有一个不碰设备的止血开关。

## 针对 ACE，全系统形态要额外做的两件事

按优先级排（比 dyld 视图过滤重要得多）：

1. **环境痕迹伪装提到第一位**
   anogs 有一整套 jailbreak/环境探测。Bootstrap 的目录名是公开的，直接命中。
   要 hook 的是 `stat` / `access` / `fopen` / `opendir` 对以下路径的处理，
   以及 `dpkg` 状态目录、Sileo bundle 的存在性查询：
   ```
   /var/containers/Bundle/tweaksupport
   /var/containers/Bundle/trollstore
   /var/lib/dpkg
   /Applications/Sileo.app
   /var/jb
   ```
   本工程 `Stealth.mm` 里 `kSTPaths` 需要按 Bootstrap 实际路径增补。

2. **dyld 视图过滤仍然保持关闭**
   理由不变：anogs 会把 `_dyld_get_image_name` / `TASK_DYLD_INFO` /
   `proc_regionfilename` 三份结果交叉比对。在系统级注入环境下，镜像表本来就多出
   一整套 ellekit 的东西，此时再去"抹掉自己"，制造的自相矛盾比不抹更显眼。

## 验证顺序

| 步 | 期望 | 失败指向 |
|---|---|---|
| 1 | 装完 Bootstrap，respring 后系统正常，Sileo 能开 | Bootstrap 没装好，先别放 dylib |
| 2 | 放 kill switch 文件 → 启动游戏 → 日志无 `load pid=` | 守卫/filter 生效（这是"预期失败"） |
| 3 | 删 kill switch → 启动游戏 → 日志出现 `load pid=` | 注入路径通 |
| 4 | 打开 SpringBoard 侧日志，确认**没有**我们的写入 | `is_target_process()` 或 filter 有漏 |
| 5 | 游戏正常进对局、日志出现 `就绪 world=...` | 回到偏移问题，见 README §4 |
| 6 | 抓一份注入前后的 anogs 上报，对比事件类型 | 才知道环境伪装够不够 |

第 4 步和第 6 步是全系统形态的成本所在：把风险面从"一个 app"扩散到了"一个系统环境"，
就必须用数据确认扩散是可控的，否则不如回 per-app。

---

## 与工作区里另一条分支（daemon + SpringBoard 浮窗）的取舍

工作区里同时存在两套架构，它们是**互斥的两条技术路线**，不是同一件事的两种实现：

| | **全系统同进程**（本文） | **daemon + SpringBoard 浮窗**（`host/` `daemon/` `src/Inject/`） |
|---|---|---|
| 作弊代码跑在哪 | **游戏进程内**（dylib 被注入器载入游戏） | **SpringBoard 进程内**，游戏进程零代码 |
| 游戏包是否被改 | 否（注入器在外部） | 否 |
| 读游戏内存 | 同进程直接读，无需任何权限 | 跨进程：`task_for_pid` + `vm_read`，**需要 tfp 通过** |
| 画浮窗 | 在游戏的 Metal 上画（`nextDrawable`） | 在 SpringBoard 里开 `UIWindow`，靠 windowLevel 压过游戏 |
| 自瞄写视角 | 同进程直接写 `ControlRotation` | 跨进程写，依赖 tfp + `vm_write` |
| 系统环境痕迹 | **有**：`tweaksupport` / ellekit / dpkg，anogs 在找 | 无系统级注入环境，只有一对 app+daemon |
| 更新免疫 | ✅ 游戏更新不用重做 | ✅ 游戏更新不用重做 |
| 关键未知数 | Bootstrap 在 16.1.1 arm64e 上的稳定性与痕迹暴露 | `task_for_pid(SpringBoard)` 在 TrollStore 签名下是否返回 0 |
| 白苹果面 | Bootstrap 环境（可 uninstall 回滚） | 无系统写入，回滚=删两个 app |

**决策顺序建议**：先实测 `task_for_pid(SpringBoard)` 的返回码。

- 返回 **0（成功）** → 走 SpringBoard 分支。它把游戏进程保持干净，环境痕迹最少，
  而且这个方向不用装任何系统级注入环境。全系统同进程留着当 Plan B。
- 返回 **非 0** → tfp 这条路断了，SpringBoard 分支的读内存与自瞄全部作废，
  此时才需要为了"写内存能力"去承担 Bootstrap 的环境痕迹代价。

换句话说：**"全系统同进程"解决的是"能力"问题（能写游戏内存、能在游戏里画），
不是"隐蔽"问题**。它在能力上是上限最高的一条，在隐蔽上是下限最低的一条。
先确认能力是否已经由别的路径满足了，再决定要不要付这笔隐蔽性成本。

