#!/usr/bin/env bash
# Assemble the distributable packages.
#
# The .app bundle is built from scratch here on purpose:
#   theos writes the final bundle (with Info.plist) under .theos/_/Applications/,
#   while the obj dir only holds the linked executable. Copying obj produces an
#   app without Info.plist, which TrollStore rejects with "error 302".
#
# Two ipa variants are emitted for bisecting launch failures:
#   ARHost-A-ents.ipa     app signed WITH host/entitlements.plist
#   ARHost-B-vanilla.ipa  app signed with NO entitlements at all
# If B launches and A does not, the entitlements (not the code) are at fault.
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

[ -n "$host_bin" ] || { echo "ERROR: ARHost binary not found"; exit 1; }
[ -n "$dmn" ] || { echo "ERROR: ARDaemon not found"; exit 1; }
[ -n "$pay" ] || { echo "ERROR: payload dylib not found"; exit 1; }
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

[ -f "$OUT/Info.plist" ] || { echo "ERROR: Info.plist missing"; exit 1; }
plutil -lint "$OUT/Info.plist"
exec_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$OUT/Info.plist")
[ "$exec_name" = "ARHost" ] || { echo "ERROR: CFBundleExecutable=$exec_name"; exit 1; }

echo
echo "=== sign helper binaries ==="
ldid -Sdaemon/entitlements.plist "$OUT/ARDaemon"
ldid -S "$OUT/ARPayload.dylib"

pack_ipa() {   # pack_ipa <dest>
    rm -rf build/ipa && mkdir -p build/ipa/Payload
    cp -a "$OUT" build/ipa/Payload/
    (cd build/ipa && ditto -c -k --sequesterRsrc --keepParent Payload "../$1" >/dev/null 2>&1 || (zip -qry "../$1" Payload))
}

echo
echo "=== variant A: app WITH entitlements ==="
ldid -Shost/entitlements.plist "$OUT/ARHost"
ldid -e "$OUT/ARHost" | grep -E '<key>' | sed 's/^[[:space:]]*//' | sed 's#</\?key>##g' || true
pack_ipa "ARHost-A-ents.ipa"
cp -a "$OUT" build/ARHost.app.A

echo
echo "=== variant B: app WITHOUT any entitlements ==="
ldid -S "$OUT/ARHost"
ldid -e "$OUT/ARHost" || true
pack_ipa "ARHost-B-vanilla.ipa"

echo
echo "=== restore bundle to variant A for the zip ==="
rm -rf "$OUT"
cp -a build/ARHost.app.A "$OUT"
rm -rf build/ARHost.app.A
(cd build && zip -qry ARHost-app.zip ARHost.app)

echo
echo "================ verify ================"
ls -la "$OUT"
echo "--- arch (expect ARM64 / 0x0100000c) ---"
for f in ARHost ARDaemon ARPayload.dylib; do
  printf '%-18s ' "$f"
  otool -hv "$OUT/$f" | awk 'NR==4{print $3, $4, $5}'
done
echo "--- A ipa contents ---"
unzip -l build/ARHost-A-ents.ipa
echo "--- B ipa contents ---"
unzip -l build/ARHost-B-vanilla.ipa

echo
echo "================ artifacts ================"
ls -lh build/*.ipa build/*.zip
shasum -a 256 build/ARHost-A-ents.ipa build/ARHost-B-vanilla.ipa
