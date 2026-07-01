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
export CCDB

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

dir_raw=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
case "$dir_raw" in
  "$HOME"*) dir="~${dir_raw#$HOME}" ;;
  *) dir="$dir_raw" ;;
esac

project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
# Try multiple candidates for git lookup — project_dir, current_dir, cwd
# NOTE: use raw paths (not the ~ -substituted dir) — git -C does not expand ~.
branch=""
for d in "$project_dir" "$dir_raw" "${PWD:-}"; do
  [ -z "$d" ] && continue
  branch=$(git -C "$d" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null) && [ -n "$branch" ] && break
done

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx=""
ctx_color='\033[32m'
if [ -n "$used" ]; then
  if awk -v u="$used" 'BEGIN { exit !(u >= 60) }'; then
    ctx=$(printf "ctx %.0f%% ⚠ 请压缩" "$used")
    ctx_color='\033[31m'
  else
    ctx=$(printf "ctx %.0f%%" "$used")
  fi
fi

# --- Session token accounting from transcript (cached by file mtime+size) ---
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
tk=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  cache_dir="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
  sig=$(stat -f "%m.%z" "$transcript" 2>/dev/null || stat -c "%Y.%s" "$transcript" 2>/dev/null)
  cache="$cache_dir/cc-statusline-tk-$(echo "$transcript" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-12 || echo hash)"
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
export CC_SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
usage=$("$SCRIPT_DIR/statusline-usage.sh" 2>/dev/null)

# --- Width-aware compression: shrink dir and branch first, keep others intact ---
cols=$(tput cols 2>/dev/null || printf '%s' "${COLUMNS:-100}")
case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
[ "$cols" -lt 40 ] && cols=100

n=0; total=0
for s in "$display_model" "$dir" "$branch" "$ctx" "$tk" "$usage"; do
  [ -z "$s" ] && continue
  total=$((total + ${#s}))
  n=$((n + 1))
done
total=$((total + 3 * (n > 0 ? n - 1 : 0)))

# 1) Compress dir: ~/workspace/foo → ~/foo (keep tilde + basename)
if [ "$total" -gt "$cols" ] && [ -n "$dir" ]; then
  short=""
  case "$dir" in
    "~")        : ;;
    "~/"*)      base=${dir##*/};  [ -n "$base" ] && short="~/$base" ;;
    "/"*)       base=${dir##*/};  [ -n "$base" ] && short="/$base" ;;
  esac
  if [ -n "$short" ] && [ ${#short} -lt ${#dir} ]; then
    total=$((total - ${#dir} + ${#short}))
    dir="$short"
  fi
fi

# 2) Truncate branch from the right: feature/foo-bar → feature…, then …
if [ "$total" -gt "$cols" ] && [ -n "$branch" ]; then
  over=$((total - cols))
  if [ $(( ${#branch} - over - 1 )) -ge 1 ]; then
    new=${branch:0:$(( ${#branch} - over - 1 ))}…
    total=$((total - ${#branch} + ${#new}))
    branch="$new"
  else
    new="…"
    total=$((total - ${#branch} + 1))
    branch="$new"
  fi
fi

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
  printf "${ctx_color}%s\033[0m" "$ctx"
fi
if [ -n "$tk" ]; then
  printf " | "
  printf "\033[33m%s\033[0m" "$tk"
fi
if [ -n "$usage" ]; then
  printf " | "
  printf "\033[36m%s\033[0m" "$usage"
fi
