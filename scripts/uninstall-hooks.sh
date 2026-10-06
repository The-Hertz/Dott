#!/bin/sh
# Toglie gli hook di Dott da ~/.claude/settings.json (lascia tutti gli altri).
set -e
SETTINGS="$HOME/.claude/settings.json"
HOOK="$HOME/Library/Application Support/Dott/dott-hook"
[ -f "$SETTINGS" ] || exit 0
cp "$SETTINGS" "$SETTINGS.dott-backup-$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp)"
/usr/bin/jq --arg cmd "\"$HOOK\"" '
  .hooks |= (with_entries(.value |= map(.hooks |= map(select((.command | startswith($cmd)) | not))) | map(select(.hooks | length > 0)))
             | with_entries(select(.value | length > 0)))
' "$SETTINGS" > "$TMP"
/usr/bin/jq empty "$TMP"
mv "$TMP" "$SETTINGS"
echo "Hook di Dott rimossi."
