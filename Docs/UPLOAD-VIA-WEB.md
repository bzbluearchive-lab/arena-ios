# 网页上传仓库并出包（零安装、零权限）

不需要 git，不需要装编译器，不需要管理员。全程在浏览器里。

---

## 第 1 步：建仓库

1. 打开 https://github.com/new
2. `Repository name` 填 `arena-ios`
3. 选 **Private**（私有）
4. **不要**勾 `Add a README file`（我们有现成的）
5. 点 `Create repository`

---

## 第 2 步：上传工程

在新仓库页面点 **`uploading an existing file`**（或 `Add file → Upload files`）。

把本地的 `arena-ios` 文件夹**里面的内容**拖进去（注意：拖内容，不要拖外层文件夹本身，
否则仓库里会多一层目录）。

需要包含这些：

```
.github/workflows/build.yml
Makefile
Makefile.legacy-tweak
Tweak.x
control
host/  daemon/  payload/  src/  tools/  Docs/
README.md  .gitignore
```

底部点 **`Commit changes`**。

> **`.github` 是隐藏目录，Windows 拖拽经常会漏掉它。**
> 提交后如果 `Actions` 页面没有任何工作流，就做第 2b 步。

### 第 2b 步：手工建工作流（只在漏传时做）

1. 仓库页 → `Actions` → 中间有 `set up a workflow yourself`
   （看不到就点 `New workflow` → `set up a workflow yourself`）
2. 把文件名改成 `build.yml`（注意要在 `.github/workflows/` 下，网页版默认就在）
3. 把本地 `arena-ios/.github/workflows/build.yml` 的内容整个粘进去
4. `Commit changes`

---

## 第 3 步：等它构建

仓库页 → **`Actions`** 标签 → 左侧 `build` → 最新一条。

首次约 3–5 分钟：

```
✓ Set up job
✓ 安装 theos 与 iOS SDK
✓ 静态自检
✓ 构建
✓ 校验产物
✓ 上传
```

点开可以看到每一步的完整日志。**如果 `静态自检` 就红了**，说明上传时漏了文件，
日志里会写明缺哪个。

---

## 第 4 步：下载产物

在同一次运行的页面**底部**（或右上角 `Artifacts` 区域）→ 点 **`ARHost-release`** 下载。

解压得到：

```
ARHost.ipa          ← 装到 iPad 用这个
ARHost-app.zip      ← TrollFools 用这个
```

---

## 第 5 步：装到 iPad

1. 把 `ARHost.ipa` 弄到 iPad 上（iCloud Drive / 数据线 / 局域网共享都行）
2. 打开 **TrollStore** → 底部 **`Apps`** → 右上角 **`+`**
3. 文件选择器里找到 `ARHost.ipa` → 点它
4. 等几秒，列表里出现 **AR Host**

---

## 第 6 步：五步验收

打开 **AR Host** → 点「**启动 daemon**」。

| | 看什么 | 通过标准 |
|---|---|---|
| ① | 日志框 | 每秒一行 `tick`，且 `ppid=1` |
| ② | 划掉 AR Host 再重开 | `tick` 编号继续往上加 |
| ③ | Filza 进程列表 | `ARDaemon`，PPID=1 |
| ④ | 日志 | `task_for_pid(SpringBoard) -> 0 OK` |
| ⑤ | 屏幕 | 中央绿框；划出控制中心/通知中心/多任务，绿框都压最上且位置不变 |

**任何一步失败就停在那一步**，把日志或截图给我。

---

## 常见问题

| 现象 | 原因 | 修法 |
|---|---|---|
| Actions 页面没有任何工作流 | `.github` 没上传成功 | 做第 2b 步 |
| `静态自检` 步骤失败 | 漏传文件 | 看日志里 `[FAIL] 存在 xxx` 那行，补传 |
| `构建` 报 `ldid: command not found` | brew 路径 | 工作流里已加 `/opt/homebrew/bin`；若仍报错把日志给我 |
| `构建` 报 `no SDK found` | SDK 没拉下来 | 工作流重跑一次（`Re-run all jobs`） |
| 上传产物步骤失败 | 产物路径不匹配 | 把 `构建` 步骤最后 30 行日志给我 |
| TrollStore 装不上 ipa | ipa 结构不对 | 本地产物里应有 `Payload/ARHost.app/`，日志能确认 |
| 点「启动 daemon」报 `spawn 失败 errno=85` | ARDaemon 没签上 | 把 `校验产物` 那步日志给我 |
| `task_for_pid -> 5` | TrollStore 洗掉了私有 entitlement | 改用 TrollFools 装 `ARHost-app.zip` 里的 app |

---

## 之后改代码怎么重出包

网页版可以直接改文件：仓库页 → 点文件 → 右上角铅笔 → 改完 `Commit changes` →
Actions 自动重跑 → 重新下载产物。

不需要重新上传整个目录。
