#!/bin/zsh
# Builds Veil.app into ./build. Usage: scripts/build.sh [--run]
set -euo pipefail
cd "${0:A:h}/.."

# With only the Command Line Tools installed, the macOS 27 SDK lacks SwiftUI's macro plugin;
# fall back to the newest 26.x SDK that ships with the tools (the app still runs on 27).
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" != *Xcode*.app* ]]; then
  CLT_SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [[ -n "$CLT_SDK" ]] && export SDKROOT="$CLT_SDK"
fi

echo "▸ Compiling (SDK: ${SDKROOT:-default})"
swift build -c release --arch arm64

APP=build/Veil.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN=$(swift build -c release --arch arm64 --show-bin-path)
cp "$BIN/Veil" "$APP/Contents/MacOS/Veil"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ Rendering icon"
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a real development identity so the microphone permission survives rebuilds.
IDENTITY=${VEIL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
IDENTITY=${IDENTITY:--}
echo "▸ Signing with: $IDENTITY"
codesign --force --options runtime --entitlements Resources/Veil.entitlements --sign "$IDENTITY" "$APP"

echo "✓ $APP"
if [[ "${1:-}" == "--run" ]]; then
  pkill -x Veil 2>/dev/null || true
  open "$APP"
fi
