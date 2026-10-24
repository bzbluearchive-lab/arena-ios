#!/usr/bin/env bash
# Assemble the distributable package: ARHost.app (+ ARDaemon + ARPayload.dylib),
# ldid-sign everything, emit .ipa and .zip.
#
# The .app bundle is built from scratch here on purpose:
#   theos writes the final bundle (with Info.plist) under .theos/_/Applications/,
#   while .theos/<dir>/obj only holds the linked executable. Copying the obj
#   directory produces an app without Info.plist, which TrollStore rejects with
#   "error 302: Info.plist not found". So: take the binary, add the plist ourselves.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/ARHost.app

echo "=== locate build outputs ==="
host_bin=$(find host/.theos/obj    -maxdepth 4 -name 'ARHost' -type f 2>/dev/null | head -1 || true)
dmn=$(find daemon/.theos/obj  -maxdepth 4 -name 'ARDaemon' -type f 2>/dev/null | head -1 || true)
pay=$(find payload/.theos/obj -maxdepth 4 -name '*ARPayload*.dylib' -type f 2>/dev/null | head -1 || true)

echo "host    = ${host_bin:-<missing>}"
echo "daemon  = ${dmn:-<missing>}"
echo "payload = ${pay:-<missing>}"

[ -n "$host_bin" ] || { echo "ERROR: ARHost binary not found"; ls -R host/.theos/obj 2>/dev/null | head -40; exit 1; }
[ -n "$dmn" ] || { echo "ERROR: ARDaemon not found";  ls -R daemon/.theos/obj 2>/dev/null | head -40; exit 1; }
[ -n "$pay" ] || { echo "ERROR: payload dylib not found"; ls -R payload/.theos/obj 2>/dev/null | head -40; exit 1; }

command -v ldid >/dev/null || { echo "ERROR: ldid not found"; exit 1; }

echo
echo "=== assemble app bundle ==="
rm -rf build
mkdir -p "$OUT/PlugIns"
cp "$host_bin" "$OUT/ARHost"
cp host/Info.plist "$OUT/Info.plist"
cp "$dmn" "$OUT/ARDaemon"
cp "$pay" "$OUT/ARPayload.dylib"
chmod +x "$OUT/ARHost" "$OUT/ARDaemon"

# hard requirements for TrollStore
[ -f "$OUT/Info.plist" ] || { echo "ERROR: Info.plist missing from bundle"; exit 1; }
plutil -lint "$OUT/Info.plist"
exec_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$OUT/Info.plist")
[ "$exec_name" = "ARHost" ] || { echo "ERROR: CFBundleExecutable=$exec_name, expected ARHost"; exit 1; }
echo "bundle ok: CFBundleExecutable=$exec_name"

echo
echo "[1/4] sign ARHost"
ldid -Shost/entitlements.plist "$OUT/ARHost"

echo "[2/4] sign ARDaemon"
ldid -Sdaemon/entitlements.plist "$OUT/ARDaemon"

echo "[3/4] sign ARPayload.dylib"
ldid -S "$OUT/ARPayload.dylib"

echo "[4/4] pack ipa + zip"
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -a "$OUT" build/ipa/Payload/
(cd build/ipa && zip -qry ../ARHost.ipa Payload)
(cd build && zip -qry ARHost-app.zip ARHost.app)

echo
echo "================ verify ================"
echo "--- bundle contents ---"
ls -la "$OUT"
echo "--- ipa contents ---"
unzip -l build/ARHost.ipa | head -20
echo "--- arch (expect ARM64 / 0x0100000c) ---"
for f in ARHost ARDaemon ARPayload.dylib; do
  printf '%-18s ' "$f"
  otool -hv "$OUT/$f" | awk 'NR==4{print $3, $4, $5}'
done
echo "--- entitlements ---"
for f in ARHost ARDaemon; do
  echo "[$f]"
  ldid -e "$OUT/$f" | grep -E '<key>' | sed 's/^[[:space:]]*//' | sed 's#</\?key>##g' || true
done

echo
echo "================ artifacts ================"
ls -lh build/ARHost.ipa build/ARHost-app.zip
shasum -a 256 build/ARHost.ipa
