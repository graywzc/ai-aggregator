# AI Aggregator

A macOS menu bar application that aggregates and displays your current usage limits and remaining quota for various AI services, such as ChatGPT and Claude.

## Features

- **Menu Bar Integration**: Real-time usage percentages (e.g., "39%/35%") displayed directly in your macOS menu bar.
- **Multi-Service Support**: 
  - **ChatGPT**: Tracks primary and secondary rate limit windows.
  - **Claude**: Monitors 5-hour and 7-day utilization windows.
- **Secure Authentication**: Uses a built-in WebView to handle authentication directly with the providers. It leverages system cookies and never stores your credentials or tokens locally.
- **Automatic Polling**: Refreshes usage data every minute.
- **Clean UI**: A popover view showing detailed reset times and progress bars.

## How It Works

AI Aggregator functions as a wrapper around the internal usage APIs of AI providers. 
1. **Login**: When you first run the app, you use the integrated WebView to sign in to ChatGPT or Claude.
2. **Cookie Management**: The app retrieves the session cookies from the WebKit store.
3. **Data Fetching**: It uses these cookies to authorized requests to endpoints like \`/backend-api/wham/usage\` (ChatGPT) and \`/api/organizations/{id}/usage\` (Claude).
4. **Fallback**: If no usage data is available or providers are not logged in, the menu bar displays a simple "A" icon.

## Installation & Building

### Prerequisites

- macOS 13.0 or later
- Xcode Command Line Tools (\`swiftc\` and \`make\`)

### Build from Source

1. Clone the repository:
   \`\`\`bash
   git clone https://github.com/graywzc/ai-aggregator.git
   cd ai-aggregator
   \`\`\`

2. Build the application:
   \`\`\`bash
   make
   \`\`\`

3. Run the application:
   \`\`\`bash
   make run
   \`\`\`

The app will be built as \`build/AIAggregator.app\`.

## Development

The project structure is simple and modular:
- \`Sources/AIAggregatorApp.swift\`: Main entry point and menu bar logic.
- \`Sources/UsageService.swift\`: Core logic for polling and parsing API responses.
- \`Sources/ProviderWebAuthView.swift\`: WebView implementation for provider login.
- \`Sources/UsagePopoverView.swift\`: The UI for the detailed usage breakdown.

## License

MIT
