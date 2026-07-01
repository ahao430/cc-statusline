# cc-statusline

A richer Claude Code status line: model · directory · git branch · context % (with high-usage warning) · **session tokens + cache hit rate** · **provider usage** (智谱 / DeepSeek / newapi relays) — including **per-session consumption** for billing/balance providers.

```
智谱 glm-5.2 | ~/proj | main | ctx 12% | tk 2.1M | cache 87% | 剩 53% ██████ 1h33m
智谱 glm-5.2 | ~/proj | main | ctx 12% | tk 2.1M | cache 87% | 5h 剩 53% ████ 1h33m · 周 剩 78% ████████ 4d12h
DeepSeek deepseek-chat | ~/proj | main | ctx 8% | tk 540k | cache 92% | ¥71.16 本次 -¥0.45
claude-sonnet-4-6 | ~/proj | main | ctx 72% ⚠ 请及时压缩 | tk 480k | cache 90% | $1.23 used $5.00 本次 +$0.12
```

## Features

- **Model** — current Claude Code model, with `智谱 ` / `DeepSeek ` prefix when the active base URL points at the official endpoint.
- **Directory & git branch** — current dir (with `~` shortening) + branch when inside a git repo (tries `current_dir` → `project_dir` → `$PWD`).
- **Context %** — how full the context window is. Turns red and shows `⚠ 请及时压缩` once usage crosses 60 %.
- **Session tokens** — cumulative `input + cache_creation + cache_read + output` from the active transcript, with cache hit rate.
- **Provider usage** — pulled from your configured provider:
  - **智谱 GLM Coding Plan**: each TOKENS_LIMIT window as `剩 N% ██████ 1h33m` — remaining %, color-coded progress bar (green <60 % used, yellow <85 %, red ≥85 %), countdown to reset. When both 5-hour and weekly windows exist, both are shown with labels: `5h 剩 53% ████ 1h33m · 周 剩 78% ████████ 4d12h`.
  - **DeepSeek official**: `¥71.16 本次 -¥0.45` — current balance plus consumption since the session began.
  - **newapi relays** (configured via ccswitch): `$1.23 used $5.00 本次 +$0.12` — used / total in the relay's configured currency (`CNY` → ¥, `USD` → $), plus consumption since session start.

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/ahao430/cc-statusline/main/install.sh | bash
```

This copies `statusline.sh` + `statusline-usage.sh` to `~/.claude/`, makes them executable, and patches `~/.claude/settings.json` to wire them into Claude Code's `statusLine`.

### From a clone

```bash
git clone https://github.com/ahao430/cc-statusline.git
cd cc-statusline
./install.sh
```

### Dependencies

`jq`, `sqlite3`, `curl`, `git` — install.sh checks for them and tells you what's missing.

macOS: `brew install jq sqlite3`
Ubuntu/Debian: `sudo apt install jq sqlite3`

## How provider usage is resolved

The script tries sources in this order:

1. **ccswitch DB** (`~/Documents/ccswitch/cc-switch.db` on macOS, plus a few fallback paths). If the current provider has a `usage_script` configured, use it.
2. **Environment variables** — fall back to `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` (inherited from the Claude Code process) and match against the official Zhipu / DeepSeek endpoints.

If neither yields a usable endpoint, the usage segment is silently omitted. Override the DB path with `CCDB=/path/to/cc-switch.db` in your shell environment.

## ccswitch users — important

ccswitch rewrites `~/.claude/settings.json` on every provider switch, so the statusLine config installed by `install.sh` will be clobbered. Add this snippet to each Claude provider in ccswitch (or to ccswitch's common config):

```json
"statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh" }
```

## Configuration

| Env var | Purpose | Default |
|---|---|---|
| `CCDB` | Path to ccswitch SQLite DB | auto-detect |
| `CLAUDE_DIR` | Where to install scripts | `~/.claude` |
| `ANTHROPIC_BASE_URL` | Inference base URL (env fallback) | inherited |
| `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` | API key (env fallback) | inherited |

## Performance

- Cold run: ~0.7 s (mostly the provider usage HTTP call).
- Warm (cache hit): ~0.23 s — well within Claude Code's statusLine throttle.
- Caches: provider API response 60 s per provider (display, including session deltas, is recomputed on every call so deltas stay fresh); session-token counts until transcript mtime/size changes.
- Per-session start values stored at `~/.cache/cc-statusline/sessions/<session_id>.<key>`; auto-cleaned after 7 days.

## Layout

```
statusline.sh          # entry point — parses Claude Code's stdin payload
statusline-usage.sh    # provider usage query (ccswitch DB → env fallback)
install.sh             # installer
```

## License

MIT
