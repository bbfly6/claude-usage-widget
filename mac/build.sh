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
# VER=1.7.1 로 덮어쓸 수 있다 — 업데이트 경로를 시험할 때 package.json 을 건드리지 않기 위해서다
VERSION="${VER:-$(node -p "require('./package.json').version")}"
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
# 아이콘이 없으면 만든다 (mac/make-icon.py). 없어도 빌드는 진행한다.
[ -f mac/icon.icns ] || python3 mac/make-icon.py >/dev/null 2>&1 || true
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

# 배포용 zip. 업데이터가 찾는 이름 규칙: mac 을 포함하고 .zip 으로 끝난다.
# ditto 를 쓴다 — zip 명령은 맥 번들의 심볼릭 링크·확장속성을 망가뜨린다.
ZIP="$ROOT/mac/dist/Claude-Usage-Widget-mac-$VERSION.zip"
# 버전 없는 사본도 만든다. 설치 페이지가 releases/latest/download/ 로 거는 고정 링크용이라
# 버전이 올라가도 링크가 안 깨진다 (Windows 의 Claude-Usage-Widget-Setup.exe 와 같은 역할).
ALIAS="$ROOT/mac/dist/Claude-Usage-Widget-mac.zip"
rm -f "$ZIP" "$ZIP.sha256" "$ALIAS" "$ALIAS.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
cp "$ZIP" "$ALIAS"
cp "$ZIP.sha256" "$ALIAS.sha256"

echo "▸ 완료: $APP"
du -sh "$APP"
echo "▸ 배포용: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  릴리스에 zip 과 .sha256 을 둘 다 올린다."
echo "  체크섬 자산이 있으면 반드시 통과해야 설치한다 - 없으면 검증 없이 진행한다."
