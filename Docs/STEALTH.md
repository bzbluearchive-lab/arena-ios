# 隐蔽性加固（per-app 注入 · 游戏进程内）

目标：把"能被 anogs 上报的信号"从多压到少，同时**不制造自相矛盾**。
自相矛盾（该有的没有、不该有的有）比"存在"本身更容易被判定为攻击。

---

## 0. 先明确上限在哪

anogs 是**报告引擎 + 服务端判定**。它做的不是"发现就踢"，而是收集环境/内存/调试/
行为信号，打成报告上传，由服务端下结论。所以：

- 能做到的：把可上报信号的数量与一致性控制住，让报告"看起来像正常设备"
- 做不到的：保证不被判定。任何声称能保证的都是猜
- 唯一可靠的验证方式：**黑盒对照实验**——注入前后各跑几局，抓 anogs 的上报，
  对比事件类型与数量。没有这个对比，一切隐蔽性工作都是自我安慰

---

## 1. 分层加固清单（按 ROI 排序）

### Tier 0 —— 不产生新的信号面（收益最大，成本最低）

| 项 | 现状 | 做法 |
|---|---|---|
| 不新建线程 | ✅ 已做 | 全部逻辑挂在游戏自己的 `present` 回调里 |
| 不建 CADisplayLink / NSTimer | ✅ 已做 | 同上 |
| **不建匿名可执行区域** | ⚠️ 需改 | `mmap(MAP_ANON|MAP_JIT)` 做的 trampoline 是"无 backing file 的可执行区域"——笔记里点名的强信号。见 §3 |
| 不 dlopen 第三方库 | ✅ 已做 | ImGui 静态编进 dylib |
| 不写磁盘配置 | ✅ 已做 | 配置只在内存 |
| 不联网、不发包 | ✅ 已做 | — |
| 不 addObserver 系统通知 | ✅ 已做 | — |

### Tier 1 —— 降低静态可判定性

| 项 | 做法 |
|---|---|
| **明文字符串清零** | 用 `XStr{"..."}` 编译期 XOR。见 [src/Core/Obfs.hpp](../src/Core/Obfs.hpp) |
| 符号表 | `-fvisibility=hidden` + `-Wl,-x`（strip 局部符号） |
| 不暴露函数名 | 不开 `-g`；不导出 C++ 符号（`-fno-rtti` 已有） |
| dylib 命名 | **不做假名伪装**。叫 `libsystem_xxx` 却躺在 `PlugIns/` 下，本身就是矛盾信号，比真名更糟 |
| 菜单/窗口标题 | 不出现任何语义词（现在叫 "ARCheat"，改掉） |
| NSLog 标签 | 系统日志里留 `[ARCheat]` 等于自己上报，改掉或只写文件 |

### Tier 2 —— 已知探测项对照

| anogs 侧可能的探测 | 我们现在的行为 | 处置 |
|---|---|---|
| `_dyld_image_count` / `_dyld_get_image_name` | 会看到 `PlugIns/xxx.dylib` | **不动视图**。三份视图交叉比对，抹自己会制造矛盾。接受这一条 |
| `TASK_DYLD_INFO` / `proc_regionfilename` | 真实一致 | 不动 |
| 匿名 RX 区域 walk | 来自 inline hook trampoline | 默认禁用 inline hook |
| ObjC `method_getImplementation` 是否落在已知 image | 落在我们 dylib 内 | 无法消除。对策：**只 swizzle 两个方法**（`nextDrawable` / `present`） |
| 越狱 / TrollStore 痕迹（`trollstore`、`/var/jb`、`tweaksupport`、`dpkg`） | 已拦 | 保留，这是真信号 |
| 调试器附加（`P_TRACED`、`PT_DENY_ATTACH`） | 现在默认开 | **改为默认关**。生产环境不调试就不需要；主动调 `PT_DENY_ATTACH` 本身是个可被反查的动作 |
| 明文 cheat 字样内存扫描 | 现在有 | Tier 1 清理后消除 |
| 线程数 / 时序方差 | 与未注入一致 | 保持 |
| 行为面（视角突变、完美跟枪） | 取决于参数 | §4 |

### Tier 3 —— 行为面

- 首轮只开 ESP，**不开自瞄**。写 `ControlRotation` 是可被回放分析抓的动作，先确认 ESP 阶段不触发
- 自瞄参数拟人化：FOV ≤ 30°、smooth 0.2–0.35、加 ±0.3° 随机抖动、不常锁同一部位
- 只在 in-match 画（大厅/加载界面不动作）——在菜单里就画等于把常驻行为暴露
- 单局使用时长控制，不做 24 小时在线

---

## 2. 与"全系统同进程"的隐蔽性对比（结论：per-app 更隐蔽）

| | per-app 注入（本方案） | 全系统同进程（Bootstrap） |
|---|---|---|
| 系统级注入环境 | 无 | `tweaksupport` + ellekit + dpkg，**anogs 明确在找** |
| 游戏进程内的存在 | 一个 dylib | 一个 dylib + 整套 loader |
| 白苹果面 | 0（删 app 即清空） | Bootstrap 环境（可 uninstall 回滚） |
| 更新免疫 | ❌ 游戏更新要重做 | ✅ |

**唯一劣势是游戏更新要重新注入。** 这是可以接受的成本：更新后重做一次注入 + 重新核对偏移，
本来就是必须做的事（版本变了偏移也变）。

---

## 3. 匿名可执行区域：必须改的那一处

`Hook.hpp` 的 `install_inline()` 现在是：

```cpp
void* tramp = mmap(nullptr, tsize, PROT_READ|PROT_WRITE,
                   MAP_PRIVATE|MAP_ANONYMOUS|MAP_JIT, -1, 0);
vm_protect(..., VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
```

这会在进程里造出一个**无 backing file 的 RWX/可执行区域**。anogs 的 region walk
正好在找这种东西。三条处置，按优先级：

1. **不用 inline hook**（推荐）。本工程主干是 ObjC 方法交换 + vtable 槽替换，
   两条都不需要分配可执行内存。`install_inline` 改成编译期开关，默认 `AR_ALLOW_INLINE_HOOK=0`
2. 必须用时，把 trampoline 放进 dylib 自己的静态节（`__TEXT,__arthunk`），
   有 backing file、在已知 image 范围内，不再是"匿名可执行"
3. 至少不要 `MAP_JIT`（它是给 JIT 用的，一个普通 dylib 申请 MAP_JIT 本身就是异常）

---

## 4. 黑盒对照实验（唯一能判定"是否更隐蔽"的方法）

```
A 组：干净设备，跑 3 局，抓 anogs 上报（proxy 抓 TLS 或抓 AnoSDKGetReportData 的 blob）
B 组：注入但全功能关闭（只加载 dylib，不装 hook），跑 3 局，抓上报
C 组：注入 + 只开 ESP，跑 3 局
D 组：注入 + ESP + 自瞄，跑 3 局
```

对比每组上报的**事件类型集合**与**数量**。判定标准：

- B 组与 A 组事件集合一致 → 注入本身不产生信号（这条最重要，说明 Tier 0/1 有效）
- C 组多出事件 → ESP 相关（渲染 hook / 内存读取被察觉）
- D 组再多出 → 行为面（视角写入）

任何一组出现"新的事件类型"，先回退到上一组，再逐项加回，定位到具体加固项。
**没有这个实验，就没有"更隐蔽"这个结论，只有"我觉得更隐蔽"。**
