#!/bin/sh
# Rimuove gli hook di Dott da ~/.gemini/config/hooks.json (lasciando eventuali altri hook configurati).
set -e
CONFIG_DIR="$HOME/.gemini/config"
HOOKS_FILE="$CONFIG_DIR/hooks.json"
[ -f "$HOOKS_FILE" ] || exit 0

BACKUP="$HOOKS_FILE.dott-backup-$(date +%Y%m%d-%H%M%S)"
cp "$HOOKS_FILE" "$BACKUP"

TMP="$(mktemp)"
/usr/bin/jq 'del(.dott)' "$HOOKS_FILE" > "$TMP"
/usr/bin/jq empty "$TMP"
mv "$TMP" "$HOOKS_FILE"

echo "Hook di Dott rimossi da Gemini."
echo "Backup salvato: $BACKUP"
