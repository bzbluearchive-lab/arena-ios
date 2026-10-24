# arena-ios

iOS 上的 UE4 研究工程：**启动器 app + 常驻 daemon + 注入 SpringBoard 的浮窗载荷**。
目标参考设备：iPad Pro (M2) / iOS 16.1.1 / TrollStore。

不用在本机装任何编译器 —— 编译交给 GitHub Actions 的 macOS 机器。

---

## 怎么出包（三步，2 分钟）

1. 建一个**私有仓库**（Actions 私有仓库每月 2000 分钟免费，这个工程一轮约 2 分钟）
2. 把这个目录整个拖进仓库的 `Add file → Upload files`
3. 仓库页 → `Actions` → 跑完后在页面底部 `Artifacts` 下载 **`ARHost-release`**

解出 `ARHost.ipa` → TrollStore → `Apps` → 右上角 `+` → 安装。

详细步骤（含 `.github` 隐藏目录漏传时的补救）：[Docs/UPLOAD-VIA-WEB.md](Docs/UPLOAD-VIA-WEB.md)

---

## 装到设备后验什么

| 步 | 操作 | 通过标准 |
|---|---|---|
| 1 | 打开 AR Host，点「启动 daemon」 | 每秒一行 `tick` |
| 2 | 从多任务划掉 AR Host，重开看日志 | `tick` 继续涨，且 `ppid=1` |
| 3 | Filza 进程列表 | `ARDaemon`，PPID=1 |
| 4 | daemon 日志 | `task_for_pid(SpringBoard) -> 0 OK` |
| 5 | 屏幕 | 中央绿框；划出控制中心/通知中心/多任务，绿框都压最上且位置不变 |

任一步失败就停在那一步，别往下跑。

---

## 结构

```
.github/workflows/build.yml   macOS runner：装 theos+SDK → 自检 → 编译 → 上传
host/                         启动器 app（配置 UI + 孵化 daemon）
daemon/                       常驻进程（注入 SpringBoard，活过 app 退出）
payload/                      注入用的 dylib（选 scene + 高层级 UIWindow）
src/Inject/SBWindow.mm        浮窗实现
src/Inject/RemoteLoad.h       远程 dlopen（task_for_pid + thread_create_running）
src/Host/DaemonSpawn.h        posix_spawn + SETSID
src/Game/                     引擎链解析、W2S、偏移（下一步接数据用）
src/Core/                     SafeMem / XTaskPort / SharedFrame（读内存后端）
tools/preflight.py            工程静态自检（37 项，Windows 上也能跑）
tools/package.sh              组装 + ldid 签名 + 出 ipa
Docs/                         机制分析、实测判读、上传步骤
Makefile.legacy-tweak         旧方案：整包注入游戏的 tweak（验证 src/Game 偏移逻辑用）
```

---

## 设计要点

- **游戏包零修改**，游戏进程零代码：浮窗住在 SpringBoard 里
- **daemon 用 `POSIX_SPAWN_SETSID` 孵化**，所以划掉 app 不影响它；不注册 launchd，所以重启后自动消失（与实测的商业产品一致）
- **payload 只编 arm64**，避开 arm64e 的 chained fixups + ptrauth 绑定
- **不碰 anogs 的 `__text`**（它自校验），hook 只落在 libc 入口与 ObjC 方法上

判断依据见 [Docs/RUNTIME_INJECT.md](Docs/RUNTIME_INJECT.md)、[Docs/SCENE_TARGET.md](Docs/SCENE_TARGET.md)、[Docs/DAEMON_MODEL.md](Docs/DAEMON_MODEL.md)。

---

## 当前状态

| 项 | 状态 |
|---|---|
| 架构判定（依据四个实测现象） | 已完成 |
| 三件套工程 + 打包 + 静态自检 37 项 | 已完成 |
| 编译 | 走 Actions，待首次构建 |
| 真实偏移、跨进程读 | 待设备验证后接入 |

待实测清单（拿到包后在设备上确认）：

- [ ] `task_for_pid(SpringBoard)` 返回码
- [ ] 16.1.1 上 HomeScreen scene 的 delegate 类名
- [ ] 盖过通知中心需要的 `windowLevel`
- [ ] TrollStore 安装是否保留私有 entitlements（不保留则改 TrollFools）
