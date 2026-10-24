#!/usr/bin/env bash
# Assemble diagnostic ipa variants for bisecting an "installs but crashes on launch" app.
#
#   ARHost-M-min.ipa    minimal bundle: ONLY the main binary + Info.plist (vanilla sign)
#   ARHost-B-full.ipa   full bundle: + ARDaemon + ARPayload.dylib (vanilla sign)
#   ARHost-T-theos.ipa  theos's own staged bundle, untouched (if present)
#
# Each variant gets a unique CFBundleIdentifier / display name so they can coexist
# on the device and be tested one after another.
set -euo pipefail
cd "$(dirname "$0")/.."

PB=/usr/libexec/PlistBuddy
command -v ldid >/dev/null || { echo "ERROR: ldid not found"; exit 1; }

host_bin=$(find host/.theos/obj    -maxdepth 4 -name 'ARHost'  -type f 2>/dev/null | head -1 || true)
dmn=$(find      daemon/.theos/obj  -maxdepth 4 -name 'ARDaemon' -type f 2>/dev/null | head -1 || true)
pay=$(find      payload/.theos/obj -maxdepth 4 -name '*ARPayload*.dylib' -type f 2>/dev/null | head -1 || true)
staged=$(find host/.theos/_ -maxdepth 4 -name 'ARHost.app' -type d 2>/dev/null | head -1 || true)

echo "host   = ${host_bin:-<missing>}"
echo "daemon = ${dmn:-<missing>}"
echo "payload= ${pay:-<missing>}"
echo "staged = ${staged:-<none>}"
[ -n "$host_bin" ] || { echo "ERROR: ARHost binary not found"; exit 1; }

rm -rf build
mkdir -p build

# mk_app <dir> <bundle-id> <display-name>   -> copies binary + plist, patches id/name
mk_app() {
    local dir="$1" bid="$2" disp="$3"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$host_bin" "$dir/ARHost"
    cp host/Info.plist "$dir/Info.plist"
    chmod +x "$dir/ARHost"
    $PB -c "Set :CFBundleIdentifier $bid"     "$dir/Info.plist"
    $PB -c "Set :CFBundleDisplayName $disp"   "$dir/Info.plist"
    $PB -c "Set :CFBundleName $disp"          "$dir/Info.plist"
}

# pack <app-dir> <ipa-name>
pack() {
    local dir="$1" dest="$2"
    rm -rf build/_ipa && mkdir -p build/_ipa/Payload
    cp -a "$dir" build/_ipa/Payload/
    ( cd build/_ipa && zip -qry "../$dest" Payload )
    echo "packed $dest"
}

echo
echo "=== M: minimal (binary + Info.plist only, vanilla sign) ==="
mk_app build/ARMin.app com.local.armin "AR M"
ldid -S build/ARMin.app/ARHost
pack build/ARMin.app ARHost-M-min.ipa

if [ -n "$dmn" ] && [ -n "$pay" ]; then
    echo
    echo "=== B: full bundle (vanilla sign) ==="
    mk_app build/ARFull.app com.local.arb "AR B"
    cp "$dmn" build/ARFull.app/ARDaemon
    cp "$pay" build/ARFull.app/ARPayload.dylib
    chmod +x build/ARFull.app/ARDaemon
    ldid -S build/ARFull.app/ARHost
    ldid -S build/ARFull.app/ARDaemon
    ldid -S build/ARFull.app/ARPayload.dylib
    pack build/ARFull.app ARHost-B-full.ipa
fi

if [ -n "$staged" ]; then
    echo
    echo "=== T: theos staged bundle, untouched ==="
    rm -rf build/ARTheos.app
    cp -a "$staged" build/ARTheos.app
    $PB -c "Set :CFBundleIdentifier com.local.art"  build/ARTheos.app/Info.plist
    $PB -c "Set :CFBundleDisplayName AR T"          build/ARTheos.app/Info.plist
    ldid -S build/ARTheos.app/ARHost || true
    ls -la build/ARTheos.app
    pack build/ARTheos.app ARHost-T-theos.ipa
fi

echo
echo "================ verify ================"
for ipa in build/*.ipa; do
    echo "--- $ipa ---"
    unzip -l "$ipa" | sed -n '4,20p'
done
echo
ls -lh build/*.ipa
shasum -a 256 build/*.ipa
