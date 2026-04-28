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

## License
MIT
