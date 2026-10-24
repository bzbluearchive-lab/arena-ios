#!/usr/bin/env python3
"""工程静态自检：在编译之前把能查的错误全查掉。

在 Windows 上就能跑（不需要 iOS 工具链）。检查项：
  1. 三层目录结构是否齐全
  2. 每个 Makefile 是否 ARCHS = arm64（payload/daemon 绝不要 arm64e）
  3. Makefile 引用的源文件是否都存在
  4. 三个 entitlements.plist 是否可解析、关键 key 是否都在
  5. Info.plist 的 CFBundleExecutable 是否与实际一致
  6. 跨文件 include 的路径是否可达
"""

import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ok, warn, bad = [], [], []


def chk(cond, msg, hard=True):
    (ok if cond else (bad if hard else warn)).append(msg)
    return cond


# ---------- 1. 结构 ----------
need = [
    "Makefile",
    "host/Makefile", "host/main.mm", "host/Info.plist", "host/entitlements.plist",
    "daemon/Makefile", "daemon/main.mm", "daemon/entitlements.plist",
    "payload/Makefile", "payload/SBWindow.mm",
    "src/Inject/SBWindow.mm", "src/Inject/RemoteLoad.h",
    "src/Host/DaemonSpawn.h",
    "tools/package.sh",
]
for p in need:
    chk(os.path.exists(os.path.join(ROOT, p)), f"存在 {p}")

# ---------- 2. ARCHS ----------
for mk in ["host/Makefile", "daemon/Makefile", "payload/Makefile"]:
    fp = os.path.join(ROOT, mk)
    if not os.path.exists(fp):
        continue
    txt = open(fp, encoding="utf-8").read()
    m = re.search(r"^ARCHS\s*=\s*(.+)$", txt, re.M)
    if not chk(m, f"{mk} 有 ARCHS", hard=True):
        continue
    archs = m.group(1).split()
    if mk.startswith(("daemon", "payload")):
        chk("arm64e" not in archs, f"{mk} ARCHS={archs}（不应含 arm64e）", hard=True)
        chk("arm64" in archs, f"{mk} 含 arm64", hard=True)
    else:
        chk("arm64" in archs, f"{mk} ARCHS={archs} 含 arm64", hard=True)

# ---------- 3. Makefile 引用的源文件 ----------
for mk in ["host/Makefile", "daemon/Makefile", "payload/Makefile"]:
    fp = os.path.join(ROOT, mk)
    if not os.path.exists(fp):
        continue
    txt = open(fp, encoding="utf-8").read()
    name = re.search(r"^(?:APPLICATION|TOOL|LIBRARY|TWEAK)_NAME\s*=\s*(\S+)", txt, re.M)
    if not name:
        continue
    var = name.group(1)
    files = re.search(rf"^{var}_FILES\s*=\s*(.+?)(?=^\S|\Z)", txt, re.M | re.S)
    if not files:
        continue
    base = os.path.dirname(fp)
    for f in files.group(1).split():
        if f.startswith("-"):
            continue
        chk(os.path.exists(os.path.join(base, f)), f"{mk}: 源文件 {f} 存在")

# ---------- 4. entitlements ----------
# 两个二进制要求不同：
#   host 是带界面的 UIKit app —— 必须有容器，所以不能带 no-container，
#   也不需要 task port / 调试器权限（那些只给 daemon）。
REQUIRED_ENT = [
    "platform-application",
    "com.apple.private.security.no-sandbox",
]
DAEMON_ENT = [
    "com.apple.private.cs.debugger",
    "task_for_pid-allow",
    "com.apple.system-task-ports",
]
for who in ["host", "daemon"]:
    fp = os.path.join(ROOT, who, "entitlements.plist")
    if not os.path.exists(fp):
        continue
    try:
        with open(fp, "rb") as fh:
            d = plistlib.load(fh)
    except Exception as e:
        bad.append(f"{who}/entitlements.plist 解析失败: {e}")
        continue
    for k in REQUIRED_ENT:
        chk(k in d, f"{who}/entitlements 含 {k}")
    if who == "daemon":
        for k in DAEMON_ENT:
            chk(k in d, f"daemon/entitlements 含 {k}（注入 SpringBoard 用）")
    else:
        chk("com.apple.private.security.no-container" not in d,
            "host/entitlements 不含 no-container（UIKit 应用拿不到容器会闪退）")

# ---------- 5. Info.plist ----------
fp = os.path.join(ROOT, "host", "Info.plist")
if os.path.exists(fp):
    try:
        with open(fp, "rb") as fh:
            d = plistlib.load(fh)
        exe = d.get("CFBundleExecutable")
        chk(exe == "ARHost", f"Info.plist CFBundleExecutable={exe}（应为 ARHost）")
        chk("CFBundleIdentifier" in d, "Info.plist 有 CFBundleIdentifier")
    except Exception as e:
        bad.append(f"Info.plist 解析失败: {e}")

# ---------- 6. include 可达 ----------
def find_headers(base, txt):
    res = []
    for m in re.finditer(r'#\s*include\s+"([^"]+)"', txt):
        res.append((base, m.group(1)))
    return res


for rel in ["src/Inject/SBWindow.mm", "src/Inject/RemoteLoad.h",
            "src/Host/DaemonSpawn.h", "daemon/main.mm", "host/main.mm"]:
    fp = os.path.join(ROOT, rel)
    if not os.path.exists(fp):
        continue
    for base, inc in find_headers(os.path.dirname(fp), open(fp, encoding="utf-8").read()):
        cand = os.path.normpath(os.path.join(base, inc))
        if inc in ("DaemonSpawn.h",) or inc.startswith(("UIKit", "Foundation",
                                                      "QuartzCore", "os/", "mach",
                                                      "sys/", "spawn.h", "unistd.h",
                                                      "fcntl.h", "errno.h", "signal.h",
                                                      "string.h", "stdio.h", "stdlib.h",
                                                      "time.h", "dlfcn.h")):
            continue
        chk(os.path.exists(cand), f"{rel}: include \"{inc}\" 可达")

# ---------- 输出 ----------
print("=" * 66)
print(f"通过 {len(ok)}  警告 {len(warn)}  失败 {len(bad)}")
print("=" * 66)
for m in ok:
    print("  [OK]  ", m)
for m in warn:
    print("  [WARN]", m)
for m in bad:
    print("  [FAIL]", m)

print()
print("=" * 66)
print("下一步（在有 iOS 工具链的机器上）")
print("=" * 66)
print("""
  macOS:
    export THEOS=~/theos
    make package

  Windows + WSL2:
    wsl -d <distro> bash -lc "cd <此目录的 /mnt/c/... 路径> && make package"

  然后：
    build/ARHost.zip  →  TrollStore 安装，或解包后用 TrollFools 装 .app
""")
print("=" * 66)
print("装到设备后的五步验收（任一步失败就停在那一步）")
print("=" * 66)
print("""
  1. 打开 ARHost → 点"启动 daemon" → 日志出现 tick
  2. 从多任务划掉 ARHost → 重新打开 → 日志仍在涨     (证明 daemonize 成功)
  3. ps 里 daemon 的 PPID 变成 1                     (说明被 launchd 收养)
  4. daemon 日志里 task_for_pid -> 0                  (entitlement 生效)
  5. 屏幕中央出现示例方框，切到通知中心仍在最上层     (注入链 + 层级正确)
""")
sys.exit(1 if bad else 0)
