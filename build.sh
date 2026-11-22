#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bridge_pkg="${BRIDGE_PACKAGE:-$HOME/.dsh/profiles/desktop/node_modules/@nszzj/dsh-hos-scrcpy}"
app="${BUILD_APP_PATH:-dist/HarmonyLink.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Bridge"
resource="$app/Contents/Resources"
if [[ ! -f "$resource/Bridge/hosScrcpy-1.0.18-beta.jar" || ! -f "$resource/Bridge/out/Main.class" ]]; then
  if [[ ! -f "$bridge_pkg/resources/hosScrcpy-1.0.18-beta.jar" ||
        ! -f "$bridge_pkg/resources/out/Main.class" ||
        ! -f "$bridge_pkg/LICENSE" || ! -f "$bridge_pkg/THIRD_PARTY_NOTICES.md" ]]; then
    echo "缺少投屏桥接组件。请按 README 获取上游 3.1.1 包，并将 BRIDGE_PACKAGE 指向解包后的 package 目录。" >&2
    exit 1
  fi
  cp "$bridge_pkg/resources/hosScrcpy-1.0.18-beta.jar" "$resource/Bridge/"
  ditto "$bridge_pkg/resources/out" "$resource/Bridge/out"
  cp "$bridge_pkg/LICENSE" "$resource/Bridge/LICENSE"
  cp "$bridge_pkg/THIRD_PARTY_NOTICES.md" "$resource/Bridge/THIRD_PARTY_NOTICES.md"
fi
cp Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$resource/AppIcon.icns"
cp LICENSE "$resource/HarmonyLink-License.txt"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -parse-as-library \
  -module-cache-path "${TMPDIR:-/tmp}/harmony-link-module-cache" \
  Sources/*.swift -o "$app/Contents/MacOS/HarmonyLink"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
