#!/bin/sh
# Installs the latest Scribe release into /Applications, plus a `scribe` terminal command.
#   curl -fsSL https://raw.githubusercontent.com/WHATDOESTHEFOXSAY2U/scribe/main/install.sh | sh
set -e
REPO="WHATDOESTHEFOXSAY2U/scribe"

[ "$(uname -s)" = "Darwin" ] || { echo "Scribe runs on macOS only."; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Scribe needs an Apple Silicon Mac (M1 or later)."; exit 1; }
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 26 ] || { echo "Scribe needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Scribe…"
curl -fL --progress-bar "https://github.com/$REPO/releases/latest/download/Scribe.zip" -o "$TMP/Scribe.zip"
ditto -x -k "$TMP/Scribe.zip" "$TMP"
[ -d "$TMP/Scribe.app" ] || { echo "The download did not contain Scribe.app."; exit 1; }

pkill -x Scribe 2>/dev/null || true
rm -rf /Applications/Scribe.app
cp -R "$TMP/Scribe.app" /Applications/Scribe.app
# The app is not notarised by Apple; without this macOS refuses to open a downloaded copy.
xattr -dr com.apple.quarantine /Applications/Scribe.app 2>/dev/null || true

# Links (YouTube and other sites) need yt-dlp; unusual file formats need ffmpeg.
if command -v brew >/dev/null 2>&1; then
  for tool in yt-dlp ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Installing $tool…"; brew install "$tool"; }
  done
  BIN="$(brew --prefix)/bin"
  if [ -w "$BIN" ]; then
    printf '#!/bin/sh\nexec /Applications/Scribe.app/Contents/MacOS/Scribe "$@"\n' > "$BIN/scribe"
    chmod +x "$BIN/scribe"
  fi
else
  echo "Homebrew was not found. Local files will work; for links, install Homebrew (https://brew.sh) and run: brew install yt-dlp ffmpeg"
fi

echo "Scribe is installed. Opening it now. The first transcription downloads the speech models (about 1 GB, once)."
open /Applications/Scribe.app
