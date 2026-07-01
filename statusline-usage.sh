#!/bin/bash
# Query current provider's usage API and emit one-line status text.
# Priority: ccswitch DB (current provider's usage_script) → env-based official
# detection (zhipu / deepseek hardcoded URLs). Caches per provider for 60s.
set -u

DB="${CCDB:-}"
if [ -z "$DB" ]; then
  for p in \
    "$HOME/Documents/ccswitch/cc-switch.db" \
    "$HOME/Library/Application Support/com.ccswitch.desktop/cc-switch.db" \
    "$HOME/.local/share/ccswitch/cc-switch.db" \
    "$HOME/.ccswitch/cc-switch.db"; do
    [ -f "$p" ] && DB="$p" && break
  done
fi

CACHE_DIR="${TMPDIR:-/tmp}"
TTL=60

# --- Inputs that the dispatch needs ------------------------------------------
pid=""; tmpl=""; cpp=""
base_url=""; access_token=""; user_id=""
auth_env=""

# --- Source 1: ccswitch DB ---------------------------------------------------
cc_row=""
if [ -n "$DB" ] && [ -f "$DB" ]; then
  cc_row=$(sqlite3 "$DB" 2>/dev/null <<'SQL'
SELECT id,
       json_extract(meta,'$.usage_script.templateType'),
       json_extract(meta,'$.usage_script.enabled'),
       json_extract(meta,'$.usage_script.baseUrl'),
       json_extract(meta,'$.usage_script.accessToken'),
       json_extract(meta,'$.usage_script.userId'),
       json_extract(meta,'$.usage_script.codingPlanProvider'),
       settings_config
FROM providers
WHERE app_type='claude' AND is_current=1;
SQL
)
fi

ccs_usable=""
if [ -n "$cc_row" ]; then
  c_pid=$(echo "$cc_row" | cut -d'|' -f1)
  c_tmpl=$(echo "$cc_row" | cut -d'|' -f2)
  c_enabled=$(echo "$cc_row" | cut -d'|' -f3)
  c_base=$(echo "$cc_row" | cut -d'|' -f4)
  c_tok=$(echo "$cc_row" | cut -d'|' -f5)
  c_uid=$(echo "$cc_row" | cut -d'|' -f6)
  c_cpp=$(echo "$cc_row" | cut -d'|' -f7)
  c_cfg=$(echo "$cc_row" | cut -d'|' -f8-)
  case "$c_tmpl" in
    token_plan|balance|newapi)
      if [ "$c_enabled" != "0" ]; then
        ccs_usable=1
        pid="$c_pid"; tmpl="$c_tmpl"; base_url="$c_base"
        access_token="$c_tok"; user_id="$c_uid"; cpp="$c_cpp"
        auth_env=$(echo "$c_cfg" | jq -r '.env.ANTHROPIC_AUTH_TOKEN // .env.ANTHROPIC_API_KEY // empty' 2>/dev/null)
      fi
      ;;
  esac
fi

# --- Source 2: env-based official detection ----------------------------------
infer_env() {
  local url="${ANTHROPIC_BASE_URL:-}"
  local key="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
  [ -z "$url" ] || [ -z "$key" ] && return 1
  pid="env"; base_url="$url"; auth_env="$key"
  access_token=""; user_id=""
  case "$url" in
    *bigmodel.cn*|*z.ai*) tmpl="token_plan"; cpp="zhipu"; return 0 ;;
    *deepseek.com*)       tmpl="balance";    cpp="";    return 0 ;;
    *)                    return 1 ;;
  esac
}

# Fall back to env if ccswitch unavailable or current provider has no usage config
if [ -z "$ccs_usable" ]; then
  infer_env || exit 0
fi

cache="$CACHE_DIR/cc-statusline-usage-${pid:-env}.json"
now=$(date +%s)
if [ -f "$cache" ]; then
  mtime=$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
  age=$((now - mtime))
  if [ "$age" -lt "$TTL" ]; then
    cat "$cache"
    exit 0
  fi
fi

emit() {
  local text="$1"
  printf '%s' "$text" > "$cache"
  printf '%s' "$text"
}

