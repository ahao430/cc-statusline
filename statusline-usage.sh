#!/bin/bash
# Query current provider's usage API and emit one-line status text.
# Supported templates (auto-detected from ccswitch DB or ANTHROPIC_BASE_URL):
#   token_plan:  zhipu (bigmodel.cn / z.ai), kimi, minimax (cn / io), zenmux
#   balance:     deepseek, stepfun, siliconflow (cn / en), openrouter, novita
#   newapi:      relay station via user-supplied baseUrl + accessToken
# Caches each API response for 60s; display is recomputed each call so session
# deltas stay fresh.
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
SESSION_DIR="${CC_SESSION_DIR:-$HOME/.cache/cc-statusline/sessions}"
TTL=60
CC_SESSION_ID="${CC_SESSION_ID:-}"

mkdir -p "$SESSION_DIR" 2>/dev/null
find "$SESSION_DIR" -type f -mtime +7 -delete 2>/dev/null &

# --- Inputs that the dispatch needs ------------------------------------------
pid=""; tmpl=""; cpp=""
base_url=""; access_token=""; user_id=""
auth_env=""; c_cfg=""; c_code=""

# --- Source 1: ccswitch DB ---------------------------------------------------
cc_json=""
if [ -n "$DB" ] && [ -f "$DB" ]; then
  cc_json=$(sqlite3 -json "$DB" 2>/dev/null <<'SQL'
SELECT
  json_extract(meta,'$.usage_script.templateType')       AS template_type,
  json_extract(meta,'$.usage_script.enabled')            AS enabled,
  json_extract(meta,'$.usage_script.baseUrl')            AS base_url,
  json_extract(meta,'$.usage_script.accessToken')        AS access_token,
  json_extract(meta,'$.usage_script.userId')             AS user_id,
  json_extract(meta,'$.usage_script.codingPlanProvider') AS cpp,
  json_extract(meta,'$.usage_script.code')               AS code,
  settings_config                                        AS cfg,
  id                                                     AS pid
FROM providers
WHERE app_type='claude' AND is_current=1;
SQL
)
fi

ccs_usable=""
if [ -n "$cc_json" ] && [ "$cc_json" != "null" ] && [ "$cc_json" != "[]" ]; then
  c_tmpl=$(echo "$cc_json"  | jq -r '.[0].template_type // empty')
  c_enabled=$(echo "$cc_json" | jq -r '.[0].enabled // empty')
  c_base=$(echo "$cc_json"  | jq -r '.[0].base_url // empty')
  c_tok=$(echo "$cc_json"   | jq -r '.[0].access_token // empty')
  c_uid=$(echo "$cc_json"   | jq -r '.[0].user_id // empty')
  c_cpp=$(echo "$cc_json"   | jq -r '.[0].cpp // empty')
  c_code=$(echo "$cc_json"  | jq -r '.[0].code // empty')
  c_cfg=$(echo "$cc_json"   | jq -r '.[0].cfg // empty')
  c_pid=$(echo "$cc_json"   | jq -r '.[0].pid // empty')
  case "$c_tmpl" in
    token_plan|balance|newapi)
      if [ "$c_enabled" != "0" ] && [ "$c_enabled" != "false" ]; then
        ccs_usable=1
        pid="$c_pid"; tmpl="$c_tmpl"; base_url="$c_base"
        access_token="$c_tok"; user_id="$c_uid"; cpp="$c_cpp"
        auth_env=$(echo "$c_cfg" | jq -r '.env.ANTHROPIC_AUTH_TOKEN // .env.ANTHROPIC_API_KEY // empty' 2>/dev/null)
      fi
      ;;
  esac
fi

