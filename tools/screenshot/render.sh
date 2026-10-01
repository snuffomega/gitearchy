#!/usr/bin/env bash
# Renders the README screenshot from demo data, off-screen, in the active
# Omarchy theme: bash tools/screenshot/render.sh [section] [out.png]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/../.." && pwd)"
SHELL_DIR=/usr/share/omarchy/shell
SECTION="${1:-all}"
OUT="$(realpath -m "${2:-$APP/preview.png}")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A throwaway Quickshell config: Omarchy's modules for the qs.* imports, and
# the plugin itself as "app".
for d in Commons Ui services; do ln -s "$SHELL_DIR/$d" "$work/$d"; done
ln -s "$APP" "$work/app"
cp "$HERE/render.qml" "$work/shell.qml"
bash "$HERE/demo-overview.sh" > "$work/demo.json"

# A desktop-sized virtual screen at 2x, so the panel isn't clamped to the
# offscreen platform's tiny default screen and the image renders sharp.
printf '%s\n' '{ "screens": [ { "name": "screenshot", "x": 0, "y": 0, "width": 2560, "height": 1440,' \
  '"logicalDpi": 96, "logicalBaseDpi": 96, "dpr": 2 } ] }' > "$work/screen.json"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
GITEARCHY_DEMO="$work/demo.json" GITEARCHY_OUT="$OUT" GITEARCHY_SECTION="$SECTION" \
  QT_QPA_PLATFORM="offscreen:configfile=$work/screen.json" \
  timeout 60 qs -p "$work/shell.qml" >"$work/qs.log" 2>&1 || true

if [ ! -s "$OUT" ]; then
  echo "render failed: no image written; last Quickshell output:" >&2
  tail -n 20 "$work/qs.log" >&2
  exit 1
fi
echo "$OUT"
