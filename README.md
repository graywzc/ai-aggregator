# AI Aggregator

A macOS menu bar application that aggregates and displays your current usage limits and remaining quota for various AI services, such as ChatGPT and Claude.

## Features

- **Menu Bar Integration**: Real-time usage percentages (e.g., "39%/35%") displayed directly in your macOS menu bar.
- **Multi-Service Support**: Tracks ChatGPT and Claude utilization windows.
- **Secure Authentication**: Uses a built-in WebView; leverages system cookies and never stores credentials locally.
- **Automatic Polling**: Refreshes usage data every minute.

## Installation

### Via Homebrew (Recommended)

To install and keep the app updated easily:

```bash
brew install graywzc/tap/ai-aggregator
```

### Manual Installation

1. Download the latest `AIAggregator.zip` from the [Releases](https://github.com/graywzc/ai-aggregator/releases) page.
2. Unzip and move `AIAggregator.app` to your `/Applications` folder.
3. **Important**: Because the app is ad-hoc signed, you may need to run the following command in your terminal to allow it to run:
   ```bash
   xattr -cr /Applications/AIAggregator.app
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

## License
MIT
