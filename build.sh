#!/bin/bash
# Builds Lyra.app into ./build.noindex (--install copies it to /Applications).
# --release also makes the two downloads in ./dist: Lyra-AppleSilicon.zip and Lyra-Intel.zip.
set -euo pipefail
cd "$(dirname "$0")"
# Fail loudly if compilation fails (never package a stale binary).
# package <arch> <app path>
package() {
  if ! swift build -c release --arch "$1" > /tmp/lyra-build.log 2>&1; then
    grep -E "error" /tmp/lyra-build.log | head -20; echo "BUILD FAILED"; exit 1
  fi
  local BIN APP="$2"
  BIN=$(swift build -c release --arch "$1" --show-bin-path)/Wordlight
  rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lyra"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
# Ad-hoc signature, but with a designated requirement of just the bundle ID. macOS stores this
# requirement when you grant a permission (Automation, System Audio Recording), so permissions
# survive rebuilds instead of being asked for again every time.
xattr -cr "$APP"   # stray file metadata would break the signature once zipped
codesign --force --deep --sign - --identifier com.almotasem.wordlight \
  -r='designated => identifier "com.almotasem.wordlight"' "$APP" >/dev/null
}

APP=build.noindex/Lyra.app   # ".noindex" keeps this copy out of Spotlight/Launchpad
package "$(uname -m)" "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--release" ]]; then
  mkdir -p dist
  for pair in "arm64:AppleSilicon" "x86_64:Intel"; do
    arch=${pair%%:*}; name=${pair##*:}
    package "$arch" "dist/$name/Lyra.app"
    rm -f "dist/Lyra-$name.zip"
    ditto -c -k --norsrc --noextattr --keepParent "dist/$name/Lyra.app" "dist/Lyra-$name.zip"
    rm -rf "dist/$name"
    echo "Made dist/Lyra-$name.zip"
  done
fi
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Lyra || true
  pkill -x Wordlight || true
  # The app used to be called Wordlight: move that old copy to the Trash (same settings carry over).
  if [ -d /Applications/Wordlight.app ]; then mv /Applications/Wordlight.app ~/.Trash/Wordlight-old-$(date +%s).app; fi
  rm -rf /Applications/Lyra.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Lyra.app"
fi
