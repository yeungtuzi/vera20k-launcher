#!/usr/bin/env bash
# Build and install the VERA2K Launcher app.
#
# The launcher is a browser only: scanning, mission text, preview rendering and
# the spawn.ini launch all run through `map-tool`, which lives in the vera20k
# checkout. Point it at that checkout with VERA20K_ROOT (default: ../vera20k).
#
#   VERA20K_ROOT=/path/to/vera20k bash build.sh [install-dir]
#
# Default install dir is /Applications.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-/Applications}"
root="${VERA20K_ROOT:-$(cd "$here/../vera20k" 2>/dev/null && pwd || true)}"

if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "vera20k checkout not found; set VERA20K_ROOT=/path/to/vera20k" >&2
  exit 1
fi
tool="$root/target/release/map-tool"
if [ ! -x "$tool" ]; then
  echo "map-tool is missing; build it in the vera20k checkout:" >&2
  echo "  (cd $root && cargo build --release --locked -p vera20k --bin map-tool)" >&2
  exit 1
fi

app="$out/VERA2K Launcher.app"
build="$here/build"
mkdir -p "$build"

swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  "$here/MapLauncher.swift" \
  -o "$build/VERA2KLauncher"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/VERA2KLauncher" "$app/Contents/MacOS/VERA2KLauncher"

if [ -f "$root/.github/release/icon.png" ]; then
  icon="$build/icon.png"
  python3 "$here/make_icon.py" "$root/.github/release/icon.png" "$icon"
  iconset="$build/VERA2KLauncher.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$icon" \
      --out "$iconset/icon_${size}x${size}.png" > /dev/null
    sips -s format png -z $((size * 2)) $((size * 2)) "$icon" \
      --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
  done
  iconutil -c icns -o "$app/Contents/Resources/icon.icns" "$iconset"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VERA2K Launcher</string>
  <key>CFBundleDisplayName</key><string>VERA2K Launcher</string>
  <key>CFBundleIdentifier</key><string>io.github.vera2k.launcher</string>
  <key>CFBundleExecutable</key><string>VERA2KLauncher</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Record the resolved tool path so the first launch works without env vars.
defaults write io.github.vera2k.launcher toolPath "$tool" 2>/dev/null || true

xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
codesign --force --deep --sign - "$app" 2>/dev/null
codesign --verify --strict "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$app" 2>/dev/null || true
echo "built $app"
