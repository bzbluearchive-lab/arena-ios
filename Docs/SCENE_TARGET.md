# 三个测试的判读：浮窗挂在哪个 scene 上

## 你的三条观察

| 测试 | 结果 |
|---|---|
| App 切换器（多任务） | 浮窗完全正常，位置不变 |
| 息屏 / 锁屏 | **浮窗消失** |
| 通知栏（通知中心） | 浮窗**没有**消失 |

## 判读

这三条同时成立，只有一种解释：**浮窗挂在 SpringBoard 的一个系统 scene 上，
层级高于通知中心，但不在锁屏 scene 里。**

拆开看：

### 切换器正常 → 排除"挂在游戏的 app scene 上"

App 切换器会把每个 app 的窗口缩成卡片并做景深虚化。如果浮窗属于游戏的 scene，
它会跟着一起被缩小、虚化、变暗。你看到"完全正常、位置不变"，
说明它**不在 app scene 里**，是 SpringBoard 自己那一层的。

### 通知栏不消失 → 它的 windowLevel 高于通知中心

通知中心是 SpringBoard 的一个浮层窗口。浮窗压在它上面，说明层级更高。
这条说明"高层级窗口"这个做法是成立的，不需要动 scene 之外的东西。

### 锁屏消失 → 它不在锁屏 scene 里

这是最关键的一条，而且**它不削弱 β 结论，反而精确定位了 scene 归属**：

SpringBoard 有几个不同的 scene：

```
HomeScreen scene     ← 主屏 + 切换器 + 通知中心 都在这一层
LockScreen scene     ← 锁屏，独立 scene
每个 app 的 scene    ← 前台 app 内容
```

浮窗挂在 **HomeScreen 那个 scene** 上。锁屏时 HomeScreen scene 被锁屏 scene 覆盖，
浮窗随之不可见——这是系统行为，不是它崩了。

## 这对实现意味着什么

### 不需要碰锁屏 scene

好消息：锁屏 scene 属于更敏感的区域（涉及隐私、可能触发额外检测）。
我们要复刻的效果**不需要它**——商业产品自己也没做。

### 要精确选中 HomeScreen scene，不是随便一个

SpringBoard 里 `UIApplication.connectedScenes` 会同时包含多个 scene。
挂错 scene 的症状：切换器里跟着缩放、或者根本不显示。

选法（按优先级打分）：

```
delegate 类名含 "HomeScreen"        → 强正分
role 为 UIWindowSceneSessionRoleApplication 且是 SpringBoard 自己的 → 次选
delegate 类名含 "Lock" 或 "LockScreen" → 强负分（排除）
某 app 的 scene（SBApplicationScene）  → 负分（排除）
activationState == ForegroundActive  → 正分
```

第一次运行时把这个列表打出来（scene 标识 + delegate 类名 + activationState），
就能在你这个具体系统版本上确认哪个是 HomeScreen scene。

### 要处理 scene 切换

锁屏 → 解锁 → 回桌面，HomeScreen scene 可能被销毁重建。
必须监听 `UISceneDidActivateNotification` / `UISceneWillDeactivateNotification`，
重新挂载窗口，否则解锁后浮窗就再也不回来了。

## 复刻的完整链路（β 确认版）

```
[启动器 app]  --posix_spawn-->  [daemon]
                                   │
                                   ├─ task_for_pid(SpringBoard)
                                   ├─ dlopen payload（remote thread）
                                   ▼
                            [SpringBoard]
                                   └─ payload: 选 HomeScreen scene
                                              建 UIWindow，level > 通知中心
                                              监听 scene 切换重建
                                              画 ESP（UIView / CALayer）
```

## 剩余未知（必须实测）

- [ ] 你这个系统版本上 HomeScreen scene 的确切标识（先打日志确认）
- [ ] 盖过通知中心需要的 windowLevel 具体值（先用 20000000 试，不够再往上）
- [ ] 切换器虚化对浮窗有没有影响（你的观察说没有，但要确认是否真的完全不虚）
- [ ] 解锁后 HomeScreen scene 是否重建（决定要不要强制重建窗口）
- [ ] 浮窗在"控制中心"里是否仍在最上（最接近通知中心，再验一次更稳）
- [ ] 触摸事件的穿透行为：不点菜单时点击是否直达下面的游戏