# --- Source 2: env-based detection -------------------------------------------
infer_env() {
  local url="${ANTHROPIC_BASE_URL:-}"
  local key="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
  [ -z "$url" ] || [ -z "$key" ] && return 1
  pid="env"; base_url="$url"; auth_env="$key"
  access_token=""; user_id=""
  case "$url" in
    *api.kimi.com*)                              tmpl="token_plan"; cpp="kimi"; return 0 ;;
    *bigmodel.cn*|*z.ai*)                        tmpl="token_plan"; cpp="zhipu"; return 0 ;;
    *api.minimaxi.com*|*api.minimax.io*)         tmpl="token_plan"; cpp="minimax"; return 0 ;;
    *zenmux*)                                    tmpl="token_plan"; cpp="zenmux"; return 0 ;;
    *api.deepseek.com*)                          tmpl="balance"; cpp=""; return 0 ;;
    *api.stepfun.com*|*api.stepfun.ai*)          tmpl="balance"; cpp=""; return 0 ;;
    *api.siliconflow.cn*)                        tmpl="balance"; cpp=""; return 0 ;;
    *api.siliconflow.com*)                       tmpl="balance"; cpp=""; return 0 ;;
    *openrouter.ai*)                             tmpl="balance"; cpp=""; return 0 ;;
    *api.novita.ai*)                             tmpl="balance"; cpp=""; return 0 ;;
    *)                                           return 1 ;;
  esac
}

if [ -z "$ccs_usable" ]; then
  infer_env || exit 0
fi

# balance / token_plan auto-detect provider from the inference URL; if ccswitch
# didn't store one in usage_script.baseUrl, fall back to settings_config.env.
if { [ "$tmpl" = "balance" ] || [ "$tmpl" = "token_plan" ]; } && [ -z "$base_url" ] && [ -n "$c_cfg" ]; then
  base_url=$(echo "$c_cfg" | jq -r '.env.ANTHROPIC_BASE_URL // empty' 2>/dev/null)
fi

# --- API-response cache (keyed by pid+tmpl+cpp+base_url to avoid collisions) -
cache_key="${pid:-env}|${tmpl}|${cpp}|${base_url}"
resp_cache="$CACHE_DIR/cc-statusline-resp-$(printf '%s' "$cache_key" | shasum | cut -c1-12).json"

fetch_cached() {
  local now=$(date +%s)
  if [ -f "$resp_cache" ]; then
    local mtime=$(stat -f %m "$resp_cache" 2>/dev/null || stat -c %Y "$resp_cache" 2>/dev/null || echo 0)
    local age=$((now - mtime))
    if [ "$age" -lt "$TTL" ]; then
      cat "$resp_cache"
      return 0
    fi
  fi
  local body
  body=$(eval "$1" 2>/dev/null)
  [ -z "$body" ] && return 1
  printf '%s' "$body" > "$resp_cache"
  printf '%s' "$body"
}

# --- Session delta helper ----------------------------------------------------
session_start() {
  local key=$1 current=$2
  [ -z "$CC_SESSION_ID" ] && { echo "$current"; return; }
  local f="$SESSION_DIR/${CC_SESSION_ID}.${key}"
  if [ -f "$f" ]; then
    cat "$f" 2>/dev/null
  else
    printf '%s' "$current" > "$f"
    printf '%s' "$current"
  fi
}

emit() { printf '%s' "$1"; exit 0; }

# --- Tier rendering (label-based, shared by all token_plan providers) --------
render_window() {
  local pct=$1 reset=$2 label=$3
  local remaining=$(awk -v p="$pct" 'BEGIN { r=100-p; if(r<0)r=0; if(r>100)r=100; printf "%.0f", r }')
  local bcolor
  if   [ "$pct" -lt 60 ]; then bcolor=$'\033[32m'
  elif [ "$pct" -lt 85 ]; then bcolor=$'\033[33m'
  else                         bcolor=$'\033[31m'; fi
  local filled=$(awk -v r="$remaining" 'BEGIN { n=int((r+5)/10); if(n<0)n=0; if(n>10)n=10; print n }')
  local bar_full="" bar_empty="" i=0
  while [ "$i" -lt "$filled" ]; do bar_full="${bar_full}█"; i=$((i+1)); done
  while [ "$i" -lt 10 ]; do bar_empty="${bar_empty}█"; i=$((i+1)); done
  local dim=$'\033[2;37m'
  local bar=$(printf "%s%s%s%s" "$bcolor" "$bar_full" "$dim" "$bar_empty")
  local countdown=""
  if [ -n "$reset" ] && [ "$reset" != "null" ] && [ "$reset" != "0" ]; then
    local secs=$(awk -v t="${reset}" 'BEGIN { printf "%d", t/1000 }')
    local now=$(date "+%s")
    local diff=$((secs - now))
    if [ "$diff" -gt 0 ]; then
      local d=$((diff / 86400)) h=$(( (diff % 86400) / 3600 )) m=$(( (diff % 3600) / 60 ))
      if   [ "$d" -gt 0 ]; then countdown=$(printf "%dd%dh" "$d" "$h")
      elif [ "$h" -gt 0 ]; then countdown=$(printf "%dh%dm" "$h" "$m")
      else                      countdown=$(printf "%dm" "$m")
      fi
    else
      countdown="0m"
    fi
  fi
  local lbl=""
  [ -n "$label" ] && lbl="${label} "
  local seg=$(printf "%s%s剩 %s%% %s\033[0m" "$bcolor" "$lbl" "$remaining" "$bar")
  [ -n "$countdown" ] && seg=$(printf "%s \033[2m%s\033[0m" "$seg" "$countdown")
  printf '%s' "$seg"
}