# --- Dispatch ----------------------------------------------------------------
case "$tmpl" in
  token_plan)
    case "$cpp" in
      zhipu)
        case "${ANTHROPIC_BASE_URL:-$base_url}" in
          *bigmodel.cn*) host="https://open.bigmodel.cn" ;;
          *z.ai*)        host="https://api.z.ai" ;;
          *)             host="https://open.bigmodel.cn" ;;
        esac
        body=$(curl -sS -m 8 -H "Authorization: $auth_env" "$host/api/monitor/usage/quota/limit" 2>/dev/null)
        [ -z "$body" ] && { rm -f "$cache"; exit 0; }
        # Pick TOKENS_LIMIT 5-hour window (unit=3); fallback to weekly (unit=6)
        read pct reset <<< $(echo "$body" | jq -r '
          .data.limits[] |
          select(((.type//"") | ascii_upcase) == "TOKENS_LIMIT" and .unit == 3) |
          "\(.percentage) \(.nextResetTime)"
        ' 2>/dev/null | head -1)
        if [ -z "$pct" ] || [ "$pct" = "null" ]; then
          read pct reset <<< $(echo "$body" | jq -r '
            .data.limits[] |
            select(((.type//"") | ascii_upcase) == "TOKENS_LIMIT" and .unit == 6) |
            "\(.percentage) \(.nextResetTime)"
          ' 2>/dev/null | head -1)
        fi
        if [ -n "$pct" ] && [ "$pct" != "null" ]; then
          remaining=$(awk -v p="$pct" 'BEGIN { r=100-p; if(r<0)r=0; if(r>100)r=100; printf "%.0f", r }')
          if   [ "$pct" -lt 60 ]; then bcolor=$'\033[32m'
          elif [ "$pct" -lt 85 ]; then bcolor=$'\033[33m'
          else                         bcolor=$'\033[31m'; fi
          filled=$(awk -v r="$remaining" 'BEGIN { n=int((r+5)/10); if(n<0)n=0; if(n>10)n=10; print n }')
          bar_full=""; i=0; while [ "$i" -lt "$filled" ]; do bar_full="${bar_full}█"; i=$((i+1)); done
          bar_empty=""; while [ "$i" -lt 10 ]; do bar_empty="${bar_empty}█"; i=$((i+1)); done
          dim=$'\033[2;37m'
          bar=$(printf "%s%s%s%s" "$bcolor" "$bar_full" "$dim" "$bar_empty")
          countdown=""
          if [ -n "$reset" ] && [ "$reset" != "null" ]; then
            secs=$(awk -v t="${reset}" 'BEGIN { printf "%d", t/1000 }')
            now=$(date "+%s")
            diff=$((secs - now))
            if [ "$diff" -gt 0 ]; then
              d=$((diff / 86400)); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
              if   [ "$d" -gt 0 ]; then countdown=$(printf "%dd%dh" "$d" "$h")
              elif [ "$h" -gt 0 ]; then countdown=$(printf "%dh%dm" "$h" "$m")
              else                      countdown=$(printf "%dm" "$m")
              fi
            else
              countdown="0m"
            fi
          fi
          out=$(printf "%s剩 %s%% %s\033[0m" "$bcolor" "$remaining" "$bar")
          [ -n "$countdown" ] && out=$(printf "%s \033[2m%s\033[0m" "$out" "$countdown")
          emit "$out"
          exit 0
        fi
        ;;
    esac
    ;;

  balance)
    body=$(curl -sS -m 8 -H "Authorization: Bearer $auth_env" "https://api.deepseek.com/user/balance" 2>/dev/null)
    [ -z "$body" ] && { rm -f "$cache"; exit 0; }
    bal=$(echo "$body" | jq -r '.balance_infos[0].total_balance // empty')
    cur=$(echo "$body" | jq -r '.balance_infos[0].currency // "CNY"')
    if [ -n "$bal" ]; then
      sym="¥"; [ "$cur" = "USD" ] && sym="\$"
      emit "$(printf "%s%s" "$sym" "$bal")"
      exit 0
    fi
    ;;

  newapi)
    [ -z "$base_url" ] || [ -z "$access_token" ] && { rm -f "$cache"; exit 0; }
    body=$(curl -sS -m 8 \
      -H "Authorization: Bearer $access_token" \
      -H "New-Api-User: $user_id" \
      -H "Content-Type: application/json" \
      "$base_url/api/user/self" 2>/dev/null)
    [ -z "$body" ] && { rm -f "$cache"; exit 0; }
    cur=$(echo "$c_cfg" | sed -n 's/.*"unit":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$cur" ] && cur="USD"
    sym="\$"; [ "$cur" = "CNY" ] && sym="¥"
    read quota used <<< $(echo "$body" | jq -r '"\( (.data.quota/500000) ) \( (.data.used_quota/500000) )"' 2>/dev/null)
    if [ -n "$quota" ] && [ "$quota" != "null" ]; then
      emit "$(printf "%s%.2f\033[2m used \033[0m%s%.2f" "$sym" "$used" "$sym" "$quota")"
      exit 0
    fi
    ;;
esac

rm -f "$cache"
exit 0
