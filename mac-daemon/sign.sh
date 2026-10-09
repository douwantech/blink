#!/bin/sh
# Sign the installed blinkd with the company's Developer ID, then restart it.
set -eu

TEAM_ID=659T9VUN97
BUNDLE_ID=com.jack.blinkd
SERVICE=com.jack.blinkd
BINARY=${1:-/Users/apple/bin/blinkd}

if [ "${1:-}" = --help ]; then
  echo "Usage: $0 [installed-blinkd-path]"
  exit 0
fi

if [ ! -f "$BINARY" ] || [ ! -x "$BINARY" ]; then
  echo "blinkd is missing or not executable: $BINARY" >&2
  exit 1
fi

# A cloud-managed Xcode certificate cannot be used by the local codesign tool.
IDENTITY=$(security find-identity -v -p codesigning | awk -v team="$TEAM_ID" '
  /"Developer ID Application:/ && index($0, "(" team ")") { print $2; exit }
')
if [ -z "$IDENTITY" ]; then
  echo "No usable Developer ID Application identity for team $TEAM_ID; blinkd was not changed." >&2
  exit 1
fi

BACKUP="${BINARY}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$BINARY" "$BACKUP"
echo "Backup: $BACKUP"

restore() {
  cp -p "$BACKUP" "$BINARY"
  echo "Restored blinkd from $BACKUP" >&2
}

if ! codesign --force --identifier "$BUNDLE_ID" --options runtime --sign "$IDENTITY" "$BINARY"; then
  restore
  exit 1
fi

if ! codesign --verify --strict --verbose=2 "$BINARY"; then
  restore
  exit 1
fi

SIGNATURE=$(codesign --display --verbose=2 "$BINARY" 2>&1)
if ! printf '%s\n' "$SIGNATURE" | grep -q "^Identifier=$BUNDLE_ID$" ||
   ! printf '%s\n' "$SIGNATURE" | grep -q "^TeamIdentifier=$TEAM_ID$" ||
   ! printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application:'; then
  echo "Unexpected blinkd signature; refusing to restart." >&2
  restore
  exit 1
fi

TARGET="gui/$(id -u)/$SERVICE"
if ! launchctl kickstart -k "$TARGET"; then
  restore
  launchctl kickstart -k "$TARGET" || true
  exit 1
fi

echo "Signed and restarted $TARGET"
codesign --display --verbose=2 "$BINARY" 2>&1 |
  grep -E '^(Identifier|Authority|TeamIdentifier)='
