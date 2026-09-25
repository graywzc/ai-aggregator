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

The list icon next to "Claude Code" in the popover opens a table of every API call Claude Code has made, in the style of a local inference server's request log: status, input tokens split into uncached / cache read / cache write, TTFT, output tokens, generation speed, total time, stop reason and Claude Code's estimated cost. Selecting a row shows every attribute Claude Code reported for it. The table shows the last 2,000 requests; every request is kept, with account identifiers stripped, in a SQLite database at `~/Library/Application Support/AIAggregator/claude-code.sqlite` (the `requests` and `prompts` tables). Earlier versions' `claude-code-requests.jsonl` is imported on first launch and renamed `.imported`.

### Stats

The Stats tab of the same window totals the history over a period (today, yesterday, 7 days, 30 days, this month, all time): completed and failed requests, input and output tokens, Claude Code's estimated cost, generation speed and average TTFT, broken down by model and by day. Generation speed is total output tokens over total time after the first token, so short requests can't skew it. The database is plain SQLite, so anything the tab doesn't show is one query away, for example cost per day over the last two weeks:

```bash
sqlite3 ~/Library/Application\ Support/AIAggregator/claude-code.sqlite "select date(date,'unixepoch','localtime') day, round(sum(cost_usd),2) usd from requests where success group by day order by day desc limit 14"
```

Internal calls such as the auto-mode permission classifier appear too, labeled by their source; Claude Code reports no TTFT for them. The Prompt column shows your prompt text only if you also set `"OTEL_LOG_USER_PROMPTS": "1"`; that text is then stored in the same folder.

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
