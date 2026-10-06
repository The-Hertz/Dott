# Dott

Una creaturina nel notch del Mac che reagisce a Claude Code tramite gli hook.

- `./build.sh` compila `build/Dott.app` (Swift Package, nessun progetto Xcode)
- `scripts/install-hooks.sh` copia il ponte in `~/Library/Application Support/Dott/` e lo aggiunge a `~/.claude/settings.json` (backup incluso)
- `scripts/uninstall-hooks.sh` lo toglie, lasciando gli altri hook
- `build/Dott.app/Contents/MacOS/Dott --snapshot <cartella>` disegna tutti gli stati in PNG

Come parlano: hook → `dott-hook` (sh + nc) → socket Unix `~/Library/Application Support/Dott/dott.sock` (0600) → l'isola.
Per i permessi (`PermissionRequest`) l'hook aspetta la tua risposta; se non arriva, Claude Code chiede nel terminale come sempre.

Controllo dal vivo: `kill -USR1 $(pgrep -x Dott)` salva la vista reale della finestra in `/tmp/dott-live.png`
(lo schermo non si puo' fotografare: serve a vedere l'aspetto vero, animazioni escluse).

## Hook gestiti
Ascolta: SessionStart/End, UserPromptSubmit, PreToolUse, PostToolUse(+Failure), Notification (anche quota e agenti), Stop(+Failure),
SubagentStart/Stop, PreCompact/PostCompact, TaskCreated/Completed.
Aspetta una tua decisione (card nell'isola): PermissionRequest, PermissionDenied («Riprova»), Elicitation (moduli e link dei server MCP),
e, se attivati nelle impostazioni, ConfigChange e PreModelSwitch.
Comandi di prova sul socket: `{"dott_gesture":"giggle"}`, `{"dott_cmd":"settings|allow|deny|elic_accept|elic_decline|music|poke|detach|dock|pin|repo|hotkeys"}`.
