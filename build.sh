#!/bin/zsh
# Compila Pulso.app y lo instala en ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Pulso.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework IOKit -framework CoreWLAN -framework SystemConfiguration -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/Pulso"
if [[ Resources/AppIcon.svg -nt Resources/AppIcon.icns ]] && command -v rsvg-convert >/dev/null; then
  Resources/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [[ "${1:-}" == "install" ]]; then
  pkill -x Pulso 2>/dev/null && while pgrep -x Pulso >/dev/null; do sleep 0.2; done || true
  rm -rf ~/Applications/Pulso.app
  cp -R "$APP" ~/Applications/Pulso.app
  open ~/Applications/Pulso.app
  echo "Instalado en ~/Applications/Pulso.app"
fi
