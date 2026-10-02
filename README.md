# AI Aggregator

![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![Swift](https://img.shields.io/badge/swift-5.9-orange)
![License](https://img.shields.io/github/license/graywzc/ai-aggregator)
![Release](https://img.shields.io/github/v/release/graywzc/ai-aggregator)
![Downloads](https://img.shields.io/github/downloads/graywzc/ai-aggregator/total)

A macOS menu bar application that aggregates and displays your current usage limits and remaining quota for various AI services, such as ChatGPT and Claude.

## Demo

<video src="https://github.com/user-attachments/assets/5789b285-eb9b-46d5-b501-3423fe5c5a3b" controls width="100%"></video>

<video src="https://github.com/user-attachments/assets/8bc18180-8021-416e-94e3-1bae871b5c20" controls width="100%"></video>

## Features

- **Menu Bar Integration**: Real-time usage percentages (e.g., "39%/35%") displayed directly in your macOS menu bar.
- **Multi-Service Support**: Tracks ChatGPT and Claude utilization windows.
- **Secure Authentication**: Uses a built-in WebView; leverages system cookies and never stores credentials locally.
- **Automatic Polling**: Refreshes usage data every minute.
- **Claude Code Speed**: Shows average generation speed (e.g., "62t/s") in the menu bar, with time to first token in the popover. See [Claude Code speed stats](#claude-code-speed-stats).

## Claude Code speed stats

Claude Code can export per-request timings over OpenTelemetry. AIAggregator listens for them on `127.0.0.1:14318` (loopback only) and shows the average output tokens per second over the last 50 requests in the menu bar (total output tokens over total streaming time). Turn it on by adding this to `~/.claude/settings.json`, then start a new Claude Code session (CLI or desktop app):

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
    "OTEL_TRACES_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_METRICS_EXPORTER": "none",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:14318"
  }
}
```

The protocol must be `http/json`; protobuf and gRPC exports are ignored. Generation speed is output tokens divided by the time after the first token. Requests with fewer than 20 output tokens are left out of the rates.

### Per-request log

The list icon next to "Claude Code" in the popover opens a table of every API call Claude Code has made, in the style of a local inference server's request log: status, input tokens split into uncached / cache read / cache write, TTFT, output tokens, generation speed, total time, stop reason and Claude Code's estimated cost. Selecting a row shows every attribute Claude Code reported for it. Clicking the Model column header opens a checklist of the models seen, with select all / select none; unchecked models drop out of the table and the totals above it. The table shows the last 2,000 requests; every request is kept, with account identifiers stripped, in a SQLite database at `~/Library/Application Support/AIAggregator/claude-code.sqlite` (the `requests` and `prompts` tables). Earlier versions' `claude-code-requests.jsonl` is imported on first launch and renamed `.imported`.

### Stats

The Stats tab of the same window totals the history over a period (today, yesterday, 7 days, 30 days, this month, all time): completed and failed requests, input and output tokens, Claude Code's estimated cost, generation speed and average TTFT, broken down by model and by day. Generation speed is total output tokens over total time after the first token, so short requests can't skew it. The database is plain SQLite, so anything the tab doesn't show is one query away, for example cost per day over the last two weeks:

```bash
sqlite3 ~/Library/Application\ Support/AIAggregator/claude-code.sqlite "select date(date,'unixepoch','localtime') day, round(sum(cost_usd),2) usd from requests where success group by day order by day desc limit 14"
```

Internal calls such as the auto-mode permission classifier appear too, labeled by their source; Claude Code reports no TTFT for them. The Prompt column shows your prompt text only if you also set `"OTEL_LOG_USER_PROMPTS": "1"`; that text is then stored in the same folder.

### Turns: end to end

The Turns tab of the Claude Code requests window shows each turn end to end. A turn is one prompt and everything Claude Code did to answer it: the rounds of model requests, the tool calls between them, permission checks and hooks. Each row shows the turn's end-to-end time and how it splits between waiting on the model, tools running on the machine, permission checks, waiting on you (a question or a plan to approve; in terminal sessions a permission prompt too, but under the desktop app Claude Code doesn't report who decided, so a prompt you answered there counts as a permission check), hooks, and Claude Code's own work in between. Selecting a turn lays its steps out on a timeline; steps inside a subagent are indented under the Agent call.

Its Compare view puts machines side by side: each host's share of time per group, and below it the same kind of step on two hosts of your choice, this Mac and the busiest other machine to begin with. Each kind of step (a model, a tool, or the program a shell command runs, such as `swift build` or `git push`) is one row with both hosts' number of calls, median and 90th-percentile time, and which host's median is shorter and by how many times. Steps only one of the two ran are left out until you turn off "Only steps both ran". Tool times there leave out the permission phase, so they measure the machine. To compare this Mac with another, send that machine's telemetry here as described under [Requests from your other machines](#requests-from-your-other-machines).

Turns come from the trace export, which the settings above already turn on (`OTEL_TRACES_EXPORTER` and `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA`). A turn appears when it finishes. Two optional settings add detail:

- `"OTEL_LOG_TOOL_DETAILS": "1"` sends each shell command, which is what sorts Bash calls into build, test, install, git and search. Without it every Bash call is just "Bash". The commands are stored in the database.
- `"OTEL_LOG_USER_PROMPTS": "1"` labels each turn with its prompt.

The start and end of every step are Claude Code's own; the split is worked out from them by giving each moment of the turn to the innermost step running then, so parallel tool calls aren't counted twice and the parts add up to the whole. Spans are kept in the `spans` table of the same database.

## Codex requests

Codex, the coding agent in the ChatGPT app and the `codex` CLI, can send the same kind of per-request telemetry. The list icon next to "Codex" in the popover opens a Codex Requests window with the same table and Stats tab, kept in its own database at `~/Library/Application Support/AIAggregator/codex.sqlite`. Turn it on by adding this to `~/.codex/config.toml`, then start a new Codex session:

```toml
[otel]
log_user_prompt = true   # optional: shows your prompt text in the Prompt column
exporter = { otlp-http = { endpoint = "http://127.0.0.1:14318/v1/logs", protocol = "json" } }
```

Codex reports each response's token counts (input includes cached tokens, output includes reasoning tokens) and TTFT. It reports no request duration, so Total is the time from Codex's request event to its response-completed event. Codex reports no cost or stop reason either. Those two columns show reasoning tokens and reasoning effort instead. The first request of a session is usually Codex warming up its connection: it has input tokens but no output or TTFT. The menu bar shows Codex's average speed with a `cx` prefix while its Speed switch is on.

## Requests from your other machines

Agents on your other Macs can export to this one over [Tailscale](https://tailscale.com). Turn on **Accept from tailnet** at the top of either requests window: AIAggregator then also listens on this Mac's Tailscale address (shown next to the switch), taking connections from tailnet addresses only. On the other machine, point the agent at this Mac's MagicDNS name instead of `127.0.0.1`, for example in that machine's Codex config:

```toml
[otel]
exporter = { otlp-http = { endpoint = "http://mba.your-tailnet.ts.net:14318/v1/logs", protocol = "json" } }
```

or, for Claude Code, `"OTEL_EXPORTER_OTLP_ENDPOINT": "http://mba.your-tailnet.ts.net:14318"`. Each request records the machine it came from, by its MagicDNS name. The Host column shows it, and its header filters by it like the Model header does. The Stats tab adds a breakdown by host. Requests from this Mac show its own name. Leave prompt logging off on a machine that sends large documents to its agent, or the full text travels with each export. Exports sent while this Mac is asleep or off the tailnet are lost.

## Installation

### Via Homebrew (Highly Recommended)

This is the easiest way to install and stay updated. It also automatically handles the macOS "damaged app" error by re-signing the binary locally.

```bash
brew install graywzc/tap/ai-aggregator
```

### Manual Installation

1. Download the latest `AIAggregator.zip` from the [Releases](https://github.com/graywzc/ai-aggregator/releases) page.
2. Unzip and move `AIAggregator.app` to your `/Applications` folder.
3. If you see a "damaged" or "unverified developer" error, run these commands in your terminal:
   ```bash
   xattr -cr /Applications/AIAggregator.app
   codesign --force --deep --sign - /Applications/AIAggregator.app
   ```
4. Right-click the app and select **Open** for the first time.

## Development

### Prerequisites
- macOS 13.0+
- Xcode Command Line Tools

### Build & Run
```bash
make        # Build the .app bundle
make run    # Build and launch
make test   # Run unit tests
```

### Release

Releases are tag-driven. Pushing a `v*` tag builds `AIAggregator.zip`,
publishes a GitHub release asset, then opens a matching Homebrew tap PR in
`graywzc/homebrew-tap`.

```bash
git switch main
git pull
git tag v1.2.1
git push origin v1.2.1
```

After the workflow finishes, review and merge the generated Homebrew tap PR.
The release workflow requires the `HOMEBREW_TAP_TOKEN` repository secret.

## License
MIT
