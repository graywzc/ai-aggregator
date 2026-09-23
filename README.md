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
- **Claude Code Speed**: Shows generation speed (e.g., "62t/s") in the menu bar, with time to first token in the popover. See [Claude Code speed stats](#claude-code-speed-stats).

## Claude Code speed stats

Claude Code can export per-request timings over OpenTelemetry. AIAggregator listens for them on `127.0.0.1:14318` (loopback only) and shows the latest request's output tokens per second in the menu bar. Turn it on by adding this to `~/.claude/settings.json`, then start a new Claude Code session (CLI or desktop app):

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
