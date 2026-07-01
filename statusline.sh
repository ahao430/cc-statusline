#!/bin/bash
# Claude Code status line:
#   model | dir | git branch | ctx% | session tokens + cache hit | provider usage
# Designed to run as the command of Claude Code's statusLine setting.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCDB="${CCDB:-}"
[ -z "$CCDB" ] && for p in \
  "$HOME/Documents/ccswitch/cc-switch.db" \
  "$HOME/Library/Application Support/com.ccswitch.desktop/cc-switch.db" \
  "$HOME/.local/share/ccswitch/cc-switch.db" \
  "$HOME/.ccswitch/cc-switch.db"; do
  [ -f "$p" ] && CCDB="$p" && break
done

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Detect official provider from ccswitch for model prefix tag
prefix=""
if [ -n "$CCDB" ]; then
  cc_url=$(sqlite3 "$CCDB" 2>/dev/null <<'SQL'
SELECT json_extract(settings_config,'$.env.ANTHROPIC_BASE_URL')
FROM providers WHERE app_type='claude' AND is_current=1;
SQL
)
  case "$cc_url" in
    *bigmodel.cn*|*z.ai*) prefix="智谱 " ;;
    *deepseek.com*) prefix="DeepSeek " ;;
  esac
fi
display_model="${prefix}${model}"

dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
case "$dir" in
  "$HOME"*) dir="~${dir#$HOME}" ;;
esac

project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
branch=""
if [ -n "$project_dir" ]; then
  branch=$(git -C "$project_dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx=""
[ -n "$used" ] && ctx=$(printf "ctx %.0f%%" "$used")

# --- Session token accounting from transcript (cached by file mtime+size) ---
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
tk=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  cache_dir="${TMPDIR:-/tmp}"
  sig=$(stat -f "%m.%z" "$transcript" 2>/dev/null || stat -c "%Y.%s" "$transcript" 2>/dev/null)
  cache="$cache_dir/cc-statusline-tk-$(echo "$transcript" | shasum 2>/dev/null | cut -c1-12 || echo hash)"
  if [ -f "$cache" ] && [ "$(head -1 "$cache" 2>/dev/null)" = "$sig" ]; then
    tk=$(tail -n +2 "$cache")
  else
    read inp ccin ccrd out <<< $(jq -r '
      select(.message.usage) |
      .message.usage |
      "\(.input_tokens // 0) \(.cache_creation_input_tokens // 0) \(.cache_read_input_tokens // 0) \(.output_tokens // 0)"' \
      "$transcript" 2>/dev/null | awk '{a+=$1;b+=$2;c+=$3;d+=$4} END {printf "%d %d %d %d", a, b, c, d}')
    if [ -n "$inp" ]; then
      total=$((inp + ccin + ccrd + out))
      denom=$((inp + ccin + ccrd))
      if [ "$denom" -gt 0 ]; then
        hit=$(awk -v r="$ccrd" -v d="$denom" 'BEGIN { printf "%.0f", r*100/d }')
      else
        hit=0
      fi
      if   [ "$total" -ge 1000000 ]; then htk=$(awk -v n="$total" 'BEGIN { printf "%.1fM", n/1000000 }')
      elif [ "$total" -ge 1000 ];    then htk=$(awk -v n="$total" 'BEGIN { printf "%.1fk", n/1000 }')
      else                                htk="${total}"
      fi
      tk=$(printf "tk %s \033[2m|\033[0m cache %s%%" "$htk" "$hit")
      printf '%s\n%s' "$sig" "$tk" > "$cache"
    fi
  fi
fi

# --- Provider usage from ccswitch or env-based official detection (cached 60s) ---
usage=$("$SCRIPT_DIR/statusline-usage.sh" 2>/dev/null)

# --- Render ---
printf "\033[36m%s\033[0m" "$display_model"
printf " | "
printf "\033[34m%s\033[0m" "$dir"
if [ -n "$branch" ]; then
  printf " | "
  printf "\033[35m%s\033[0m" "$branch"
fi
if [ -n "$ctx" ]; then
  printf " | "
  printf "\033[32m%s\033[0m" "$ctx"
fi
if [ -n "$tk" ]; then
  printf " | "
  printf "\033[33m%s\033[0m" "$tk"
fi
if [ -n "$usage" ]; then
  printf " | "
  printf "\033[36m%s\033[0m" "$usage"
fi
