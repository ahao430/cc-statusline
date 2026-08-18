#!/bin/bash
# Claude Code status line (two lines):
#   line 1: model | ctx% | session tokens + cache hit | provider usage
#   line 2: dir | git branch
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

# Detect official provider from ccswitch for model prefix tag. Fetch the full
# settings_config once and reuse below for the 1M-context check.
prefix=""
cc_url=""
cc_cfg=""
if [ -n "$CCDB" ]; then
  cc_cfg=$(sqlite3 "$CCDB" 2>/dev/null "SELECT settings_config FROM providers WHERE app_type='claude' AND is_current=1;")
  cc_url=$(echo "$cc_cfg" | jq -r '.env.ANTHROPIC_BASE_URL // empty' 2>/dev/null)
fi
[ -z "$cc_url" ] && cc_url="${ANTHROPIC_BASE_URL:-}"
case "$cc_url" in
  *bigmodel.cn*|*z.ai*) prefix="智谱 " ;;
  *deepseek.com*) prefix="DeepSeek " ;;
esac
display_model="${prefix}${model}"

# Effective context window for the ctx% fallback. Claude Code reports 200000 by
# default, but non-official models differ. ccswitch tags 1M models with a [1M]
# suffix on the model id (e.g. "glm-5.2[1M]"); check the current provider's
# config for that marker (works for GLM / Claude / GPT alike). Fall back to
# parsing GLM version (5.1+ = 1M) when ccswitch isn't available.
# CC_CONTEXT_WINDOW overrides everything for other 1M models.
cw_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
if [ -n "${CC_CONTEXT_WINDOW:-}" ]; then
  cw_size="$CC_CONTEXT_WINDOW"
else
  model_id=$(echo "$input" | jq -r '.model.id // .model.display_name // ""')
  mid=$(echo "$model_id" | tr '[:upper:]' '[:lower:]')
  cw_set=0
  # 1) Authoritative model list (exact context windows). GPT 5.4+ = 1.05M;
  #    gpt-5.3-codex = 400k; Claude / DeepSeek / GLM / MiniMax 1M models = 1M.
  case "$mid" in
    gpt-5.3-codex|gpt-5.3-codex-*) cw_size=400000; cw_set=1 ;;
    gpt-5.4|gpt-5.4-*|gpt-5.5|gpt-5.5-*|gpt-5.6|gpt-5.6-*) cw_size=1050000; cw_set=1 ;;
    claude-fable-5|claude-fable-5-*|claude-opus-5|claude-opus-5-*|claude-sonnet-5|claude-sonnet-5-*|claude-opus-4-6|claude-opus-4-6-*|claude-opus-4-7|claude-opus-4-7-*|claude-opus-4-8|claude-opus-4-8-*|claude-sonnet-4-6|claude-sonnet-4-6-*) cw_size=1000000; cw_set=1 ;;
    deepseek-v4-pro|deepseek-v4-pro-*|deepseek-v4-flash|deepseek-v4-flash-*) cw_size=1000000; cw_set=1 ;;
    glm-5.1|glm-5.1-*|glm-5.2|glm-5.2-*|glm-5.3|glm-5.3-*) cw_size=1000000; cw_set=1 ;;
    minimax-m3|minimax-m3-*) cw_size=1000000; cw_set=1 ;;
  esac
  # 2) Fallback: ccswitch config tags 1M models with a [1M] suffix on the id
  #    (catches models not in the list above).
  if [ "$cw_set" -eq 0 ] && [ -n "$cc_cfg" ]; then
    echo "$cc_cfg" | jq -e --arg m "$model_id" '
      [.env.ANTHROPIC_MODEL, .env.ANTHROPIC_DEFAULT_FABLE_MODEL, .env.ANTHROPIC_DEFAULT_SONNET_MODEL, .env.ANTHROPIC_DEFAULT_OPUS_MODEL, .env.ANTHROPIC_DEFAULT_HAIKU_MODEL]
      | any(. == ($m + "[1M]") or . == ($m + "[1m]"))
    ' >/dev/null 2>&1 && { cw_size=1000000; cw_set=1; }
  fi
fi

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

# Context %: prefer Claude Code's used_percentage; the tk block below provides a
# transcript-derived fallback (used_percentage reads 0 on some non-official providers).
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx=""
ctx_color='\033[32m'

