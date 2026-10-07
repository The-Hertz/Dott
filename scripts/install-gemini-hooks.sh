#!/bin/sh
# Installa il ponte per Gemini / Antigravity e lo aggancia in ~/.gemini/config/hooks.json.
# Fa prima un backup del file hooks.json se esiste gia'.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/Dott"
CONFIG_DIR="$HOME/.gemini/config"
HOOKS_FILE="$CONFIG_DIR/hooks.json"
HOOK="$DEST/gemini-dott-hook"

mkdir -p "$DEST"
cp "$HERE/gemini-dott-hook" "$HOOK"
chmod +x "$HOOK"

mkdir -p "$CONFIG_DIR"
[ -f "$HOOKS_FILE" ] || echo '{}' > "$HOOKS_FILE"

BACKUP="$HOOKS_FILE.dott-backup-$(date +%Y%m%d-%H%M%S)"
cp "$HOOKS_FILE" "$BACKUP"

TMP="$(mktemp)"
/usr/bin/jq --arg hook "$HOOK" '
  .dott = {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": ($hook + " PreToolUse"),
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": ($hook + " PostToolUse"),
            "timeout": 5
          }
        ]
      }
    ],
    "PreInvocation": [
      {
        "type": "command",
        "command": ($hook + " PreInvocation"),
        "timeout": 5
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": ($hook + " Stop"),
        "timeout": 5
      }
    ]
  }
' "$HOOKS_FILE" > "$TMP"

/usr/bin/jq empty "$TMP"
mv "$TMP" "$HOOKS_FILE"

echo "Hook di Gemini per Dott installati con successo."
echo "Configurazione: $HOOKS_FILE"
echo "Backup salvato: $BACKUP"
