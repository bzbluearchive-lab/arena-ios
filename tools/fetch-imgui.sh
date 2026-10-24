#!/usr/bin/env bash
# fetch-imgui.sh - pull a pinned Dear ImGui into vendor/imgui
#
# CI does this itself; this copy is for local builds on macOS / WSL2 / Linux.
# Pinned tag so an upstream change cannot break the build overnight.

set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${IMGUI_TAG:-v1.90.9}"
DEST="vendor/imgui"

if [ -f "$DEST/imgui.h" ] && [ -f "$DEST/backends/imgui_impl_metal.mm" ]; then
  echo "[i] $DEST already present ($TAG expected) - skipping"
  exit 0
fi

rm -rf "$DEST"
mkdir -p vendor
git clone --depth=1 --branch "$TAG" https://github.com/ocornut/imgui.git "$DEST"

for f in imgui.h imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp \
         backends/imgui_impl_metal.h backends/imgui_impl_metal.mm; do
  test -f "$DEST/$f" || { echo "[x] missing after clone: $f"; exit 1; }
done

echo "[i] imgui ready: $DEST ($TAG)"
