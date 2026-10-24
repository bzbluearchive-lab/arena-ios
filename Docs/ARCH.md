# 架构决策：同进程注入 vs 跨进程

## 结论

**当前路线 = 同进程（in-process）注入。**

dylib 进 `Arena.app/PlugIns/`，跑在游戏进程地址空间内，读写自己进程的内存（`mach_task_self()`）。
不跨进程、不需要 `task_for_pid`、不需要任何内核权限。

这不是"更省事"的偷懒选择，在这个目标上是四条约束共同推出来的唯一可行解：

| 约束 | 同进程 | 跨进程 |
|---|---|---|
| iOS 无"悬浮窗"权限（没有 Android 那种 SYSTEM_ALERT_WINDOW，跨 app 合成不了画面） | ESP 能画 | **ESP 画不出来**，只能读数据 |
| TrollStore 不 patch 内核，`task_for_pid` 仍由 taskgated 把关 | 不需要 | 要越狱 + 内核原语（kfd / libkernrw / tfp0） |
| 自瞄要写 `ControlRotation` | 本进程直接写 | 要跨进程写，只能靠内核 r/w |
| ACE 的检测面 | 进程内多一个 dylib（可见） | 游戏 dyld 表里干净（但你需要另找一条路把画面画上去） |

关键点：**ESP 必须在渲染器内部画**。iOS 上另一个进程没法叠在全屏游戏之上，所以
"完全跨进程"在这台设备上等于"放弃透视，只留读数据和自瞄"。而自瞄又需要写内存，
又回到需要内核。

## 四种形态对比（这台设备：iPad Pro M2 / iOS 16.1.1 / TrollStore 2）

| 形态 | 可行性 | ACE 暴露面 | ESP | 自瞄 | 与白苹果的关系 |
|---|---|---|---|---|---|
| **A. 同进程注入（本工程）** | ✅ TrollStore 直接支持 | 多一个 dylib；同地址空间可被 anogs 扫 | ✅ | ✅ | 无关，全在沙盒 |
| B. 越狱 + 内核 r/w（kfd/libkernrw）跨进程读 | ⚠️ 要 Dopamine，且跨进程**写**更难 | 游戏视角下干净 | ❌ 仍需注入才能画 | ⚠️ | 内核原语读写出错会 panic，这是**唯一会崩设备**的一条 |
| C. 外部硬件（采集卡/外置机读画面） | 理论可行，工程成本高 | 极低 | ⚠️ 要外接显示 | ❌ | 无关 |
| D. 网络层（改包/重放） | 服务端权威 + 加密 + 状态同步，收益极低 | 中 | ❌ | ❌ | 无关 |

B 之所以危险：`kfd`/`libkernrw` 这类东西一旦把错误的物理地址写进内核结构，
结果是 panic 或内核数据损坏 —— 这才是真正的"变砖级"操作面，和注入 dylib 完全两码事。

## 代码里的切换缝在哪

读层被刻意收在一个文件里：`src/Core/SafeMem.h` 的 `mem::read()`。

```cpp
// 现在：同进程
vm_read_overwrite(mach_task_self(), addr, n, out, &got);

// 若要换成跨进程（形态 B），只需在这里换实现：
// kfd_read(kfd_fd, pid, addr, out, n);
// 上层 World.mm / Aim.mm / Overlay.mm 一行都不用改
```

`World` / `Aim` / `Overlay` 全部只依赖 `mem::rd` / `mem::rdptr` / `mem::wr` 三个语义，
不依赖具体是哪个进程的地址空间。这是刻意的：将来要做形态 B 的对比实验，改一个函数即可。

## 为什么不同时做"loader/payload 分离"

可选形态 A'：包内只放一个几十行的 loader dylib（名字伪装成系统库风格），
运行时从容器目录 `dlopen` 真正的 payload，`dlopen` 完立刻 `unlink` 文件。

- 收益：静态扫描（zip 包/`Frameworks` 目录/签名列表）看不到 payload；升级 payload 不用重新注入
- 代价：运行时仍多出镜像项，且 `dlopen` 一个无签名 mach-o 在 TrollStore 环境下的行为需要实测；
  匿名映射 + 可执行权限本身就是 anogs 会看的一类信号
- 现状：本工程**未采用**。理由是先按"零新增异常面"做，等 A 跑通、有一份注入前后的
  anogs 上报对比数据，再决定要不要加这一层

## 不做的事

- 不 patch anogs 的 `__text`（它自校验）
- 不把检测函数改成返回 clean（会让整份上报 desync）
- 不默认开启 dyld 视图过滤（三份视图交叉比对，自相矛盾比"多一个 dylib"更像攻击）
- 不为了"更隐藏"去上内核原语（那是把白苹果风险从 0 拉到非 0 的唯一动作）
