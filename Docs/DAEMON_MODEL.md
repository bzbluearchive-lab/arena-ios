# 浮窗活过"外挂程序退出"意味着什么

## 三个事实叠起来

1. 游戏退出，浮窗仍在工作 → 它与游戏进程无关（这条上一轮已定）
2. **外挂 app 退出，浮窗不消失也不停止** → 浮窗的持有者不是那个 app
3. 直到你主动关才停 → 有一个显式的终止入口，说明持有者是个能被命令结束的进程

一个 iOS app 被划掉后，它创建的 `UIWindow`、`UIScene`、`CAContext`
**全部随之销毁**——这是系统的清理逻辑，没有例外。所以浮窗还在，
只能说明它**不属于那个 app 进程**。

结论：这是**至少两个进程**的结构。

```
[App：菜单 / 配置 / 启动器]   ← 你划掉的这个
        │ posix_spawn / launchctl
        ▼
[Daemon：持有浮窗 + 读内存 + 绘制 + 收触摸]   ← 真正干活的
```

也正因为 daemon 自己也做读内存和绘制，它才能在外挂 app 死掉后继续"正常工作"——
它不依赖 app 提供任何数据。

## 三种可能，用五个实验区分

| 假设 | 说明 |
|---|---|
| **H1 手动 daemonize 的子进程** | app `posix_spawn` 一个 helper，helper `setsid()` 脱离进程组，父进程死它不死 |
| **H2 launchd 注册的常驻服务** | 通过 launchctl 注册 LaunchAgent，由 launchd 拉起，与 app 生命周期完全无关 |
| **H3 系统服务侧持有** | 浮窗实际由某个系统侧进程持有，app 只是控制器 |

判别实验，按顺序做，前两个就能定死：

| # | 实验 | H1 | H2 | H3 |
|---|---|---|---|---|
| 1 | **重启设备**，不打开那个 app，浮窗自己回来吗 | 不回来 | **自己回来** | 不回来 |
| 2 | 浮窗工作时看进程列表，找那个可疑进程的 **PPID** | `1`（孤儿/已 daemonize） | `1`（launchd 拉起） | 指向某个系统进程 |
| 3 | `ls -la <app>/` 看包里有没有**第二个可执行文件** | 有 | 有或没有 | 无 |
| 4 | 点浮窗上的"关闭"，同时盯着 `ps`，哪个进程消失了 | 那个 helper | 那个服务 | 系统侧进程内的一层 |
| 5 | 未沙盒环境下 `launchctl list \| grep -i <名字>` | 无 | **有** | 无 |

进程列表在 Filza 的进程视图里能看，或者你的外挂如果带终端更直接。
`ps -A -o pid,ppid,comm` 是最省事的格式。

## 复刻的路径（按实验结论选）

### H1 成立 → 先证明"TrollStore app 能 daemonize"

这是整条路的地基，**20 分钟能验完**。骨架在 `src/Host/DaemonSpawn.mm`。

最小验证实验：

1. 写一个 TrollStore app，bundle 里放第二个 Mach-O（`helper`，用 ldid 签）
2. app 启动时 `posix_spawn` 它，带 `POSIX_SPAWN_SETSID`
3. helper 里 `setsid()`，每 2 秒往容器日志写一行
4. 从多任务里把 app 划掉
5. 看日志还在不在涨

- 还在涨 → TrollStore 的未沙盒 app 可以孵化常驻进程，H1 的路通
- 停了 → SpringBoard 连进程组一起杀了，需要 double-fork + `setsid()` 组合，
  或者直接转 H2

### H2 成立 → launchctl 注册

未沙盒 + `platform-application` 的进程有可能通过 `launchctl bootstrap`
在用户域注册服务。需要试的 entitlement：

```
platform-application
com.apple.private.security.no-sandbox
com.apple.private.launchd.keepalive
com.apple.private.launchd.manager
```

这条路的好处是**重启后自动起来**，坏处是注册痕迹可枚举（`launchctl list` 一眼看到）。

### H3 成立 → 那就得先弄清是哪个系统服务，复杂度最高

## 真正的难点不是 daemon，是"daemon 怎么拿到窗口"

app 之外的进程想显示东西，常规做法（`UIWindow` + `UIScene`）走不通，
因为没有 app 生命周期就没有 scene。

可试的顺序：

1. **`CAContext`**：`CAContext contextWithCGSConnection:options:` 拿 contextId，
   把自己的 `CALayer` 树挂上去。问题是需要宿主 —— 但如果你想做的就是
   "盖在所有东西之上"，宿主的层级恰恰是要研究的
2. **FrontBoard 侧申请高 level 的 scene**：需要 `com.apple.frontboard.*` 类 entitlement
3. **让 daemon 表现得像一个后台 app**：`LSBackgroundOnly` + 自建 scene

这一层我**没有任何实测数据**，属于必须动手试的部分。上一轮那份
`Docs/OVERLAY_HOST.md` 里的实验 B（dump 那款产品的 entitlements 和链接框架）
在这里价值最大：它到底链接了 `FrontBoard` 还是 `BackBoardServices` 还是只用了
`QuartzCore`，直接决定走哪条。

## 对本工程的影响（又一次形态调整）

如果 H1 或 H2 成立，最终形态是：

```
包结构
  Cheat.app/
    Cheat           ← 启动器 + 配置 UI（你划掉的那个）
    CheatDaemon     ← 浮窗持有者 + 读内存 + 绘制 + 触摸
    Info.plist
  entitlements.plist
```

- 游戏包：**零修改**（维持上一轮的结论）
- 游戏进程：**零代码**
- 能直接复用的：`World.mm` 的引擎链解析与校验、`Offsets.hpp`、`Aim.mm` 的 W2S
- 可以删掉的：`Tweak.x`、`Stealth.mm`、`ManualMap.hpp`（它们解决的是注入痕迹问题）
- 绘制层换成 `UIView` / `CALayer`，`Overlay.mm` 的 Metal/ImGui 那套要重写

## 待验证（必须实测）

- [ ] TrollStore 未沙盒 app 孵化的子进程，能否在 app 被划掉后存活
- [ ] 存活的话，子进程能否拿到可见窗口（CAContext / FrontBoard 哪条通）
- [ ] launchd 注册在未沙盒但非 root 的情况下是否被接受
- [ ] 那款产品是 H1 还是 H2（重启实验 + PPID 一看就知道）
- [ ] 它读内存用 task port 还是内核原语