# $@ = windows array of "pct|reset_ms|label" strings. Single window → no label.
render_and_emit() {
  local -a windows=("$@")
  [ "${#windows[@]}" -eq 0 ] && exit 0
  local n=${#windows[@]}
  local out="" w pct rest reset label seg
  for w in "${windows[@]}"; do
    pct="${w%%|*}"; rest="${w#*|}"
    reset="${rest%%|*}"; label="${rest##*|}"
    [ "$n" -eq 1 ] && label=""
    seg=$(render_window "$pct" "$reset" "$label")
    if [ -z "$out" ]; then out="$seg"; else out="$out \033[2m·\033[0m $seg"; fi
  done
  emit "$out"
}

# --- Dispatch ----------------------------------------------------------------
case "$tmpl" in
  token_plan)
    # Auto-detect cpp from URL when not provided (env path with non-zhipu URL)
    if [ -z "$cpp" ] || [ "$cpp" = "env" ]; then
      case "${ANTHROPIC_BASE_URL:-$base_url}" in
        *api.kimi.com*)                       cpp="kimi" ;;
        *bigmodel.cn*)                        cpp="zhipu" ;;
        *z.ai*)                               cpp="zhipu" ;;
        *api.minimaxi.com*|*api.minimax.io*)  cpp="minimax" ;;
        *zenmux*)                             cpp="zenmux" ;;
      esac
    fi

    case "$cpp" in
      zhipu)
        case "${ANTHROPIC_BASE_URL:-$base_url}" in
          *bigmodel.cn*) host="https://open.bigmodel.cn" ;;
          *z.ai*)        host="https://api.z.ai" ;;
          *)             host="https://open.bigmodel.cn" ;;
        esac
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: $auth_env' '$host/api/monitor/usage/quota/limit'") || { rm -f "$resp_cache"; exit 0; }
        windows=()
        while IFS='|' read -r pct reset unit; do
          [ -z "$pct" ] && continue
          [ "$pct" = "null" ] && continue
          case "$unit" in
            3) label="5h" ;;
            6) label="周" ;;
            *) label="u${unit}" ;;
          esac
          windows+=("$pct|$reset|$label")
        done < <(echo "$body" | jq -r '
          .data.limits[] |
          select(((.type//"") | ascii_upcase) == "TOKENS_LIMIT") |
          "\(.percentage)|\(.nextResetTime)|\(.unit)"
        ' 2>/dev/null)
        render_and_emit ${windows[@]+"${windows[@]}"}
        ;;

      kimi)
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' 'https://api.kimi.com/coding/v1/usages'") || { rm -f "$resp_cache"; exit 0; }
        windows=()
        while IFS='|' read -r pct reset; do
          [ -z "$pct" ] && continue
          [ "$pct" = "null" ] && continue
          windows+=("$pct|$reset|5h")
        done < <(echo "$body" | jq -r '
          (.limits // [])[] | .detail // empty |
          if ((.limit // 0) > 0) then
            "\((((.limit - (.remaining // 0)) / .limit) * 100) | round)|\(if .resetTime then (.resetTime | fromdateiso8601 * 1000 | floor | tostring) else "" end)"
          else empty end
        ' 2>/dev/null)
        while IFS='|' read -r pct reset; do
          [ -z "$pct" ] && continue
          [ "$pct" = "null" ] && continue
          windows+=("$pct|$reset|周")
        done < <(echo "$body" | jq -r '
          .usage // empty |
          if ((.limit // 0) > 0) then
            "\((((.limit - (.remaining // 0)) / .limit) * 100) | round)|\(if .resetTime then (.resetTime | fromdateiso8601 * 1000 | floor | tostring) else "" end)"
          else empty end
        ' 2>/dev/null)
        render_and_emit ${windows[@]+"${windows[@]}"}
        ;;

      minimax)
        case "${ANTHROPIC_BASE_URL:-$base_url}" in
          *api.minimax.io*) host="https://api.minimax.io" ;;
          *)                host="https://api.minimaxi.com" ;;
        esac
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' '$host/v1/api/openplatform/coding_plan/remains'") || { rm -f "$resp_cache"; exit 0; }
        windows=()
        while IFS='|' read -r pct reset; do
          [ -z "$pct" ] && continue
          [ "$pct" = "null" ] && continue
          windows+=("$pct|$reset|5h")
        done < <(echo "$body" | jq -r '
          (.model_remains // [])[] | select(.model_name == "general") |
          "\((100 - (.current_interval_remaining_percent // 100)) | round)|\(.end_time // "")"
        ' 2>/dev/null)
        weekly_status=$(echo "$body" | jq -r '[(.model_remains // [])[] | select(.model_name == "general")] | .[0].current_weekly_status // 0' 2>/dev/null)
        if [ "$weekly_status" = "1" ]; then
          while IFS='|' read -r pct reset; do
            [ -z "$pct" ] && continue
            [ "$pct" = "null" ] && continue
            windows+=("$pct|$reset|周")
          done < <(echo "$body" | jq -r '
            (.model_remains // [])[] | select(.model_name == "general") |
            "\((100 - (.current_weekly_remaining_percent // 100)) | round)|\(.weekly_end_time // "")"
          ' 2>/dev/null)
        fi
        render_and_emit ${windows[@]+"${windows[@]}"}
        ;;

      zenmux)
        # Per ccswitch's design, usage_script.baseUrl IS the query endpoint.
        zurl="${base_url:-${ANTHROPIC_BASE_URL:-}}"
        [ -z "$zurl" ] && exit 0
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' '$zurl'") || { rm -f "$resp_cache"; exit 0; }
        windows=()
        while IFS='|' read -r pct reset; do
          [ -z "$pct" ] && continue
          [ "$pct" = "null" ] && continue
          windows+=("$pct|$reset|5h")
        done < <(echo "$body" | jq -r '
          .data.quota_5_hour // empty |
          "\((.usage_percentage // 0) * 100 | round)|\(if .resets_at then (.resets_at | fromdateiso8601 * 1000 | floor | tostring) else "" end)"
        ' 2>/dev/null)
        while IFS='|' read -r pct reset; do
          [ -z "$pct" ] && continue
          [ "$pct" = "null" ] && continue
          windows+=("$pct|$reset|周")
        done < <(echo "$body" | jq -r '
          .data.quota_7_day // empty |
          "\((.usage_percentage // 0) * 100 | round)|\(if .resets_at then (.resets_at | fromdateiso8601 * 1000 | floor | tostring) else "" end)"
        ' 2>/dev/null)
        render_and_emit ${windows[@]+"${windows[@]}"}
        ;;
    esac
    ;;

  balance)
    bal_url="${ANTHROPIC_BASE_URL:-$base_url}"
    bal_provider=""
    case "$bal_url" in
      *api.deepseek.com*)                  bal_provider="deepseek" ;;
      *api.stepfun.com*|*api.stepfun.ai*)  bal_provider="stepfun" ;;
      *api.siliconflow.cn*)                bal_provider="siliconflow-cn" ;;
      *api.siliconflow.com*)               bal_provider="siliconflow-en" ;;
      *openrouter.ai*)                     bal_provider="openrouter" ;;
      *api.novita.ai*)                     bal_provider="novita" ;;
    esac

    bal=""; cur="CNY"; key=""
    case "$bal_provider" in
      deepseek)
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' 'https://api.deepseek.com/user/balance'") || { rm -f "$resp_cache"; exit 0; }
        bal=$(echo "$body" | jq -r '.balance_infos[0].total_balance // empty')
        cur=$(echo "$body" | jq -r '.balance_infos[0].currency // "CNY"')
        key="ds-bal"
        ;;
      stepfun)
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' 'https://api.stepfun.com/v1/accounts'") || { rm -f "$resp_cache"; exit 0; }
        bal=$(echo "$body" | jq -r '.balance // empty')
        key="sf-bal"
        ;;
      siliconflow-cn)
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' 'https://api.siliconflow.cn/v1/user/info'") || { rm -f "$resp_cache"; exit 0; }
        bal=$(echo "$body" | jq -r '.data.totalBalance // empty')
        key="sfc-bal"
        ;;
      siliconflow-en)
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' 'https://api.siliconflow.com/v1/user/info'") || { rm -f "$resp_cache"; exit 0; }
        bal=$(echo "$body" | jq -r '.data.totalBalance // empty')
        cur="USD"
        key="sfe-bal"
        ;;
      openrouter)
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' 'https://openrouter.ai/api/v1/credits'") || { rm -f "$resp_cache"; exit 0; }
        bal=$(echo "$body" | jq -r '(.data.total_credits - .data.total_usage)' 2>/dev/null)
        cur="USD"
        key="or-bal"
        ;;
      novita)
        body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $auth_env' 'https://api.novita.ai/v3/user/balance'") || { rm -f "$resp_cache"; exit 0; }
        # availableBalance is in 0.0001 USD units → divide by 10000
        bal=$(echo "$body" | jq -r '(.availableBalance / 10000)' 2>/dev/null)
        cur="USD"
        key="nv-bal"
        ;;
    esac

    [ -z "$bal" ] || [ "$bal" = "null" ] && exit 0
    sym="¥"; [ "$cur" = "USD" ] && sym="\$"
    start=$(session_start "$key" "$bal")
    delta_str=""
    if [ -n "$start" ] && [ "$start" != "$bal" ]; then
      delta_signed=$(awk -v c="$bal" -v s="$start" -v sym="$sym" 'BEGIN {
        d = s - c
        if (d > 0.001)      printf " \033[2m本次 -%s%.2f\033[0m", sym, d
        else if (d < -0.001) printf " \033[2m本次 +%s%.2f\033[0m", sym, -d
      }')
      delta_str="$delta_signed"
    fi
    emit "$(printf "%s%s%s" "$sym" "$bal" "$delta_str")"
    ;;

  newapi)
    [ -z "$base_url" ] || [ -z "$access_token" ] && exit 0
    body=$(fetch_cached "curl -sS -m 8 -H 'Authorization: Bearer $access_token' -H 'New-Api-User: $user_id' -H 'Content-Type: application/json' '$base_url/api/user/self'") || { rm -f "$resp_cache"; exit 0; }
    # JS extractor uses unquoted key: `unit: "USD"` — match both JSON and JS forms
    cur=$(echo "$c_code" | sed -n 's/.*unit[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$cur" ] && cur="USD"
    sym="¥"; [ "$cur" = "USD" ] && sym="\$"
    read quota used <<< $(echo "$body" | jq -r '"\( (.data.quota/500000) ) \( (.data.used_quota/500000) )"' 2>/dev/null)
    [ -z "$quota" ] || [ "$quota" = "null" ] && exit 0
    # Session delta: used increases as you consume
    start=$(session_start "na-used" "$used")
    delta_str=""
    if [ -n "$start" ] && [ "$start" != "$used" ]; then
      delta_signed=$(awk -v c="$used" -v s="$start" -v sym="$sym" 'BEGIN {
        d = c - s
        if (d > 0.001)      printf " \033[2m本次 +%s%.2f\033[0m", sym, d
        else if (d < -0.001) printf " \033[2m本次 -%s%.2f\033[0m", sym, -d
      }')
      delta_str="$delta_signed"
    fi
    emit "$(printf "%s%.2f\033[2m used \033[0m%s%.2f%s" "$sym" "$used" "$sym" "$quota" "$delta_str")"
    ;;
esac

exit 0
