#!/bin/sh
# Install the latest Gowa.app release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/nyelonong/gowa/main/scripts/install.sh | sh
#
# The app is ad-hoc signed (no Apple notarization), so the script removes the
# download quarantine after verifying the zip layout.
set -eu

REPO=nyelonong/gowa
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Fetching latest release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -oE "https://[^"]*Gowa\.app\.zip" | head -1)
[ -n "$URL" ] || { echo "No Gowa.app.zip found in the latest release"; exit 1; }

echo "Downloading $URL…"
curl -fsSL -o "$TMP/Gowa.app.zip" "$URL"

unzip -q "$TMP/Gowa.app.zip" -d "$TMP"

if [ -d /Applications/Gowa.app ]; then
    echo "Replacing existing /Applications/Gowa.app…"
    rm -rf /Applications/Gowa.app
fi

mv "$TMP/Gowa.app" /Applications/Gowa.app
xattr -dr com.apple.quarantine /Applications/Gowa.app 2>/dev/null || true

echo "Installed /Applications/Gowa.app — open it from Launchpad or:"
echo "  open -a Gowa"
