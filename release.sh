#!/bin/zsh
# Empaqueta Pulso para publicarlo en GitHub Releases.
#   ./release.sh            → compila y crea dist/Pulso-<versión>.zip
#   ./release.sh --publish  → además crea el tag v<versión> y la release en GitHub (requiere gh)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
ZIP="dist/Pulso-$VERSION.zip"

./build.sh
mkdir -p dist && rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --noqtn --keepParent build/Pulso.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "Creado $ZIP"
echo "SHA-256: $SHA"

if [[ "${1:-}" == "--publish" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Hay cambios sin commit; haz commit antes de publicar." >&2; exit 1
  fi
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  gh release create "v$VERSION" "$ZIP" --title "Pulso $VERSION" --notes "$(cat <<NOTES
Requiere macOS 14 o superior en un Mac con Apple Silicon (M1 o posterior).

**Instalación:** descomprime el zip, mueve \`Pulso.app\` a Aplicaciones y ábrela.
La app no está notarizada por Apple; la primera vez sigue los pasos de la sección
[Primera apertura](https://github.com/$REPO#primera-apertura) del README.

SHA-256 de \`Pulso-$VERSION.zip\`: \`$SHA\`
NOTES
)"
fi
