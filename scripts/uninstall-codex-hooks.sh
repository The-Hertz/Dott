#!/bin/sh
# Rimuove gli hook di Dott da Codex (~/.codex/hooks.json e ~/.codex/config.toml).
set -e
CODEX_DIR="$HOME/.codex"
HOOKS_FILE="$CODEX_DIR/hooks.json"
CONFIG_FILE="$CODEX_DIR/config.toml"
SKY="$HOME/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
HOOK="$HOME/Library/Application Support/Dott/codex-dott-hook"

if [ -f "$HOOKS_FILE" ]; then
    cp "$HOOKS_FILE" "$HOOKS_FILE.dott-backup-$(date +%Y%m%d-%H%M%S)"
    TMP="$(mktemp)"
    /usr/bin/jq --arg cmd "$HOOK" '
      .hooks |= (with_entries(.value |= map(.hooks |= map(select((.command | startswith($cmd)) | not))) | map(select(.hooks | length > 0)))
                 | with_entries(select(.value | length > 0)))
    ' "$HOOKS_FILE" > "$TMP"
    /usr/bin/jq empty "$TMP"
    mv "$TMP" "$HOOKS_FILE"
    echo "Hook di Dott rimossi da ~/.codex/hooks.json."
fi

if [ -f "$CONFIG_FILE" ]; then
    if [ -x "$SKY" ]; then
        sed -i '' "s|^notify *=.*|notify = [\"$SKY\", \"turn-ended\"]|" "$CONFIG_FILE"
    else
        sed -i '' "/^notify *=/d" "$CONFIG_FILE"
    fi
    echo "Configurazione notify ripristinata in ~/.codex/config.toml."
fi
