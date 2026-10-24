#!/usr/bin/env bash
# Assemble the distributable package: ARHost.app (+ ARDaemon + ARPayload.dylib),
# ldid-sign everything, emit .ipa and .zip.
#
# Discovery is find/glob-based on purpose: theos output paths and library file
# names differ between versions and targets (arm64 vs arm64e, "lib" prefix or
# not), so hard-coded paths are a common source of CI failure.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/ARHost.app

echo "=== locate build outputs ==="
app=$(find host/.theos/obj    -maxdepth 3 -name 'ARHost.app'         -type d 2>/dev/null | head -1 || true)
dmn=$(find daemon/.theos/obj  -maxdepth 3 -name 'ARDaemon'           -type f 2>/dev/null | head -1 || true)
pay=$(find payload/.theos/obj -maxdepth 3 -name '*ARPayload*.dylib'  -type f 2>/dev/null | head -1 || true)

echo "app     = ${app:-<missing>}"
echo "daemon  = ${dmn:-<missing>}"
echo "payload = ${pay:-<missing>}"

[ -n "$app" ] || { echo "ERROR: ARHost.app not found"; ls -R host/.theos/obj 2>/dev/null | head -40; exit 1; }
[ -n "$dmn" ] || { echo "ERROR: ARDaemon not found";   ls -R daemon/.theos/obj 2>/dev/null | head -40; exit 1; }
[ -n "$pay" ] || { echo "ERROR: payload dylib not found"; ls -R payload/.theos/obj 2>/dev/null | head -40; exit 1; }

command -v ldid >/dev/null || { echo "ERROR: ldid not found"; exit 1; }

rm -rf build
mkdir -p build
cp -a "$app" "$OUT"
cp "$dmn" "$OUT/ARDaemon"
cp "$pay" "$OUT/ARPayload.dylib"
chmod +x "$OUT/ARHost" "$OUT/ARDaemon"

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
for f in ARHost ARDaemon; do
  echo "--- $f entitlements ---"
  ldid -e "$OUT/$f" | grep -E '<key>' | sed 's/^[[:space:]]*//' | sed 's#</\?key>##g' || true
done
echo "--- arch (expect ARM64 / 0x0100000c) ---"
for f in ARHost ARDaemon ARPayload.dylib; do
  printf '%-18s ' "$f"
  if command -v otool >/dev/null; then
    otool -hv "$OUT/$f" | awk 'NR==4{print $3, $4, $5}'
  else
    echo "(no otool)"
  fi
done

echo
echo "================ artifacts ================"
ls -lh build/ARHost.ipa build/ARHost-app.zip
shasum -a 256 build/ARHost.ipa
