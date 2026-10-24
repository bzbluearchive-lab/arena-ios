#!/usr/bin/env bash
# check-toolchain.sh —— 交叉编译链冒烟测试
# 在容器里先跑这个，比直接 make 更容易定位问题：
#   工具在不在 → SDK 在不在 → 编译通不通 → 链接通不通 → 签名通不通

set -uo pipefail
THEOS="${THEOS:-/opt/theos}"
FAIL=0

ok()  { printf '  \033[1;32m[OK]\033[0m %s\n' "$*"; }
ng()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=1; }
warn(){ printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }

printf '\033[1;36m== 1. 工具 ==\033[0m\n'
for t in clang make python3 ld64 ldid; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t -> $(command -v "$t")"; else ng "$t 缺失"; fi
done
command -v ld64      >/dev/null 2>&1 && LINKER=ld64
command -v ld64.lld  >/dev/null 2>&1 && LINKER=${LINKER:-ld64.lld}
[ -n "${LINKER:-}" ] && ok "链接器用 $LINKER" || ng "没有任何 Mach-O 链接器"

printf '\033[1;36m== 2. theos / SDK ==\033[0m\n'
[ -d "$THEOS/makefiles" ] && ok "theos -> $THEOS" || ng "theos 缺失"
SDK=$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk 2>/dev/null | tail -1 || true)
if [ -n "$SDK" ]; then
  ok "SDK -> $SDK"
  [ -f "$SDK/usr/include/objc/runtime.h" ] && ok "含 objc 头" || warn "缺 objc/runtime.h（部分系统版本正常）"
else
  ng "SDK 缺失（$THEOS/sdks 为空）"
fi

printf '\033[1;36m== 3. 冒烟：编译 -> 链接 -> 签名 ==\033[0m\n'
tmp=$(mktemp -d)
printf '#import <objc/runtime.h>\nint probe(void){return 42;}\n' > "$tmp/p.m"

if [ -n "${SDK:-}" ]; then
  if clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc \
        -c "$tmp/p.m" -o "$tmp/p.o" 2>"$tmp/e1"; then
    ok "clang 编译 arm64 + objc 头"
  else
    ng "clang 编译失败："
    sed 's/^/       /' "$tmp/e1" | head -5
  fi
fi

if [ -f "$tmp/p.o" ] && [ -n "${LINKER:-}" ] && [ -n "${SDK:-}" ]; then
  if "$LINKER" -arch arm64 -dylib -platform_version ios 15.0 15.0 \
        -syslibroot "$SDK" -o "$tmp/p.dylib" "$tmp/p.o" 2>"$tmp/e2"; then
    ok "链接出 dylib（$LINKER）"
  else
    ng "链接失败（$LINKER）："
    sed 's/^/       /' "$tmp/e2" | head -8
    [ "$LINKER" = "ld64.lld" ] && echo "       提示：apt install -y ld64 装真 ld64 通常能解"
  fi
fi

if [ -f "$tmp/p.dylib" ] && command -v ldid >/dev/null 2>&1; then
  if ldid -S "$tmp/p.dylib" 2>"$tmp/e3"; then
    ok "ldid 签名通过"
  else
    ng "ldid 签名失败："
    sed 's/^/       /' "$tmp/e3" | head -5
  fi
fi

if [ -f "$tmp/p.dylib" ] && command -v file >/dev/null 2>&1; then
  printf '       产物类型：%s\n' "$(file -b "$tmp/p.dylib")"
fi

rm -rf "$tmp"
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m工具链自检通过，可以 make package\033[0m\n'
else
  printf '\033[1;31m工具链自检未通过，按上面 FAIL 行的提示修\033[0m\n'
fi
exit "$FAIL"
