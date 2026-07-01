# cc-statusline

Claude Code 的增强状态栏：模型 · 目录 · git 分支 · 上下文占比（超量告警）· **本次会话 token + 缓存命中率** · **渠道用量**（智谱 / Kimi / MiniMax / ZenMux / DeepSeek / StepFun / SiliconFlow / OpenRouter / Novita / newapi 中转站），余额类渠道还会显示 **本次会话消耗**。

```
智谱 glm-5.2 | ~/proj | main | ctx 12% | tk 2.1M | cache 87% | 剩 53% ██████ 1h33m
智谱 glm-5.2 | ~/proj | main | ctx 12% | tk 2.1M | cache 87% | 5h 剩 53% ████ 1h33m · 周 剩 78% ████████ 4d12h
DeepSeek deepseek-chat | ~/proj | main | ctx 8% | tk 540k | cache 92% | ¥71.16 本次 -¥0.45
claude-sonnet-4-6 | ~/proj | main | ctx 72% ⚠ 请压缩 | tk 480k | cache 90% | $1.23 used $5.00 本次 +$0.12
```

## 功能

- **模型** —— 当前 Claude Code 模型名；当激活的 baseURL 命中官方端点时，自动加 `智谱 ` / `DeepSeek ` 前缀。
- **目录 & git 分支** —— 当前目录（`~` 缩写）+ git 分支（依次尝试 `current_dir` → `project_dir` → `$PWD`）。
- **上下文占比** —— 上下文窗口使用率，超过 60% 时变红并提示 `⚠ 请压缩`。
- **会话 token** —— 从 transcript 累加 `input + cache_creation + cache_read + output`，附带缓存命中率。
- **渠道用量** —— 按当前渠道拉取：
  - **套餐类（token_plan）**：每个窗口显示为 `剩 N% ██████ 1h33m` —— 剩余百分比、颜色进度条（用量 <60% 绿、<85% 黄、≥85% 红）、倒计时。多窗口时加标签：`5h 剩 53% ████ 1h33m · 周 剩 78% ████████ 4d12h`。支持：
    - **智谱 GLM Coding Plan**（`bigmodel.cn` / `z.ai`）—— TOKENS_LIMIT 窗口（5h + 周）
    - **Kimi For Coding**（`api.kimi.com`）—— `limits[].detail` (5h) + `usage` (周)
    - **MiniMax**（`api.minimaxi.com` CN / `api.minimax.io` EN）—— `model_remains[general]` 5h + 周（仅 `current_weekly_status==1` 时）
    - **ZenMux**（`zenmux` 域名）—— `quota_5_hour` + `quota_7_day`
  - **余额类（balance）**：`¥71.16 本次 -¥0.45` —— 当前余额 + 本次会话消耗。支持：
    - **DeepSeek**（`api.deepseek.com`）—— `balance_infos[0].total_balance`（自动识别 CNY / USD）
    - **StepFun**（`api.stepfun.com` / `api.stepfun.ai`）—— `.balance`（CNY）
    - **SiliconFlow CN/EN**（`api.siliconflow.cn` CNY / `api.siliconflow.com` USD）—— `.data.totalBalance`
    - **OpenRouter**（`openrouter.ai`）—— `total_credits - total_usage`（USD）
    - **NovitaAI**（`api.novita.ai`）—— `availableBalance / 10000`（原始单位 0.0001 USD）
  - **newapi 中转站**（经 ccswitch 配置）：`$1.23 used $5.00 本次 +$0.12` —— 已用 / 总额（按渠道 `unit` 字段自动选货币符号，`CNY` → ¥、`USD` → $）+ 本次会话消耗。

## 安装

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/ahao430/cc-statusline/main/install.sh | bash
```

会把 `statusline.sh` 和 `statusline-usage.sh` 拷到 `~/.claude/`、赋予执行权限，并把 `~/.claude/settings.json` 的 `statusLine` 字段指向脚本。

### 从克隆安装

```bash
git clone https://github.com/ahao430/cc-statusline.git
cd cc-statusline
./install.sh
```

### 依赖

`jq`、`sqlite3`、`curl`、`git` —— install.sh 会检测缺失项并提示。

macOS：`brew install jq sqlite3`
Ubuntu/Debian：`sudo apt install jq sqlite3`

## 渠道用量解析顺序

脚本按以下优先级取渠道用量：

1. **ccswitch DB**（macOS 默认在 `~/Documents/ccswitch/cc-switch.db`，外加若干 fallback 路径）。当前渠道若配了 `usage_script`，就用它。
2. **环境变量** —— 退化到 `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`（从 Claude Code 进程继承），按 URL 关键字自动识别全部 10 个内置渠道（智谱 / Kimi / MiniMax / ZenMux / DeepSeek / StepFun / SiliconFlow / OpenRouter / Novita / newapi 不走此路径，需 ccswitch）。

都没命中时，用量段静默不显示。可用 `CCDB=/path/to/cc-switch.db` 覆盖 DB 路径。

## ccswitch 用户注意事项

ccswitch 每次切换渠道都会覆盖 `~/.claude/settings.json`，install.sh 写入的 statusLine 配置会被冲掉。请在 ccswitch 里给每个 Claude 渠道（或 ccswitch 的公共配置）加上这段：

```json
"statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh" }
```

## 配置项

| 环境变量 | 用途 | 默认值 |
|---|---|---|
| `CCDB` | ccswitch SQLite DB 路径 | 自动探测 |
| `CLAUDE_DIR` | 脚本安装目录 | `~/.claude` |
| `ANTHROPIC_BASE_URL` | 推理 baseURL（环境变量兜底用） | 继承 |
| `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` | API key（环境变量兜底用） | 继承 |

## 性能

- 冷启动：约 0.7 秒（主要花在拉取渠道用量的 HTTP 请求上）。
- 缓存命中：约 0.23 秒，远低于 Claude Code 的 statusLine 节流窗口。
- 缓存策略：渠道 API 响应按渠道缓存 60 秒（展示内容、含本次会话消耗，每次调用都重新计算，保证增量新鲜）；会话 token 按文件 mtime + size 失效。
- 会话起始值保存在 `~/.cache/cc-statusline/sessions/<session_id>.<key>`，超过 7 天自动清理。

## 仓库结构

```
statusline.sh          # 入口 —— 解析 Claude Code 的 stdin payload，渲染状态栏
statusline-usage.sh    # 渠道用量查询（ccswitch DB → 环境变量兜底）
install.sh             # 一键安装脚本
```

## License

MIT
