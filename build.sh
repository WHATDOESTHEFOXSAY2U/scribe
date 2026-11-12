#!/bin/zsh
# Builds Scribe.app and installs it to /Applications (plus a `scribe` command if /opt/homebrew/bin is writable).
set -e
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Scribe"
APP="build/Scribe.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
strip "$APP/Contents/MacOS/Scribe"  # every symbol: 1 MB smaller; the cost is unsymbolicated crash reports

# The icon is drawn by Icon.swift and only redrawn when that file changes.
ICON=".build/AppIcon.icns"
if [[ ! -f "$ICON" || Icon.swift -nt "$ICON" ]]; then
  rm -rf .build/AppIcon.iconset
  swift Icon.swift .build/AppIcon.iconset && iconutil -c icns .build/AppIcon.iconset -o "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Scribe</string>
  <key>CFBundleIdentifier</key><string>local.scribe</string>
  <key>CFBundleExecutable</key><string>Scribe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.4</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Recording</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>
      <string>public.audiovisual-content</string>
      <string>public.audio</string>
    </array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
rm -rf /Applications/Scribe.app && cp -R "$APP" /Applications/Scribe.app
# The command is a wrapper, not a symlink: run through its real path the program counts as the app,
# so both share one compiled-model cache and the half-minute first-run preparation happens once.
CLI=/opt/homebrew/bin/scribe
if [[ -w "${CLI:h}" ]]; then
  rm -f "$CLI"
  print -r -- '#!/bin/sh
exec /Applications/Scribe.app/Contents/MacOS/Scribe "$@"' > "$CLI"
  chmod +x "$CLI"
fi
du -sh /Applications/Scribe.app
