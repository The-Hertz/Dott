#!/bin/sh
# Installa il ponte per Codex e lo aggancia in ~/.codex/hooks.json e ~/.codex/config.toml.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/Dott"
CODEX_DIR="$HOME/.codex"
HOOKS_FILE="$CODEX_DIR/hooks.json"
CONFIG_FILE="$CODEX_DIR/config.toml"
HOOK="$DEST/codex-dott-hook"

mkdir -p "$DEST"
cp "$HERE/codex-dott-hook" "$HOOK"
chmod +x "$HOOK"

mkdir -p "$CODEX_DIR"

# 1. Configura ~/.codex/hooks.json
if [ -f "$HOOKS_FILE" ]; then
    cp "$HOOKS_FILE" "$HOOKS_FILE.dott-backup-$(date +%Y%m%d-%H%M%S)"
fi

TMP="$(mktemp)"
/usr/bin/jq --arg cmd "$HOOK" '
  def add(ev; t):
    .hooks[ev] = ((.hooks[ev] // [])
      | if any(.[]?; any(.hooks[]?; .command == $cmd)) then .
        else . + [{hooks: [{type: "command", command: $cmd, timeout: t}]}] end);
  .hooks = (.hooks // {})
  | add("SessionStart"; 5) | add("SessionEnd"; 5) | add("UserPromptSubmit"; 5)
  | add("PreToolUse"; 5) | add("PostToolUse"; 5)
  | add("Stop"; 5) | add("PermissionRequest"; 120)
' "${HOOKS_FILE:-/dev/null}" 2>/dev/null > "$TMP" || echo "{\"hooks\":{}}" > "$TMP"

/usr/bin/jq empty "$TMP"
mv "$TMP" "$HOOKS_FILE"

# 2. Aggiorna notify in ~/.codex/config.toml se presente
if [ -f "$CONFIG_FILE" ]; then
    BACKUP="$CONFIG_FILE.dott-backup-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP"
    # Sostituisce o aggiunge notify che chiama codex-dott-hook turn-ended
    if grep -q "^notify *=" "$CONFIG_FILE"; then
        sed -i '' "s|^notify *=.*|notify = [\"$HOOK\", \"turn-ended\"]|" "$CONFIG_FILE"
    else
        echo "notify = [\"$HOOK\", \"turn-ended\"]" >> "$CONFIG_FILE"
    fi
    echo "Backup config.toml salvato: $BACKUP"
fi

echo "Hook di Codex per Dott installati con successo."
echo "Configurazione hooks: $HOOKS_FILE"
