#!/usr/bin/env python3
"""
preflight_esp.py —— 只显示（骨骼/装备/物资）形态的静态自检。

Windows 上也能跑，不需要 clang / theos：
    python tools/preflight_esp.py

CI 里在编译前跑一遍，把"20 分钟编译 → 报错 → 改 → 再编译"的循环压成 2 秒。

检查项分三类：
  [必过] 编译一定会挂的（文件缺失、include 解析不了、符号缺定义）
  [不变量] 本工程承诺的硬约束（零写入、无明文指纹、inline hook 关闭）
  [提示] 环境相关的（imgui 有没有、sdk 有没有），本机缺不算失败
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAKEFILE = os.path.join(ROOT, "Makefile.legacy-tweak")

FAIL = []
WARN = []
OK = []


def ok(msg):
    OK.append(msg)


def fail(msg):
    FAIL.append(msg)


def warn(msg):
    WARN.append(msg)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


# ---------------------------------------------------------------- 1. FILES 列表
def parse_files():
    if not os.path.exists(MAKEFILE):
        fail("Makefile.legacy-tweak 不存在")
        return [], ""
    src = read(MAKEFILE)
    m = re.search(r"ARCheat_FILES\s*=\s*((?:.*\\\n)*.*)", src)
    if not m:
        fail("Makefile.legacy-tweak 里找不到 ARCheat_FILES")
        return [], src
    raw = m.group(1).replace("\\\n", " ")
    files = [t for t in raw.split() if t and not t.startswith("#")]
    return files, src


def check_files(files):
    if not files:
        return
    for f in files:
        p = os.path.join(ROOT, f)
        if not os.path.exists(p):
            fail("FILES 里的文件不存在: %s" % f)
    ok("FILES 列表 %d 个文件全部存在" % len(files))


# ---------------------------------------------------------------- 2. include 解析
INC_RE = re.compile(r'^\s*#\s*(?:include|import)\s+"([^"]+)"', re.M)

# 与 Makefile 里的 -I 保持一致（vendor 头文件靠这些目录解析）
INC_DIRS = ["", "src", "vendor", "vendor/imgui", "vendor/imgui/backends"]


def check_includes(files):
    missing = []
    vendor_missing = set()
    vendor_dir = os.path.join(ROOT, "vendor", "imgui")
    for f in files:
        p = os.path.join(ROOT, f)
        if not os.path.exists(p):
            continue
        base = os.path.dirname(p)
        for inc in INC_RE.findall(read(p)):
            dirs = [base] + [os.path.join(ROOT, d) if d else ROOT for d in INC_DIRS]
            if any(os.path.exists(os.path.normpath(os.path.join(d, inc))) for d in dirs):
                continue
            # 三方头文件来自 vendor/，由 CI 拉取；本地没拉不算失败
            if inc.startswith("imgui") and not os.path.isdir(vendor_dir):
                vendor_missing.add(inc)
                continue
            missing.append((f, inc))
    if vendor_missing:
        warn("vendor 头文件尚未拉取（CI 会自动拉）: " + ", ".join(sorted(vendor_missing)))
    if missing:
        for f, inc in missing:
            fail('include 解析不到: %s -> "%s"' % (f, inc))
    else:
        ok("所有项目内 include 都能解析")


# ---------------------------------------------------------------- 3. 不变量
def check_invariants(files, mk_src):
    # 3.1 零写入：目标文件里不允许出现 mem::wr( 调用
    write_sites = []
    for f in files:
        p = os.path.join(ROOT, f)
        if not os.path.exists(p):
            continue
        for i, line in enumerate(read(p).splitlines(), 1):
            if "mem::wr(" in line and not line.strip().startswith("//"):
                write_sites.append("%s:%d" % (f, i))
    if write_sites:
        fail("出现写游戏内存的调用点（只显示形态承诺零写入）: " + ", ".join(write_sites))
    else:
        ok("零写入不变量成立：没有任何 mem::wr() 调用点")

    # 3.2 Aim.mm 不能被链接进来（只看 FILES 解析结果，不看注释）
    if any(f.endswith("Aim.mm") for f in files):
        fail("Makefile 的 FILES 里包含 Aim.mm —— 会把写内存的代码编进二进制")
    else:
        ok("Aim.mm 未链接（写内存路径不存在于二进制中）")

    # 3.3 inline hook 必须编译期关闭
    if "AR_ALLOW_INLINE_HOOK=0" in mk_src:
        ok("AR_ALLOW_INLINE_HOOK=0：不提供匿名可执行内存分配路径")
    else:
        fail("Makefile 里缺少 -DAR_ALLOW_INLINE_HOOK=0")

    # 3.4 明文指纹：源码里不该有裸的 cheat 词（注释和 XOR 常量除外）
    banned = ["ARCheat", "aimbot", "Aimbot", "cheat", "Cheat", "wallhack", "ESP"]
    hits = []
    for f in files:
        p = os.path.join(ROOT, f)
        if not os.path.exists(p):
            continue
        for i, line in enumerate(read(p).splitlines(), 1):
            s = line.strip()
            if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
                continue
            for b in banned:
                # 允许出现在文件名/路径字符串里（Tweak.x 的日志路径），但 UI 文本不行
                if b in s and "archeat-" not in s and "ARCheat.dylib" not in s:
                    hits.append("%s:%d %s" % (f, i, b))
                    break
    if hits:
        warn("疑似明文指纹（人工确认，若是注释/路径可忽略）: " + "; ".join(hits[:8]))
    else:
        ok("源码文本里没有裸的 cheat 字样")

    # 3.5 编译开关：C++17 + ARC
    for need in ["-std=c++17", "-fobjc-arc"]:
        if need in mk_src:
            ok("编译开关 %s 存在" % need)
        else:
            fail("Makefile 缺少 %s" % need)

    # 3.6 符号剥离
    if "-Wl,-x" in mk_src and "-fvisibility=hidden" in mk_src:
        ok("符号剥离开关齐（-fvisibility=hidden + -Wl,-x）")
    else:
        warn("缺少符号剥离开关（-fvisibility=hidden / -Wl,-x）")


# ---------------------------------------------------------------- 4. 环境相关
IMGUI_NEEDED = [
    "imgui.h", "imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp",
    "backends/imgui_impl_metal.h", "backends/imgui_impl_metal.mm",
]


def check_env():
    vendor = os.path.join(ROOT, "vendor", "imgui")
    if not os.path.isdir(vendor):
        warn("vendor/imgui 不存在（CI 会自动拉；本机编译前先跑 tools/fetch-imgui.sh）")
    else:
        miss = [f for f in IMGUI_NEEDED if not os.path.exists(os.path.join(vendor, f))]
        if miss:
            warn("vendor/imgui 缺文件: " + ", ".join(miss))
        else:
            ok("vendor/imgui 齐全")

    if not os.environ.get("THEOS"):
        warn("THEOS 未设置（本机编译前 export THEOS=~/theos；CI 里由 workflow 设置）")
    else:
        ok("THEOS=%s" % os.environ["THEOS"])


# ---------------------------------------------------------------- main
def main():
    files, mk_src = parse_files()
    if not os.path.exists(MAKEFILE):
        pass
    else:
        check_files(files)
        check_includes(files)
        check_invariants(files, mk_src)
    check_env()

    for line in OK:
        print("  [ok]   %s" % line)
    for line in WARN:
        print("  [warn] %s" % line)
    for line in FAIL:
        print("  [FAIL] %s" % line)

    print("")
    print("preflight: %d ok / %d warn / %d fail" % (len(OK), len(WARN), len(FAIL)))
    if FAIL:
        print("=> 先修 FAIL 项，编译一定过不去")
        return 1
    print("=> 静态检查通过，可以进编译")
    return 0


if __name__ == "__main__":
    sys.exit(main())