# --- Session token accounting from transcript (cached by file mtime+size) ---
# Also derives a fallback context % from the last API call's input tokens.
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
tk=""
ctx_pct=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  cache_dir="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
  sig=$(stat -f "%m.%z" "$transcript" 2>/dev/null || stat -c "%Y.%s" "$transcript" 2>/dev/null)
  cache="$cache_dir/cc-statusline-tk5-$(echo "$transcript" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-12 || echo hash)"
  if [ -f "$cache" ] && [ "$(head -1 "$cache" 2>/dev/null)" = "$sig" ]; then
    tk=$(sed -n '2p' "$cache" 2>/dev/null)
    ctx_pct=$(sed -n '3p' "$cache" 2>/dev/null)
  else
    # $5 = last non-zero row's (input + cache_creation + cache_read) = current context size.
    # (Recent entries often report 0 usage for tool calls / empty responses, so skip those.)
    read inp ccin ccrd out last_in <<< $(jq -r '
      select(.message.usage) |
      .message.usage |
      "\(.input_tokens // 0) \(.cache_creation_input_tokens // 0) \(.cache_read_input_tokens // 0) \(.output_tokens // 0)"' \
      "$transcript" 2>/dev/null | awk '{a+=$1;b+=$2;c+=$3;d+=$4; if(($1+$2+$3)>0) la=($1+$2+$3)} END {printf "%d %d %d %d %d", a, b, c, d, la+0}')
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
      # Fallback context %: last API call's input tokens ÷ effective context window
      if [ -n "$last_in" ] && [ "$last_in" -gt 0 ]; then
        ctx_pct=$(awk -v n="$last_in" -v s="$cw_size" 'BEGIN { p=n*100/s; if(p<0)p=0; if(p>100)p=100; printf "%.0f", p }')
      fi
      printf '%s\n%s\n%s' "$sig" "$tk" "$ctx_pct" > "$cache"
    fi
  fi
fi

# Resolve ctx: use Claude Code's used_percentage when populated (>0), else the
# transcript-derived ctx_pct.
final_ctx=""
if [ -n "$used_pct" ] && [ "$used_pct" != "0" ] && [ "$used_pct" != "0.0" ]; then
  final_ctx="$used_pct"
elif [ -n "$ctx_pct" ]; then
  final_ctx="$ctx_pct"
fi
if [ -n "$final_ctx" ]; then
  if awk -v u="$final_ctx" 'BEGIN { exit !(u >= 60) }'; then
    ctx=$(printf "ctx %.0f%% ⚠ 请压缩" "$final_ctx")
    ctx_color='\033[31m'
  else
    ctx=$(printf "ctx %.0f%%" "$final_ctx")
  fi
fi

# --- Provider usage from ccswitch or env-based official detection (cached 60s) ---
export CC_SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')

# --- Mid-session provider change detection ---
# Cache env fingerprint on first run; if it changes later same session, warn the user.
fp_cache_dir="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}/cc-statusline-fp"
fp_changed=""
if [ -n "$CC_SESSION_ID" ]; then
  fp_url=""; fp_key=""
  if [ -n "$CCDB" ]; then
    fp_url=$(sqlite3 "$CCDB" 2>/dev/null "SELECT json_extract(settings_config,'$.env.ANTHROPIC_BASE_URL') FROM providers WHERE app_type='claude' AND is_current=1;")
    fp_key=$(sqlite3 "$CCDB" 2>/dev/null "SELECT json_extract(settings_config,'$.env.ANTHROPIC_AUTH_TOKEN') FROM providers WHERE app_type='claude' AND is_current=1;")
  fi
  [ -z "$fp_url" ] && fp_url="${ANTHROPIC_BASE_URL:-}"
  [ -z "$fp_key" ] && fp_key="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
  fp=$(printf '%s|%s' "${fp_url:-}" "${fp_key:0:16}" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-12)
  if [ -n "$fp" ]; then
    mkdir -p "$fp_cache_dir"
    fp_file="$fp_cache_dir/${CC_SESSION_ID}"
    if [ -f "$fp_file" ]; then
      read -r fp_prev < "$fp_file"
      [ "$fp" != "$fp_prev" ] && fp_changed="1"
    else
      printf '%s' "$fp" > "$fp_file"
    fi
  fi
fi

# warning marker rendered inline after model, before the next segment
usage=$("$SCRIPT_DIR/statusline-usage.sh" 2>/dev/null)

# --- LAN IP (cached per session; fetched once at startup) ---
get_lan_ip() {
  if command -v ipconfig >/dev/null 2>&1; then
    local ip=$(ipconfig getifaddr en0 2>/dev/null)
    [ -z "$ip" ] && ip=$(ipconfig getifaddr en1 2>/dev/null)
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
  fi
  if command -v ifconfig >/dev/null 2>&1; then
    local ip=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2}' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
  fi
  if command -v ip >/dev/null 2>&1; then
    local ip=$(ip -4 addr 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d/ -f1 | head -1)
    [ -n "$ip" ] && printf '%s' "$ip"
  fi
}
lan_ip=""
if [ -n "$CC_SESSION_ID" ]; then
  ip_cache_dir="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}/cc-statusline-ip"
  ip_file="$ip_cache_dir/${CC_SESSION_ID}"
  if [ -f "$ip_file" ]; then
    lan_ip=$(cat "$ip_file" 2>/dev/null)
  else
    lan_ip=$(get_lan_ip)
    if [ -n "$lan_ip" ]; then
      mkdir -p "$ip_cache_dir" 2>/dev/null
      printf '%s' "$lan_ip" > "$ip_file"
    fi
  fi
