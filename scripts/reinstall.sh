#!/usr/bin/env bash
# Rebuild discworld-vitals.mallardx and install it to Mallard's dev plugin dir.
# Resolves the install dir via the platform app-data path (matches Mallard's
# in-tree reinstall scripts). The plugin repo can live anywhere on disk.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_NAME="discworld-vitals"
PLUGIN_ID="net.mallard.${PLUGIN_NAME}"

case "$(uname -s)" in
  Darwin) PLUGINS_DEV="$HOME/Library/Application Support/net.mallard.app/plugins-dev" ;;
  *) echo "error: unsupported OS $(uname -s); see Mallard's reinstall scripts for the pattern" >&2; exit 1 ;;
esac

DEST="$PLUGINS_DEV/$PLUGIN_ID"
mkdir -p "$PLUGINS_DEV"

contents=(plugin.toml src ui)

cd "$REPO_ROOT"
echo "Rebuilding $REPO_ROOT/$PLUGIN_NAME.mallardx ..."
rm -f "$PLUGIN_NAME.mallardx"
zip -qr "$PLUGIN_NAME.mallardx" "${contents[@]}"

echo "Installing to $DEST ..."
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "${contents[@]/#/$REPO_ROOT/}" "$DEST/"

VERSION="$(grep '^version' "$REPO_ROOT/plugin.toml" | head -1 | sed 's/[^"]*"\([^"]*\)".*/\1/')"
echo ""
echo "$PLUGIN_NAME v$VERSION installed."
echo "  bundle: $REPO_ROOT/$PLUGIN_NAME.mallardx"
echo "  dev:    $DEST"
echo ""
