#!/bin/bash
# 맥 빌드 — .app 번들 생성
#
# UI(index.html · style.css · renderer.js)는 src/ 를 그대로 복사한다.
# 맥 전용 사본을 만들지 않는다 — 원본이 하나여야 Windows 와 화면이 어긋나지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
NAME="Claude Usage Widget by R"
APP="$ROOT/mac/dist/$NAME.app"
VERSION=$(node -p "require('./package.json').version")
ARCH="${ARCH:-arm64}"          # ARCH=universal 로 인텔 겸용 빌드

echo "▸ 버전 $VERSION / 아키텍처 $ARCH"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ui"

echo "▸ Swift 컴파일"
SWIFT_ARCH=()
if [ "$ARCH" = "universal" ]; then
  SWIFT_ARCH=(-target arm64-apple-macos13.0)
  swiftc -O -whole-module-optimization -target arm64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/.bin-arm64" mac/Sources/*.swift
  swiftc -O -whole-module-optimization -target x86_64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/.bin-x64" mac/Sources/*.swift
  lipo -create -output "$APP/Contents/MacOS/ClaudeUsageWidget" \
    "$APP/Contents/MacOS/.bin-arm64" "$APP/Contents/MacOS/.bin-x64"
  rm -f "$APP/Contents/MacOS/.bin-arm64" "$APP/Contents/MacOS/.bin-x64"
else
  swiftc -O -whole-module-optimization -target arm64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/ClaudeUsageWidget" mac/Sources/*.swift
fi

echo "▸ 리소스 복사 (src/ 원본 공유)"
cp src/index.html src/style.css src/renderer.js "$APP/Contents/Resources/ui/"
cp mac/bridge.js "$APP/Contents/Resources/"
[ -f mac/icon.icns ] && cp mac/icon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ClaudeUsageWidget</string>
  <key>CFBundleIdentifier</key><string>com.roy.claude-usage-widget</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

echo "▸ 애드혹 서명"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "▸ 완료: $APP"
du -sh "$APP"
