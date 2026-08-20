#!/bin/bash
# No-Xcode build for Andy题词 (v0.1.1 RC)
# - swiftc directly compiles all 25 Swift sources into a single binary
# - Hand-assembles Contents/Info.plist (merging GENERATE_INFOPLIST_FILE fields)
# - Skips Assets.car (actool unavailable without Xcode → app launches with system icon)
# - Ad-hoc codesign with empty entitlements so microphone/network actually work
# - Pass --universal to produce a fat arm64+x86_64 binary (default: arm64-only)
set -euo pipefail

# Parse args
UNIVERSAL=false
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --help|-h)
      echo "Usage: $0 [--universal]"
      echo "  (default)  Build arm64-only binary"
      echo "  --universal  Build arm64 + x86_64 universal binary"
      exit 0
      ;;
    *) echo "Unknown arg: $arg"; exit 2 ;;
  esac
done

# Run from repo root (parent of this script)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEXTREAM_DIR="$REPO_ROOT/Textream"
cd "$TEXTREAM_DIR"

APP_NAME="Andy题词"
BUNDLE_ID="dev.andy.tici"
VERSION="0.1.1"
BUILD_NUM="2"
DEPLOY_TARGET="15.0"
DEVELOPER_TEAM="RJA7656U34"

if $UNIVERSAL; then
  ARCHES=(arm64 x86_64)
  BUILD_DIR="$(pwd)/build_universal"
  echo "🎯 Target: universal (arm64 + x86_64)"
else
  ARCHES=(arm64)
  BUILD_DIR="$(pwd)/build"
  echo "🎯 Target: arm64-only"
fi
APP_DIR="$BUILD_DIR/release/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"

echo "🧹 Cleaning previous build…"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$BUILD_DIR"

# Helper: stub out #Preview blocks (SwiftUI 6.x freestanding macro needs
# PreviewsMacros plugin that's only available inside Xcode).
stub_sources() {
  local out_dir="$1"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  for f in Textream/*.swift; do
    if grep -q "^#Preview" "$f"; then
      awk '
        /^#Preview[[:space:]]*\{/ { in_block=1; print "// [no-xcode] " $0; next }
        in_block && /^}/ { print "// [no-xcode] " $0; in_block=0; next }
        in_block { print "// [no-xcode] " $0; next }
        { print }
      ' "$f" > "$out_dir/$(basename "$f")"
    else
      cp "$f" "$out_dir/"
    fi
  done
}

ARCH_BINARIES=()
for ARCH in "${ARCHES[@]}"; do
  echo ""
  echo "🔨 Compiling $(ls Textream/*.swift | wc -l | xargs) Swift sources for ${ARCH}…"
  TMP_SRC_DIR="$(pwd)/.build/swift_sources_$ARCH"
  stub_sources "$TMP_SRC_DIR"
  SWIFT_SOURCES=("$TMP_SRC_DIR"/*.swift)
  ARCH_OUT="$BUILD_DIR/${APP_NAME}_${ARCH}"
  swiftc \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -O \
    -parse-as-library \
    -o "$ARCH_OUT" \
    "${SWIFT_SOURCES[@]}"
  file "$ARCH_OUT"
  ARCH_BINARIES+=("$ARCH_OUT")
done

# Combine arch slices with lipo (universal only)
if [ "${#ARCH_BINARIES[@]}" -gt 1 ]; then
  echo ""
  echo "🔗 lipo -create → universal binary"
  lipo -create "${ARCH_BINARIES[@]}" -output "$MACOS_DIR/${APP_NAME}"
else
  cp "${ARCH_BINARIES[0]}" "$MACOS_DIR/${APP_NAME}"
fi
for ab in "${ARCH_BINARIES[@]}"; do rm -f "$ab"; done

# Verify the Mach-O binary was produced
file "$MACOS_DIR/${APP_NAME}"
lipo -info "$MACOS_DIR/${APP_NAME}"

echo "📝 Assembling Info.plist (with GENERATE_INFOPLIST_FILE fields merged)…"
# Project-root Info.plist has document/services/URL types; merge with auto-generated keys
# (CFBundleExecutable, CFBundleIdentifier, CFBundleName, CFBundleDisplayName, etc.)
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ATSApplicationFontsPath</key>
	<string>.</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUM}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>${DEPLOY_TARGET}</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Andy</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Andy题词 让同一 Wi-Fi 下的手机/平板/电脑预览或控制你的提词器（仅本地网络）。</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Andy题词 需要使用麦克风进行实时语音识别，在口播录制时高亮当前朗读到的词。</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Andy题词 使用本地语音识别引擎识别您朗读的脚本内容。</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Andy题词 脚本</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>dev.andy.tici.document</string>
			</array>
		</dict>
	</array>
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.json</string>
				<string>public.data</string>
			</array>
			<key>UTTypeDescription</key>
			<string>Andy题词 脚本</string>
			<key>UTTypeIdentifier</key>
			<string>dev.andy.tici.document</string>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>andytici</string>
				</array>
			</dict>
		</dict>
	</array>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>dev.andy.tici</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>andytici</string>
			</array>
		</dict>
	</array>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>在 Andy题词 中朗读</string>
			</dict>
			<key>NSMessage</key>
			<string>readInAndyTici</string>
			<key>NSPortName</key>
			<string>Andy题词</string>
			<key>NSSendTypes</key>
			<array>
				<string>public.utf8-plain-text</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "🖼️  Generating AppIcon.icns via iconutil (no Xcode required)…"
ICONSET_SRC="$REPO_ROOT/Textream/Textream/Assets.xcassets/AppIcon.appiconset"
ICONSET_TMP="$BUILD_DIR/AppIcon.iconset"
ICON_ICNS="$BUILD_DIR/AppIcon.icns"
rm -rf "$ICONSET_TMP" "$ICON_ICNS"
mkdir -p "$ICONSET_TMP"
# iconutil expects a *.iconset directory; copy the 10 PNG sizes with the exact
# filenames it requires (filename doesn't carry scale; size + scale are encoded
# in the name like icon_512x512@2x.png = 1024x1024).
for size_pair in "16x16" "32x32" "128x128" "256x256" "512x512"; do
  cp "$ICONSET_SRC/icon_${size_pair}.png"     "$ICONSET_TMP/icon_${size_pair}.png"
  cp "$ICONSET_SRC/icon_${size_pair}@2x.png"  "$ICONSET_TMP/icon_${size_pair}@2x.png"
done
iconutil -c icns "$ICONSET_TMP" -o "$ICON_ICNS"
file "$ICON_ICNS"
cp "$ICON_ICNS" "$RES_DIR/AppIcon.icns"
ls -la "$RES_DIR/AppIcon.icns"

echo "🔏 Ad-hoc signing (no sandbox entitlements so mic + network work locally)…"
codesign \
  --force \
  --sign - \
  --timestamp=none \
  "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR" || true

echo ""
echo "✅ Done!"
echo "   App:   $APP_DIR"
echo "   Size:  $(du -sh "$APP_DIR" | awk '{print $1}')"
echo "   Icon:  $RES_DIR/AppIcon.icns (built from AppIcon.appiconset via iconutil)"
echo ""
file "$MACOS_DIR/${APP_NAME}"
