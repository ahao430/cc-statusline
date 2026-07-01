# cc-statusline

A richer Claude Code status line: model · directory · git branch · context % · **session tokens + cache hit rate** · **provider usage** (智谱 / DeepSeek / newapi relays).

```
智谱 glm-5.2 | ~/proj | main | ctx 12% | tk 2.1M | cache 87% | 剩 53% ██████ 1h33m
DeepSeek deepseek-chat | ~/proj | main | ctx 8% | tk 540k | cache 92% | ¥71.16
claude-sonnet-4-6 | ~/proj | main | ctx 5% | tk 12k | cache 0% | $1.23 used $5.00
```

## Features

- **Model** — current Claude Code model, with `智谱 ` / `DeepSeek ` prefix when the active base URL points at the official endpoint.
- **Directory & git branch** — current dir (with `~` shortening) + branch when inside a git repo.
- **Context %** — how full the context window is.
- **Session tokens** — cumulative `input + cache_creation + cache_read + output` from the active transcript, with cache hit rate.
- **Provider usage** — pulled from your configured provider:
  - **智谱 GLM Coding Plan** (5h window): `剩 N% ████████ 1h33m` — remaining %, color-coded progress bar, countdown to reset. Green <60 % used, yellow <85 %, red ≥85 %.
  - **DeepSeek official**: `¥71.16` balance.
  - **newapi relays** (configured via ccswitch): `$1.23 used $5.00` — used / total in the relay's configured currency.

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
- Caches: usage results 60 s per provider; session-token counts until transcript mtime/size changes.

## Layout

```
statusline.sh          # entry point — parses Claude Code's stdin payload
statusline-usage.sh    # provider usage query (ccswitch DB → env fallback)
install.sh             # installer
```

## License

MIT
