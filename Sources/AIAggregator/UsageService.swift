import Foundation
import WebKit
import Combine
import Security

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

    @Published var geminiWindows: [UsageWindow] = []
    @Published var geminiError: String? = nil

    private var timer: Timer?
    private let googleClientId = "681255809395" + "-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    private let googleClientSecret = "GOCSPX-4uHgMPm" + "-1o7Sk-geV6Cu5clXFsxl"
    private let redirectUri = "https://codeassist.google.com/authcode"

    init() {
        startPolling()
    }

    var chatGptCompact: String? {
        guard chatGptError == nil, !chatGptWindows.isEmpty else { return nil }
        return chatGptWindows.map { "\($0.percentRemaining)%" }.joined(separator: "/")
    }
    var claudeCompact: String? {
        guard claudeError == nil, !claudeWindows.isEmpty else { return nil }
        return claudeWindows.map { "\($0.percentRemaining)%" }.joined(separator: "/")
    }
    var geminiCompact: String? {
        guard geminiError == nil, !geminiWindows.isEmpty else { return nil }
        return geminiWindows.map { "\($0.percentRemaining)%" }.joined(separator: "/")
    }

    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let allLoggedOut = self.chatGptError == "Logged Out"
                && self.claudeError == "Logged Out"
                && self.geminiError == "Logged Out"
            if !allLoggedOut { self.fetchAllUsages() }
        }
        fetchAllUsages()
    }

    func fetchAllUsages() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let session = self.createSession(with: cookies)
            self.fetchChatGPT(session: session)
            self.fetchClaude(session: session)
            self.fetchGemini(session: session)
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

    // MARK: - Logout Logic

    func logoutChatGPT() {
        chatGptWindows = []
        chatGptError = "Logged Out"
        ProvidersVisibility.shared.showChatGPT = false
        clearCookies(for: "chatgpt.com") {
            NotificationCenter.default.post(name: .reloadChatGPT, object: nil)
        }
    }

    func logoutClaude() {
        claudeWindows = []
        claudeError = "Logged Out"
        ProvidersVisibility.shared.showClaude = false
        clearCookies(for: "claude.ai") {
            NotificationCenter.default.post(name: .reloadClaude, object: nil)
        }
    }

    func logoutGemini() {
        UserDefaults.standard.removeObject(forKey: "gemini_refresh_token")
        ProvidersVisibility.shared.showGemini = false
        DispatchQueue.main.async {
            self.geminiWindows = []
            self.geminiError = "Logged Out"
            NotificationCenter.default.post(name: .reloadGemini, object: nil)
        }
    }

    private func clearCookies(for domainSuffix: String, completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where cookie.domain.contains(domainSuffix) {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { completion() }
        }
    }


    // MARK: - Gemini OAuth Flow

    var googleAuthURL: URL {
        let scopes = [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile"
        ].joined(separator: " ")

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: googleClientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    func handleOAuthCode(_ code: String, verifier: String = "") {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var body = "client_id=\(googleClientId)&client_secret=\(googleClientSecret)&code=\(code)&redirect_uri=\(redirectUri)&grant_type=authorization_code"
        if !verifier.isEmpty { body += "&code_verifier=\(verifier)" }
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let raw = String(data: data, encoding: .utf8) {
                print("[Gemini] token exchange: \(raw.prefix(300))")
            }
            guard let data = data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let refreshToken = dict["refresh_token"] as? String else {
                return
            }
            self.saveRefreshToken(refreshToken)
            self.fetchAllUsages()
        }.resume()
    }

    private func saveRefreshToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "gemini_refresh_token")
    }

    private func getRefreshToken() -> String? {
        UserDefaults.standard.string(forKey: "gemini_refresh_token")
    }

    // MARK: - Fetchers

    private func fetchGemini(session: URLSession) {
        guard let refreshToken = getRefreshToken() else {
            DispatchQueue.main.async {
                self.geminiWindows = []
                if self.geminiError != "Logged Out" {
                    self.geminiError = "Login Required"
                }
            }
            return
        }

        refreshGoogleToken(refreshToken: refreshToken) { accessToken in
            guard let token = accessToken else {
                DispatchQueue.main.async {
                    self.geminiWindows = []
                    self.geminiError = "Auth Error"
                }
                return
            }
            self.fetchGeminiProject(session: session, token: token)
        }
    }

    private func refreshGoogleToken(refreshToken: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let body = "client_id=\(googleClientId)&client_secret=\(googleClientSecret)&refresh_token=\(refreshToken)&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = dict["access_token"] as? String else {
                completion(nil)
                return
            }
            completion(accessToken)
        }.resume()
    }

    private func fetchGeminiProject(session: URLSession, token: String) {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let loadBody: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: loadBody)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: request) { data, response, error in
            if let httpResp = response as? HTTPURLResponse {
                print("[Gemini] loadCodeAssist HTTP \(httpResp.statusCode)")
            }
            if let data = data, let raw = String(data: data, encoding: .utf8) {
                print("[Gemini] loadCodeAssist body: \(raw.prefix(500))")
            }
            guard let data = data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let project = dict["cloudaicompanionProject"] as? String else {
                DispatchQueue.main.async {
                    self.geminiWindows = []
                    self.geminiError = "No Project"
                }
                return
            }
            print("[Gemini] project: \(project)")
            self.fetchGeminiUsage(session: session, token: token, projectId: project)
        }.resume()
    }

    private func fetchGeminiUsage(session: URLSession, token: String, projectId: String) {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let body: [String: Any] = ["project": projectId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: request) { data, response, error in
            if let httpResp = response as? HTTPURLResponse {
                print("[Gemini] retrieveUserQuota HTTP \(httpResp.statusCode)")
            }
            if let data = data, let raw = String(data: data, encoding: .utf8) {
                print("[Gemini] retrieveUserQuota body: \(raw.prefix(1000))")
            }
            DispatchQueue.main.async {
                guard let data = data,
                      let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    self.geminiWindows = []
                    self.geminiError = "Fetch Error"
                    return
                }
                do {
                    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let buckets = dict["buckets"] as? [[String: Any]] else {
                        self.geminiWindows = []
                        self.geminiError = "Parse Error"
                        return
                    }

                    // Collect all buckets then keep the lowest (most restrictive) per label
                    var best: [String: UsageWindow] = [:]
                    for bucket in buckets {
                        if let frac = bucket["remainingFraction"] as? Double {
                            let modelId = bucket["modelId"] as? String ?? "unknown"
                            let label = modelId.contains("flash") ? "Flash" : (modelId.contains("pro") ? "Pro" : modelId)
                            let pct = Int(frac * 100)
                            let existing = best[label]
                            if existing == nil || pct < existing!.percentRemaining {
                                best[label] = UsageWindow(
                                    label: label,
                                    percentRemaining: pct,
                                    resetsAt: self.extractReset(from: bucket))
                            }
                        }
                    }
                    let windows = ["Flash", "Pro"].compactMap { best[$0] }
                        + best.filter { !["Flash", "Pro"].contains($0.key) }.map(\.value)

                    self.geminiWindows = windows
                    self.geminiError = nil
                } catch {
                    self.geminiWindows = []
                    self.geminiError = "JSON Error"
                }
            }
        }.resume()
    }

    // MARK: - ChatGPT Fetcher

    private func fetchChatGPT(session: URLSession) {
        guard chatGptError != "Logged Out" else { return }
        guard let sessionUrl = URL(string: "https://chatgpt.com/api/auth/session") else { return }
        var sessionRequest = URLRequest(url: sessionUrl)
        sessionRequest.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")

        session.dataTask(with: sessionRequest) { data, response, error in
            guard let data = data,
                  let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.chatGptWindows = []
                    if self.chatGptError != "Logged Out" {
                        self.chatGptError = "Auth Error"
                    }
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
                    self.chatGptError = nil
                } catch {
                    self.chatGptWindows = []
                    self.chatGptError = "JSON Error"
                }
            }
        }.resume()
    }

    // MARK: - Claude Fetcher

    private func fetchClaude(session: URLSession) {
        guard claudeError != "Logged Out" else { return }
        guard let url = URL(string: "https://claude.ai/api/organizations") else { return }
        var request = URLRequest(url: url)
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")

        session.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.claudeWindows = []
                    if self.claudeError != "Logged Out" {
                        self.claudeError = "Auth Error"
                    }
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
                    self.claudeError = nil
                } catch {
                    self.claudeWindows = []
                    self.claudeError = "JSON Error"
                }
            }
        }.resume()
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
            let stripped = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
            if let d = Self.isoFormatter.date(from: stripped) { return d }
        }
        if let n = value as? Double, n > 1_000_000_000 {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }

    internal func extractReset(from dict: [String: Any]) -> Date? {
        for key in ["resets_at", "reset_at", "next_reset_at", "window_resets_at", "resetTime"] {
            if let d = parseDate(dict[key]) { return d }
        }
        for key in ["resets_in_seconds", "seconds_until_reset", "reset_in_seconds", "reset_after_seconds"] {
            if let n = dict[key] as? Double { return Date(timeIntervalSinceNow: n) }
            if let n = dict[key] as? Int    { return Date(timeIntervalSinceNow: TimeInterval(n)) }
        }
        return nil
    }

    internal func windowLabel(seconds: Int) -> String {
        if seconds >= 86400 { return "\(seconds / 86400)d" }
        if seconds >= 3600  { return "\(seconds / 3600)h" }
        if seconds >= 60    { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    private func dumpJSON(_ tag: String, _ data: Data) {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let str = String(data: pretty, encoding: .utf8) {
            print("[\(tag)] \(str)")
        }
    }
}
