#!/usr/bin/env bash
# Install cc-statusline into ~/.claude/ and wire up Claude Code's statusLine.
# Safe to re-run. Passes through CCDB if set in env.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err()  { printf "\033[31mError:\033[0m %s\n" "$*" >&2; exit 1; }
note() { printf "\033[33mNote:\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }

# --- 1. Dependencies ---------------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "missing required command: $1
please install it (e.g. \`brew install $2\` on macOS, \`apt install $2\` on Debian/Ubuntu)"
}

need_cmd jq jq
need_cmd sqlite3 sqlite3
need_cmd curl curl
need_cmd git git
ok "dependencies present"

# --- 2. Target dir -----------------------------------------------------------
mkdir -p "$CLAUDE_DIR"

# --- 3. Copy scripts ---------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/statusline.sh"        "$CLAUDE_DIR/statusline.sh"
install -m 0755 "$SCRIPT_DIR/statusline-usage.sh"  "$CLAUDE_DIR/statusline-usage.sh"
ok "scripts installed to $CLAUDE_DIR"

# --- 4. Detect ccswitch DB (informational only) ------------------------------
found_db=""
for p in \
  "$HOME/Documents/ccswitch/cc-switch.db" \
  "$HOME/Library/Application Support/com.ccswitch.desktop/cc-switch.db" \
  "$HOME/.local/share/ccswitch/cc-switch.db" \
  "$HOME/.ccswitch/cc-switch.db"; do
  if [ -f "$p" ]; then found_db="$p"; break; fi
done
if [ -n "$found_db" ]; then
  ok "ccswitch DB detected: $found_db"
else
  note "no ccswitch DB found — zhipu/deepseek usage will fall back to env-var detection"
fi

# --- 5. Wire up settings.json ------------------------------------------------
SETTINGS="$CLAUDE_DIR/settings.json"
if [ ! -f "$SETTINGS" ]; then
  printf '{}' > "$SETTINGS"
fi

# Back up before mutating
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"

STATUSLINE_CMD="bash $CLAUDE_DIR/statusline.sh"

# Use jq to set statusLine, preserving everything else
if jq -e --arg cmd "$STATUSLINE_CMD" \
   '.statusLine = {"type":"command","command":$cmd}' "$SETTINGS" > "$SETTINGS.tmp" 2>/dev/null; then
  mv "$SETTINGS.tmp" "$SETTINGS"
  ok "settings.json updated: statusLine.command = $STATUSLINE_CMD"
else
  err "failed to patch $SETTINGS — it may be malformed JSON. Inspect the .bak.* file."
fi

printf '\n\033[32mDone.\033[0m Restart Claude Code (or run /statusline in the prompt) to see the new line.\n\n'
cat <<EOF
Examples of what you'll see:

  glm-5.2 | ~/proj | main | ctx 12% | tk 2.1M | cache 87% | 剩 53% ██████ 1h33m
  DeepSeek deepseek-chat | ~/proj | main | ctx 8% | tk 540k | cache 92% | ¥71.16
  claude-sonnet-4-6 | ~/proj | main | ctx 5% | tk 12k | cache 0% | \$1.23 used \$5.00

If you use ccswitch: it overwrites settings.json on every provider switch. Add
the statusLine snippet to each provider (or to ccswitch's common config):

  "statusLine": { "type": "command", "command": "bash $CLAUDE_DIR/statusline.sh" }

EOF
