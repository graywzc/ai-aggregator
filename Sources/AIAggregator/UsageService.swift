import Foundation
import WebKit
import Combine

struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String           // "5h", "7d"
    let percentRemaining: Int   // 0-100
    let resetsAt: Date?
}

class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published var chatGptWindows: [UsageWindow] = []
    @Published var chatGptError: String? = nil

    @Published var claudeWindows: [UsageWindow] = []
    @Published var claudeError: String? = nil

    private var timer: Timer?

    init() {
        startPolling()
    }

    // Compact "39%/35%" string for the menu bar; nil if no data.
    var chatGptCompact: String? {
        guard chatGptError == nil, !chatGptWindows.isEmpty else { return nil }
        return chatGptWindows.map { "\($0.percentRemaining)%" }.joined(separator: "/")
    }
    var claudeCompact: String? {
        guard claudeError == nil, !claudeWindows.isEmpty else { return nil }
        return claudeWindows.map { "\($0.percentRemaining)%" }.joined(separator: "/")
    }

    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchAllUsages()
        }
        fetchAllUsages()
    }

    func fetchAllUsages() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let session = self.createSession(with: cookies)
            self.fetchChatGPT(session: session)
            self.fetchClaude(session: session)
        }
    }

    private func createSession(with cookies: [HTTPCookie]) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieStorage?.cookieAcceptPolicy = .always
        for cookie in cookies { config.httpCookieStorage?.setCookie(cookie) }
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept": "application/json"
        ]
        return URLSession(configuration: config)
    }

    // MARK: - Reset-time parsing helpers

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatter = ISO8601DateFormatter()

    internal func parseDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            if let d = Self.isoFormatterFractional.date(from: s) { return d }
            if let d = Self.isoFormatter.date(from: s) { return d }
            // ISO8601DateFormatter only supports up to millisecond precision; Claude returns
            // microseconds (e.g. "2026-04-26T02:30:00.770702+00:00"). Strip the fraction and retry.
            let stripped = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
            if let d = Self.isoFormatter.date(from: stripped) { return d }
        }
        if let n = value as? Double, n > 1_000_000_000 { // looks like epoch seconds
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }

    internal func extractReset(from dict: [String: Any]) -> Date? {
        // Try common ISO timestamp fields
        for key in ["resets_at", "reset_at", "next_reset_at", "window_resets_at"] {
            if let d = parseDate(dict[key]) { return d }
        }
        // Try "seconds remaining" fields
        for key in ["resets_in_seconds", "seconds_until_reset", "reset_in_seconds", "reset_after_seconds"] {
            if let n = dict[key] as? Double { return Date(timeIntervalSinceNow: n) }
            if let n = dict[key] as? Int    { return Date(timeIntervalSinceNow: TimeInterval(n)) }
        }
        return nil
    }

    private func dumpJSON(_ tag: String, _ data: Data) {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let str = String(data: pretty, encoding: .utf8) {
            print("[\(tag)] \(str)")
        }
    }

    // MARK: - ChatGPT

    private func fetchChatGPT(session: URLSession) {
        guard let sessionUrl = URL(string: "https://chatgpt.com/api/auth/session") else { return }
        var sessionRequest = URLRequest(url: sessionUrl)
        sessionRequest.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")

        session.dataTask(with: sessionRequest) { data, response, error in
            guard let data = data,
                  let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.chatGptWindows = []
                    self.chatGptError = "Auth Error"
                }
                return
            }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["accessToken"] as? String else {
                    DispatchQueue.main.async {
                        self.chatGptWindows = []
                        self.chatGptError = "No Token"
                    }
                    return
                }
                var accountId: String? = nil
                let parts = accessToken.components(separatedBy: ".")
                if parts.count == 3 {
                    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    b64 += String(repeating: "=", count: (4 - (b64.count % 4)) % 4)
                    if let jwtData = Data(base64Encoded: b64),
                       let jwt = try? JSONSerialization.jsonObject(with: jwtData) as? [String: Any],
                       let profile = jwt["https://api.openai.com/profile"] as? [String: Any] {
                        accountId = profile["chatgpt_account_id"] as? String
                    }
                }
                self.fetchChatGPTUsage(session: session, accessToken: accessToken, accountId: accountId)
            } catch {
                DispatchQueue.main.async {
                    self.chatGptWindows = []
                    self.chatGptError = "JSON Error"
                }
            }
        }.resume()
    }

    private func fetchChatGPTUsage(session: URLSession, accessToken: String, accountId: String?) {
        guard let usageUrl = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return }
        var req = URLRequest(url: usageUrl)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")
        if let id = accountId { req.setValue(id, forHTTPHeaderField: "chatgpt-account-id") }

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    self.chatGptWindows = []
                    self.chatGptError = "Fetch Error"
                    return
                }
                self.dumpJSON("ChatGPT usage", data)
                do {
                    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let rateLimit = dict["rate_limit"] as? [String: Any] else {
                        self.chatGptWindows = []
                        self.chatGptError = "Parse Error"
                        return
                    }

                    var windows: [UsageWindow] = []
                    if let primary = rateLimit["primary_window"] as? [String: Any],
                       let used = primary["used_percent"] as? Int,
                       let secs = primary["limit_window_seconds"] as? Int {
                        windows.append(UsageWindow(
                            label: self.windowLabel(seconds: secs),
                            percentRemaining: 100 - used,
                            resetsAt: self.extractReset(from: primary)))
                    }
                    if let secondary = rateLimit["secondary_window"] as? [String: Any],
                       let used = secondary["used_percent"] as? Int,
                       let secs = secondary["limit_window_seconds"] as? Int {
                        windows.append(UsageWindow(
                            label: self.windowLabel(seconds: secs),
                            percentRemaining: 100 - used,
                            resetsAt: self.extractReset(from: secondary)))
                    }

                    self.chatGptWindows = windows
                    self.chatGptError = windows.isEmpty ? "No Limits" : nil
                } catch {
                    self.chatGptWindows = []
                    self.chatGptError = "JSON Error"
                }
            }
        }.resume()
    }

    internal func windowLabel(seconds: Int) -> String {
        if seconds >= 86400 { return "\(seconds / 86400)d" }
        if seconds >= 3600  { return "\(seconds / 3600)h" }
        if seconds >= 60    { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    // MARK: - Claude

    private func fetchClaude(session: URLSession) {
        guard let url = URL(string: "https://claude.ai/api/organizations") else { return }
        var request = URLRequest(url: url)
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")

        session.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.claudeWindows = []
                    self.claudeError = "Auth Error"
                }
                return
            }
            do {
                if let orgs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let firstOrg = orgs.first,
                   let uuid = firstOrg["uuid"] as? String {
                    self.fetchClaudeUsage(session: session, orgId: uuid)
                } else {
                    DispatchQueue.main.async {
                        self.claudeWindows = []
                        self.claudeError = "No Org ID"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.claudeWindows = []
                    self.claudeError = "JSON Error"
                }
            }
        }.resume()
    }

    private func fetchClaudeUsage(session: URLSession, orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else { return }
        var request = URLRequest(url: url)
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")

        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    self.claudeWindows = []
                    self.claudeError = "Fetch Error"
                    return
                }
                self.dumpJSON("Claude usage", data)
                do {
                    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        self.claudeWindows = []
                        self.claudeError = "Parse Error"
                        return
                    }

                    var windows: [UsageWindow] = []
                    if let five = dict["five_hour"] as? [String: Any],
                       let util = five["utilization"] as? Double {
                        windows.append(UsageWindow(
                            label: "5h",
                            percentRemaining: Int(100.0 - util),
                            resetsAt: self.extractReset(from: five)))
                    }
                    if let seven = dict["seven_day"] as? [String: Any],
                       let util = seven["utilization"] as? Double {
                        windows.append(UsageWindow(
                            label: "7d",
                            percentRemaining: Int(100.0 - util),
                            resetsAt: self.extractReset(from: seven)))
                    }

                    self.claudeWindows = windows
                    self.claudeError = windows.isEmpty ? "No Limits" : nil
                } catch {
                    self.claudeWindows = []
                    self.claudeError = "JSON Error"
                }
            }
        }.resume()
    }
}
