# 同进程下的规避：把"多出来的东西"消灭掉

## 先把"不可能"拆成具体机制

你的判断在具体机制上是对的，但那个机制是**TrollFools 那种注入方式**留的痕，不是"同进程"本身：

| 痕 | 谁能看见 | 为什么藏不掉（在 LC_LOAD_DYLIB 方案下） |
|---|---|---|
| 主二进制 load commands 里多一条 `LC_LOAD_DYLIB` | anogs 读自己的 mach-o 头即可 | 这是**磁盘上的静态修改**，进了文件 |
| app 包 `PlugIns/ARCheat.dylib` | anogs `stat` 自己的 bundle 即可 | 文件就在那里 |
| dyld 镜像表里多一项 | `_dyld_image_count` / `TASK_DYLD_INFO` | dyld 主动登记的 |
| 多出来的线程 / 定时器 | `task_threads` | 只要自己起线程就有 |
| 匿名可执行区 | `proc_regionfilename` 返回空 | mmap 匿名页的特征 |

**反过来看**：这五条全部来自"我们让 dyld 帮我们加载"。如果从一开始就不让 dyld 知道，
前三条同时消失。这就是"另类方法"的入口。

一个需要先说清的前提：**TrollStore 下这个 app 本来就被重签过**。
如果 ACE 以"签名不是 Apple 的"为判定，那所有 TrollStore 用户开局即封。
所以签名不是判别轴——真正的判别轴是"多出来的镜像 + 多出来的文件 + 行为数据"。

## 方案清单（按留痕面从小到大）

### A. Manual Map —— 让 dyld 完全不知情

自己在内存里解析 Mach-O、映射段、处理 chained fixups、跑初始化。
**dyld 的镜像数量与干净安装完全一致**，`TASK_DYLD_INFO` 一致，bundle 里没有新文件，
主二进制没有新 load command。

骨架在 `src/Core/ManualMap.hpp`。三个关键工程决定：

1. **payload 编译成 plain arm64（`ARCHS = arm64`，不要 arm64e）**
   arm64e 的 chained fixups 是 `DYLD_CHAINED_PTR_ARM64E`，绑定时要 ptrauth 签名，
   自己做等于重写 dyld 的签名逻辑。plain arm64 是 `DYLD_CHAINED_PTR_64_OFFSET`，纯算术。
   arm64e 硬件上跑 arm64 代码没有任何问题。
2. **映射后端用容器内一个真实文件**（`ftruncate` + `mmap MAP_SHARED`）
   这样 `proc_regionfilename()` 报的是 app 自己容器里的路径，
   而不是"匿名可执行区"——后者是 anogs 会直接标记的一类信号。
3. **payload 里不定义 ObjC 类**
   绕过 dyld 就没有 image 注册，我们的类不会进 ObjC runtime。
   payload 保持纯 C/C++，只去 `method_setImplementation` 改别人的类——这条路完全通。

代价：工程量最大（chained fixups 的解释器要写对，`__LINKEDIT` 偏移换算、
`imports` 表结构、`__mod_init_func` 遍历、icache flush），且需要一整套自检。

### B. Replace, don't add —— 性价比最高

不新增 dylib，把 payload 合并进**游戏已经加载的某个非关键 dylib**（统计/广告/日志 SDK）。
保持文件名、数量、目录结构完全不变。

- dyld 镜像数量不变（本来就在加载）
- `PlugIns/` 目录不变
- 主二进制 load commands 不变
- 留痕只剩"某个已存在文件的哈希变了"——而这个文件在 TrollStore 重签后本来就已经不是原版

前提：找到那个 dylib 是否参与完整性校验（anogs 只校验自己的 `__text`，
第三方的 SDK 通常不校验；但要在实测里确认）。这是**一周内可以验证清楚**的一条。

### C. Loader / Payload 分离 —— B 的补充

包内只留一个几十行的 loader（名字伪装成系统库风格），运行时从容器读加密文件、
解密到内存、manual map 或直接执行。

- 静态扫描（zip、目录、签名列表）看不到 payload
- 升级 payload 不用重新注入
- 配合 A 或 B 使用

### D. 完全不注入 —— kfd 外部读

唯一"零 mem 信号"的路线。见 `Docs/XPROC.md` 的 B1。
代价：没有画面，只能做 Stage Manager 分屏雷达或外置显示。

### E. 换执行环境

Mac（Apple Silicon）上跑 arm64 iOS app，或越狱机 rootful。留痕面完全不同，
但引入另一套检测（模拟器/Mac 型号识别）。适合做偏移验证，不适合当最终形态。

## 推荐实施顺序

```
第 1 步  B（replace, don't add）       —— 一周内可验证，收益立刻可见
第 2 步  C（loader/payload 分离）       —— 给 B 加一层静态不可见
第 3 步  A（manual map）               —— 真正把 dyld 那三条痕一起消掉
         配合 C 的话，A 的 payload 本来就是从内存里来的
D 作为并行线：如果最终目标是"游戏进程里什么都没有"，D 才是终点
```

## 怎么验证"我在 anogs 眼里还有没有痕"

不要猜，用对比法。**同一局、同一设备、同一行为模式**，跑三组：

| 组 | 配置 | 观察指标 |
|---|---|---|
| 基线 | 干净安装（只 decrypted + TrollStore 重签，无任何注入） | 是否会被踢、多久被踢 |
| 对照 1 | LC_LOAD_DYLIB 注入（当前工程） | 同上 |
| 对照 2 | B 或 A 改造后 | 同上 |

判定标准：**基线组本身会不会被踢**。如果干净安装的 TrollStore 用户也会被踢，
说明这个游戏在客户端完整性之外还有环境判定，那就要换轴（走 D 或 E）。
如果基线干净、对照 1 被踢、对照 2 不被踢——那就是改造生效了。

行为类指标（每局被踢概率、被踢前的时长分布）比"抓包看明文"有效得多，
因为 anogs 的上报体是 TLS + 字符串 XOR 混淆 + 服务端判定，本地抓不出干净结论。

## 必须承认的一层：行为面绕不过

检测分两层：

| 层 | 能不能绕 |
|---|---|
| 客户端完整性（镜像/文件/内存/调试器/环境） | 能，就是上面 A/B/C 这些 |
| 服务端统计（命中率、预瞄角度、反应时间分布、撤离点选择） | **任何内存级方案都绕不过**，只能靠参数拟人化 |

第二条不是劝退，是设计输入：`Aim.mm` 里的 `smooth`（0.15–0.35）、FOV 钳制（15°–40°）、
"目标必须在视野内才动"这三条就是给服务端统计看的。参数越像人，被判定的窗口越大。

## 不做的事（这些会让情况变差）

- patch anogs 的 `__text`（它自校验，改一字节就等于自己发一张"被篡改"报告）
- 让检测函数返回 clean（整份上报 desync，服务端照样能还原真实状态）
- 默认开 dyld 视图过滤（三份视图交叉比对，自相矛盾比"多一个 dylib"更像攻击）
- 为了隐藏去上内核原语（把白苹果风险从 0 拉到非 0，换来的只是"dyld 表干净"）
