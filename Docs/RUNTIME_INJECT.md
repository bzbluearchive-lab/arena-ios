# 最后一个分叉：浮窗的宿主是谁

## 已经定死的部分

| 观察 | 结论 |
|---|---|
| 游戏退出，浮窗仍在 | 与游戏进程无关 |
| 外挂 app 退出，浮窗仍在工作 | 浮窗不归那个 app 进程所有 |
| 盖在任何系统浮窗之上 | 层级高于 SpringBoard 自己的 HUD |
| 重启后需手动再开 | **无 launchd 持久化** → 不是注册的常驻服务 |

前三条指向"两个进程"，第四条把 H2（launchd）排掉。剩下两种可能：

### 形态 α：daemon 自己持有窗口

daemon 是个普通进程，靠 `CAContext` / FrontBoard 侧 API 拿到可见层级。
问题：`UIWindow` + `UIScene` 这条路在 app 生命周期之外走不通，
非 app 进程要拿到窗口是整套方案里最不确定的一环。

### 形态 β：运行时注入 SpringBoard

```
[App] --spawn--> [Daemon] --task_for_pid--> [SpringBoard 进程]
                                              ↑ 运行时注入，磁盘零修改
                                              └ 浮窗在这里，层级天然最高
```

这条能同时解释四个观察，而且解释得最干净：

- 浮窗在 SpringBoard 里 → 游戏退出、外挂 app 退出都不影响它
- SpringBoard 自己的 layer → 天然在系统 HUD 之上
- 纯运行时注入，磁盘上不落东西 → 重启后 SpringBoard 重来，浮窗消失，需手动再开

## 一个实验分清楚

**看 App 切换器（多任务界面）。**

游戏和浮窗都开着时，双击 Home / 上滑呼出多任务界面，观察浮窗：

| 现象 | 判读 |
|---|---|
| 浮窗**仍然在，位置不变，压在所有 app 卡片之上** | **形态 β** —— 切换器本身是 SpringBoard 画的，能压在它上面的只能是同一个进程里的东西 |
| 浮窗消失、被缩成一张卡片、或位置错乱 | 形态 α —— 它属于某个 app scene |

辅助判据（有就更快）：

- **锁屏**：浮窗在锁屏界面上还在吗？在 → β（锁屏也是 SpringBoard）
- **`ps -A -o pid,ppid,comm`**：外挂 app 划掉后，有没有一个 PPID=1 的第三方进程？
  - 有 → 那个 daemon 活着（两种形态都需要它当注入器/看门狗）
  - **没有** → 浮窗一定在系统进程里，形态 β 板上钉钉

## 形态 β 的实现链（这就是"另类方法"的正解）

整条链不需要改任何磁盘文件，也不需要动游戏包：

```
1. task_for_pid(SpringBoard_pid)  → 拿到 SpringBoard 的 task port
   需要的 entitlement：com.apple.system-task-ports（或 platform-application 组合）
2. 在 SpringBoard 里分配内存 + 写入 payload 的 dylib 路径
   payload 放自己 app 容器的 Documents/，SpringBoard 未沙盒，读得到
3. thread_create_running，pc 指向 dlopen
   ★ 关键：libdyld 在 dyld shared cache 里，所有进程映射地址一致
     → 我们进程里 dlsym(RTLD_DEFAULT,"dlopen") 的值，到 SpringBoard 里照样有效
4. dlopen 返回后，payload 的 constructor 在 SpringBoard 里跑
5. payload 建 UIWindow，windowLevel 拉到顶
6. 触摸由 SpringBoard 自己派发（窗口就在它的进程里）
```

第 3 步是整个方案的支点：**shared cache 让函数地址跨进程一致**，
所以远程调用 `dlopen` 不需要在目标里找符号。

骨架在 `src/Inject/RemoteLoad.h`。

### 为什么这比注入游戏包更抗分析

| | 注入游戏包 | 运行时注入 SpringBoard |
|---|---|---|
| 磁盘修改 | 改主二进制 load commands + 多一个文件 | **零** |
| 游戏进程 | 有我们的代码（anogs 直接分析） | **零** |
| 被分析方能看到 | 一个在读它内存的 dylib | 至多看到"有进程拿过我的 task port" |
| ACE 的检测位置 | 就在它眼皮底下 | 不在游戏进程里 |

## 风险分层（这条比什么都重要）

即使走到形态 β 这一步，最坏结果仍然是**有界的**：

| 动作 | 最坏结果 | 恢复方式 |
|---|---|---|
| payload 在 SpringBoard 里崩溃 | respring（SpringBoard 自动重启），屏幕黑一下回来 | 自动恢复 |
| payload 死循环卡住 SpringBoard | 强制重启设备 | 按住电源+音量 |
| task port 拿失败 | 注入失败，什么都不发生 | 无 |
| **白苹果（卡 logo 不起来）** | 需要破坏开机链：rootfs / dyld cache / 内核缓存 / 启动脚本 | —— |

**形态 β 完全够不到开机链**：它只在用户态进程里跑，磁盘零写入，没有一处会留在重启路径上。
这正是回到你第一个问题的答案：这条路的天花板是 respring，不是白苹果。

## 待验证（按顺序，前两项决定后面全部）

- [ ] App 切换器里浮窗是否仍压在最上层（分辨 α / β）
- [ ] `ps` 里 app 划掉后是否还有 PPID=1 的第三方进程
- [ ] TrollStore 环境下 `task_for_pid(SpringBoard_pid)` 是否返回 KERN_SUCCESS
- [ ] 远程 `thread_create_running` + `dlopen` 在 SpringBoard 里是否成功
- [ ] SpringBoard 里新建的 `UIWindow` 用哪个 windowLevel 才能盖过 HUD
- [ ] 关闭按钮是怎么通知 payload 退出的（信号 / 共享内存标志位 / 直接 kill）

## 两个形态的工作量对比

| | 形态 α（daemon 自带窗口） | 形态 β（注入 SpringBoard） |
|---|---|---|
| 窗口机制 | 未知，要试 CAContext/FrontBoard，可能卡死 | 就是 `UIWindow`，成熟 |
| 绘制 | UIView / CALayer | UIView / CALayer（同） |
| 读内存 | task_for_pid 或 kfd | 同（可在 payload 里做，也可在 daemon 里做完传过去） |
| 主要风险 | 拿不到窗口 | SpringBoard 崩溃 → respring |
| 我的判断 | 不确定性最高 | **可验证性最高，先做这个** |
