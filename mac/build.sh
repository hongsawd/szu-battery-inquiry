#!/bin/bash
# 把 main.swift 编译成 深大电量.app（不需要 Xcode，只要 Command Line Tools）
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="深大电量"
BUNDLE="$APP_NAME.app"
BIN="SzuPower"

echo "==> 编译（Intel + Apple Silicon 通用，最低 macOS 11）"
swiftc -O -target arm64-apple-macos11.0 -o "$BIN.arm64" main.swift \
  -framework Cocoa -framework SwiftUI -framework Carbon
swiftc -O -target x86_64-apple-macos11.0 -o "$BIN.x86_64" main.swift \
  -framework Cocoa -framework SwiftUI -framework Carbon
lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
rm -f "$BIN.arm64" "$BIN.x86_64"
lipo -info "$BIN"

echo "==> 组装 .app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$BIN"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.hongsawd.szupower</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# 图标：有 icon.icns 就用，没有就用系统符号
if [ -f "../icon.icns" ]; then
  cp ../icon.icns "$BUNDLE/Contents/Resources/icon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string icon.icns" "$BUNDLE/Contents/Info.plist" >/dev/null
fi

echo "==> 自检"
./"$BUNDLE/Contents/MacOS/$BIN" --selftest

echo "==> 完成：$BUNDLE"
echo "双击打开，或：open \"$PWD/$BUNDLE\""
