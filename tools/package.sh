#!/usr/bin/env bash
# 组装可分发包：ARHost.app（含 ARDaemon 与 ARPayload.dylib）+ ldid 签名 + ipa + zip
set -euo pipefail
cd "$(dirname "$0")/.."

SLICE=arm64
OUT=build/ARHost.app

app=$(ls -d host/.theos/obj/${SLICE}/ARHost.app 2>/dev/null | head -1 || true)
dmn=$(ls -1 daemon/.theos/obj/${SLICE}/ARDaemon  2>/dev/null | head -1 || true)
pay=$(ls -1 payload/.theos/obj/${SLICE}/ARPayload.dylib 2>/dev/null | head -1 || true)

[ -n "$app" ] || { echo "缺少 ARHost.app，先 make host";        exit 1; }
[ -n "$dmn" ] || { echo "缺少 ARDaemon，先 make daemon";        exit 1; }
[ -n "$pay" ] || { echo "缺少 ARPayload.dylib，先 make payload"; exit 1; }

command -v ldid >/dev/null || { echo "缺少 ldid（brew install ldid）"; exit 1; }

rm -rf build
mkdir -p build
cp -a "$app" "$OUT"
cp "$dmn" "$OUT/ARDaemon"
cp "$pay" "$OUT/ARPayload.dylib"
chmod +x "$OUT/ARHost" "$OUT/ARDaemon"

echo "[1/4] 签名 ARHost（带 host entitlements）"
ldid -Shost/entitlements.plist "$OUT/ARHost"

echo "[2/4] 签名 ARDaemon（带 daemon entitlements）"
ldid -Sdaemon/entitlements.plist "$OUT/ARDaemon"

echo "[3/4] 签名 ARPayload.dylib（不挂 entitlements）"
ldid -S "$OUT/ARPayload.dylib"

echo "[4/4] 打 ipa 与 zip"
# TrollStore 的 + 只吃 .ipa（结构必须是 Payload/ARHost.app），所以单独做一个
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -a "$OUT" build/ipa/Payload/
(cd build/ipa && zip -qry ../ARHost.ipa Payload)
# 裸 app 包，给 TrollFools / 手动安装用
(cd build && zip -qry ARHost-app.zip ARHost.app)

echo
echo "================ 校验 ================"
for f in ARHost ARDaemon; do
  echo "--- $f entitlements ---"
  ldid -e "$OUT/$f" | grep -E '<key>' | sed 's/^[[:space:]]*//' | sed 's#</\?key>##g'
done
echo "--- 架构（应为 ARM64 / 0x0100000c） ---"
for f in ARHost ARDaemon ARPayload.dylib; do
  printf '%-18s ' "$f"
  if command -v otool >/dev/null; then
    otool -hv "$OUT/$f" | awk 'NR==4{print $3, $4, $5}'
  else
    echo "(无 otool)"
  fi
done

echo
echo "================ 产物 ================"
ls -lh build/ARHost.ipa build/ARHost-app.zip
echo
echo "装到 iPad：把 build/ARHost.ipa 传到设备 → TrollStore → Apps → 右上角 + → 选它"
shasum -a 256 build/ARHost.ipa
