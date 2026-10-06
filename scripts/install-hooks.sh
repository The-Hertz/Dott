#!/bin/sh
# Installa il ponte e lo aggancia agli hook di Claude Code (~/.claude/settings.json).
# Aggiunge i nostri hook accanto a quelli che ci sono gia' e fa prima un backup.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/Dott"
SETTINGS="$HOME/.claude/settings.json"
HOOK="$DEST/dott-hook"

mkdir -p "$DEST"
cp "$HERE/dott-hook" "$HOOK"
chmod +x "$HOOK"

[ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
BACKUP="$SETTINGS.dott-backup-$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

TMP="$(mktemp)"
/usr/bin/jq --arg cmd "\"$HOOK\"" '
  def add(ev; t):
    .hooks[ev] = ((.hooks[ev] // [])
      | if any(.[]?; any(.hooks[]?; .command == $cmd)) then .
        else . + [{hooks: [{type: "command", command: $cmd, timeout: t}]}] end);
  # Le domande di Claude: un hook dedicato, con il tempo di aspettare la tua risposta.
  def addAsk:
    .hooks.PreToolUse = ((.hooks.PreToolUse // [])
      | if any(.[]?; any(.hooks[]?; .command == ($cmd + " --ask"))) then .
        else . + [{matcher: "AskUserQuestion", hooks: [{type: "command", command: ($cmd + " --ask"), timeout: 130}]}] end);
  .hooks = (.hooks // {})
  | add("SessionStart"; 5) | add("SessionEnd"; 5) | add("UserPromptSubmit"; 5)
  | add("PreToolUse"; 5) | add("PostToolUse"; 5) | add("PostToolUseFailure"; 5)
  | add("Notification"; 5) | add("PermissionRequest"; 120)
  | add("Stop"; 5) | add("StopFailure"; 5)
  | add("SubagentStart"; 5) | add("SubagentStop"; 5)
  | add("PreCompact"; 5) | add("PostCompact"; 5) | add("TaskCreated"; 5) | add("TaskCompleted"; 5)
  | add("PermissionDenied"; 120) | add("Elicitation"; 120) | add("ConfigChange"; 120) | add("PreModelSwitch"; 120)
  | addAsk
' "$SETTINGS" > "$TMP"
/usr/bin/jq empty "$TMP"
mv "$TMP" "$SETTINGS"

echo "Hook di Dott installati. Backup: $BACKUP"