else
  lan_ip=$(get_lan_ip)
fi

# --- Width-aware compression: skip entirely if real width unknown ---
# Strip ANSI escape sequences for accurate width measurement.
strip_ansi() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Cell-width counter (CJK / wide chars = 2, others = 1). Falls back to char count if python3 missing.
cell_width() {
  local s
  s=$(strip_ansi "$1")
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$s" | python3 -c '
import sys, unicodedata
sys.stdout.write(str(sum(2 if unicodedata.east_asian_width(c) in ("W","F") else 1 for c in sys.stdin.read())))
'
  else
    printf '%s' "$s" | wc -m | tr -d " \t\n"
  fi
}

# Truncate to max cells, keeping head + tail joined by an ellipsis in the middle.
truncate_middle() {
  local s="$1" max="$2" len=${#1}
  [ "$len" -le "$max" ] && { printf '%s' "$s"; return; }
  [ "$max" -le 1 ] && { printf '…'; return; }
  local head_n=$(( (max - 1) / 2 ))
  local tail_n=$(( max - 1 - head_n ))
  printf '%s…%s' "${s:0:$head_n}" "${s: -$tail_n}"
}

is_pos_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# Only compress when COLUMNS is explicitly set (tput cols is unreliable in Claude Code's context).
# Compression is opt-in: export COLUMNS=<w> in the shell that launches claude, or set via env hook.
cols=""
if is_pos_int "${COLUMNS:-}" && [ "${COLUMNS}" -ge 40 ]; then cols="${COLUMNS}"; fi

# Width-aware compression targets line 2 only (dir + branch + lan_ip).
# Line 1 (model | ctx | tk | usage) is naturally short and stays complete.
# lan_ip is never truncated (truncated IPs are meaningless); dir/branch shrink instead.
if [ -n "$cols" ]; then
  ip_w=0
  [ -n "$lan_ip" ] && ip_w=$(( $(cell_width "$lan_ip") + 3 ))  # " | " separator
  total2=0; nparts2=0
  for s in "$dir" "$branch"; do
    [ -z "$s" ] && continue
    total2=$((total2 + $(cell_width "$s")))
    nparts2=$((nparts2 + 1))
  done
  total2=$((total2 + 3 * (nparts2 > 0 ? nparts2 - 1 : 0) + ip_w))

  if [ "$total2" -gt "$cols" ]; then
    if [ -n "$branch" ]; then
      pair_budget=$(( cols - 3 - ip_w ))   # 1 separator between dir and branch, +ip reserved
    else
      pair_budget=$(( cols - ip_w ))
    fi
    [ "$pair_budget" -lt 8 ] && pair_budget=8

    if [ -n "$branch" ]; then
      half=$(( pair_budget / 2 ))
      [ "$half" -lt 4 ] && half=4
      dir=$(truncate_middle "$dir" "$half")
      branch=$(truncate_middle "$branch" "$half")
    else
      dir=$(truncate_middle "$dir" "$pair_budget")
    fi
  fi
fi

# --- Render ---
# Line 1: model | ctx | tk | usage  — kept complete so usage info never gets truncated.
# Line 2: dir | branch | lan_ip     — gives long paths / branch names the full width.
printf "\033[36m%s\033[0m" "$display_model"
if [ -n "$fp_changed" ]; then
  printf " \033[31m⚠\033[0m"
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
if [ -n "$dir" ] || [ -n "$branch" ] || [ -n "$lan_ip" ]; then
  printf "\n"
  if [ -n "$dir" ]; then
    printf "\033[34m%s\033[0m" "$dir"
  fi
  if [ -n "$branch" ]; then
    [ -n "$dir" ] && printf " | "
    printf "\033[35m%s\033[0m" "$branch"
  fi
  if [ -n "$lan_ip" ]; then
    { [ -n "$dir" ] || [ -n "$branch" ]; } && printf " | "
    printf "\033[2m%s\033[0m" "$lan_ip"
  fi
fi
