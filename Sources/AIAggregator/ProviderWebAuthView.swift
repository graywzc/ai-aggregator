import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AppKit
import CommonCrypto

extension Notification.Name {
    static let reloadChatGPT = Notification.Name("reloadChatGPT")
    static let reloadClaude  = Notification.Name("reloadClaude")
    static let reloadGemini  = Notification.Name("reloadGemini")
}

// MARK: - Attachment model

struct ChatAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let data: Data
    let mimeType: String
    var name: String { url.lastPathComponent }

    static func load(from url: URL) -> ChatAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                   ?? "application/octet-stream"
        return ChatAttachment(url: url, data: data, mimeType: mime)
    }
}

// MARK: - Persistent dual WebView controller

final class DualChatController: NSObject, ObservableObject, WKNavigationDelegate {
    let chatGPTView: WKWebView
    let claudeView: WKWebView
    let geminiView: WKWebView

    @Published var chatGPTCurrentURL: URL?
    @Published var claudeCurrentURL: URL?
    @Published var geminiCurrentURL: URL?

    // Post-send URL watching
    private var watchingForURLChange = false
    private var pendingSessionName: String?
    private var baselineChatGPTURL: URL?
    private var baselineClaudeURL: URL?
    private var baselineGeminiURL: URL?
    private var urlWatchTimeout: DispatchWorkItem?
    var onSessionURLsReady: ((String, URL?, URL?, URL?) -> Void)?

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    override init() {
        chatGPTView = Self.makeWebView()
        claudeView  = Self.makeWebView()
        geminiView  = Self.makeWebView()
        super.init()

        chatGPTView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
        claudeView.addObserver(self,  forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
        geminiView.addObserver(self,  forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)

        chatGPTView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
        claudeView.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
        geminiView.load(URLRequest(url: URL(string: "https://gemini.google.com/app")!))

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reloadChatGPT), name: .reloadChatGPT, object: nil)
        nc.addObserver(self, selector: #selector(reloadClaude),  name: .reloadClaude,  object: nil)
        nc.addObserver(self, selector: #selector(reloadGemini),  name: .reloadGemini,  object: nil)
    }

    @objc private func reloadChatGPT() {
        chatGPTView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    }

    @objc private func reloadClaude() {
        claudeView.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
    }

    @objc private func reloadGemini() {
        geminiView.load(URLRequest(url: URL(string: "https://gemini.google.com/app")!))
    }

    func navigate(to session: ChatSession) {
        cancelURLWatch()
        print("[Session] navigate to '\(session.name)'")
        print("[Session]   chatGPT: \(session.chatGPTURL ?? "nil")")
        print("[Session]   claude:  \(session.claudeURL ?? "nil")")
        print("[Session]   gemini:  \(session.geminiURL ?? "nil")")
        if let str = session.chatGPTURL, let url = URL(string: str) {
            chatGPTView.load(URLRequest(url: url))
        }
        if let str = session.claudeURL, let url = URL(string: str) {
            claudeView.load(URLRequest(url: url))
        }
        if let str = session.geminiURL, let url = URL(string: str) {
            geminiView.load(URLRequest(url: url))
        }
    }

    func navigateToHomepages() {
        cancelURLWatch()
        chatGPTView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
        claudeView.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
        geminiView.load(URLRequest(url: URL(string: "https://gemini.google.com/app")!))
    }

    func startWatchingForConversationURLs(name: String) {
        cancelURLWatch()
        baselineChatGPTURL = chatGPTCurrentURL
        baselineClaudeURL  = claudeCurrentURL
        baselineGeminiURL  = geminiCurrentURL
        pendingSessionName = name
        watchingForURLChange = true
        print("[Session] watching for URL changes after send (baseline: \(chatGPTCurrentURL?.absoluteString ?? "nil"), \(claudeCurrentURL?.absoluteString ?? "nil"), \(geminiCurrentURL?.absoluteString ?? "nil"))")

        let timeout = DispatchWorkItem { [weak self] in
            print("[Session] timeout reached, flushing with current URLs")
            self?.flushPendingSession()
        }
        urlWatchTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func cancelURLWatch() {
        watchingForURLChange = false
        pendingSessionName = nil
        urlWatchTimeout?.cancel()
        urlWatchTimeout = nil
    }

    private func checkIfReadyToSave() {
        guard watchingForURLChange else { return }
        let v = ProvidersVisibility.shared
        let chatGPTReady = !v.showChatGPT || chatGPTCurrentURL != baselineChatGPTURL
        let claudeReady  = !v.showClaude  || claudeCurrentURL  != baselineClaudeURL
        let geminiReady  = !v.showGemini  || geminiCurrentURL  != baselineGeminiURL
        print("[Session] URL check — chatGPT:\(chatGPTReady) claude:\(claudeReady) gemini:\(geminiReady)")
        if chatGPTReady && claudeReady && geminiReady {
            flushPendingSession()
        }
    }

    private func flushPendingSession() {
        guard let name = pendingSessionName else { return }
        cancelURLWatch()
        print("[Session] flush '\(name)' — chatGPT:\(chatGPTCurrentURL?.absoluteString ?? "nil") claude:\(claudeCurrentURL?.absoluteString ?? "nil") gemini:\(geminiCurrentURL?.absoluteString ?? "nil")")
        onSessionURLsReady?(name, chatGPTCurrentURL, claudeCurrentURL, geminiCurrentURL)
    }

    deinit {
        chatGPTView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
        claudeView.removeObserver(self,  forKeyPath: #keyPath(WKWebView.url))
        geminiView.removeObserver(self,  forKeyPath: #keyPath(WKWebView.url))
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(WKWebView.url), let webView = object as? WKWebView else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        DispatchQueue.main.async {
            let url = webView.url
            if webView === self.chatGPTView {
                print("[URL] chatGPT -> \(url?.absoluteString ?? "nil")")
                self.chatGPTCurrentURL = url
            } else if webView === self.claudeView {
                print("[URL] claude  -> \(url?.absoluteString ?? "nil")")
                self.claudeCurrentURL = url
            } else if webView === self.geminiView {
                print("[URL] gemini  -> \(url?.absoluteString ?? "nil")")
                self.geminiCurrentURL = url
            }
            self.checkIfReadyToSave()
        }
    }

    private static func makeWebView() -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = userAgent
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        return wv
    }
    
    func send(text: String, attachments: [ChatAttachment]) {
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let attachmentsJSON = encodeAttachments(attachments)
        let v = ProvidersVisibility.shared
        if v.showChatGPT {
            inject(into: chatGPTView, text: text, attachmentsJSON: attachmentsJSON,
                   inputSelectors: ["#prompt-textarea"],
                   sendSelectors: ["button[data-testid=\"send-button\"]",
                                   "button[aria-label*=\"Send\" i]:not([disabled])"])
        }
        if v.showClaude {
            inject(into: claudeView, text: text, attachmentsJSON: attachmentsJSON,
                   inputSelectors: ["div.ProseMirror[contenteditable=\"true\"]",
                                    "div[contenteditable=\"true\"]"],
                   sendSelectors: ["button[aria-label=\"Send message\"]",
                                   "button[aria-label=\"Send Message\"]",
                                   "button[aria-label*=\"Send\" i]:not([disabled])"],
                   useFileInputFallback: true)
        }
        if v.showGemini {
            inject(into: geminiView, text: text, attachmentsJSON: attachmentsJSON,
                   inputSelectors: ["rich-textarea div.ql-editor[contenteditable=\"true\"]",
                                    "div.ql-editor[contenteditable=\"true\"]",
                                    "div[contenteditable=\"true\"]"],
                   sendSelectors: ["button.send-button",
                                   "button[aria-label=\"Send message\" i]",
                                   "button[aria-label*=\"Send\" i]"],
                   useEnterToSend: true,
                   useClipboardPaste: true)
        }
    }

    func encodeAttachments(_ attachments: [ChatAttachment]) -> String {
        let dicts: [[String: String]] = attachments.map { [
            "base64": $0.data.base64EncodedString(),
            "mime": $0.mimeType,
            "name": $0.name
        ] }
        guard let json = try? JSONSerialization.data(withJSONObject: dicts),
              let str = String(data: json, encoding: .utf8) else { return "[]" }
        return str
    }

    func jsonString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }

    private func inject(into webView: WKWebView,
                        text: String,
                        attachmentsJSON: String,
                        inputSelectors: [String],
                        sendSelectors: [String],
                        useEnterToSend: Bool = false,
                        useClipboardPaste: Bool = false,
                        useFileInputFallback: Bool = false) {
        let inputSelectorJS = inputSelectors.map { "'\($0)'" }.joined(separator: ", ")
        let sendSelectorJS  = sendSelectors.map  { "'\($0)'" }.joined(separator: ", ")
        let textJSON = jsonString(text)

        let js = """
        (function() {
            const text = \(textJSON);
            const files = \(attachmentsJSON);
            const inputSelectors = [\(inputSelectorJS)];
            const sendSelectors  = [\(sendSelectorJS)];
            const useFileInputFallback = \(useFileInputFallback ? "true" : "false");
            const useClipboardPaste = \(useClipboardPaste ? "true" : "false");
            const useEnter = \(useEnterToSend ? "true" : "false");

            function findInput() {
                for (const sel of inputSelectors) {
                    const el = document.querySelector(sel);
                    if (el) return el;
                }
                return null;
            }

            function findSend() {
                for (const sel of sendSelectors) {
                    const els = document.querySelectorAll(sel);
                    for (const el of els) {
                        if (el.disabled) continue;
                        if (el.getAttribute('aria-disabled') === 'true') continue;
                        return el;
                    }
                }
                return null;
            }

            const input = findInput();
            if (!input) return 'no-input';
            input.focus();

            function buildFiles() {
                const out = [];
                for (const f of files) {
                    const binary = atob(f.base64);
                    const bytes = new Uint8Array(binary.length);
                    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                    out.push(new File([new Blob([bytes], { type: f.mime })], f.name, { type: f.mime }));
                }
                return out;
            }

            if (files.length > 0) {
                const dt = new DataTransfer();
                for (const file of buildFiles()) dt.items.add(file);
                const evt = new Event('paste', { bubbles: true, cancelable: true });
                Object.defineProperty(evt, 'clipboardData', { value: dt });
                input.dispatchEvent(evt);
            }

            if (useFileInputFallback && files.length > 0) {
                setTimeout(() => {
                    let host = input;
                    let fi = null;
                    while (host && !fi) {
                        fi = host.querySelector('input[type="file"]');
                        host = host.parentElement;
                    }
                    if (!fi) {
                        fi = Array.from(document.querySelectorAll('input[type="file"]'))
                            .find(x => {
                                const a = (x.accept || '').toLowerCase();
                                return !a || a.includes('image') || a.includes('*');
                            });
                    }
                    if (!fi) return;
                    try {
                        const dt = new DataTransfer();
                        for (const file of buildFiles()) dt.items.add(file);
                        fi.files = dt.files;
                        fi.dispatchEvent(new Event('change', { bubbles: true }));
                        fi.dispatchEvent(new Event('input',  { bubbles: true }));
                    } catch (e) {}
                }, 50);
            }

            function setText() {
                if (input.tagName === 'TEXTAREA') {
                    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
                    setter.call(input, text);
                    input.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
                    return;
                }
                input.focus();

                if (useClipboardPaste) {
                    function findQuill() {
                        let el = input;
                        while (el) {
                            try {
                                for (const k of Object.getOwnPropertyNames(el)) {
                                    try {
                                        const v = el[k];
                                        if (v && typeof v === 'object'
                                            && typeof v.insertText  === 'function'
                                            && typeof v.deleteText  === 'function'
                                            && typeof v.getLength   === 'function') {
                                            return v;
                                        }
                                    } catch (e) {}
                                }
                            } catch (e) {}
                            el = el.parentElement;
                        }
                        return null;
                    }
                    const quill = findQuill();
                    if (quill && text.length > 0) {
                        try {
                            const len = quill.getLength();
                            if (len > 1) quill.deleteText(0, len - 1, 'user');
                            quill.insertText(0, text, 'user');
                            input.focus();
                            input.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
                        } catch (e) {}
                    }
                } else {
                    const sel = window.getSelection();
                    sel.removeAllRanges();
                    const allRange = document.createRange();
                    allRange.selectNodeContents(input);
                    sel.addRange(allRange);
                    document.execCommand('delete', false, null);
                    if (text.length > 0) {
                        document.execCommand('insertText', false, text);
                    }
                    input.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
                }
            }

            function pressEnter() {
                const opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
                               bubbles: true, cancelable: true };
                input.dispatchEvent(new KeyboardEvent('keydown', opts));
                input.dispatchEvent(new KeyboardEvent('keypress', opts));
                input.dispatchEvent(new KeyboardEvent('keyup', opts));
            }

            const initialDelay = files.length > 0 ? 600 : 60;
            setTimeout(() => {
                setText();
                let attempts = 0;
                const maxAttempts = files.length > 0 ? 60 : 15;
                const tick = () => {
                    const btn = findSend();
                    if (btn) { btn.click(); return; }
                    if (++attempts < maxAttempts) {
                        setTimeout(tick, 250);
                    } else if (useEnter) {
                        pressEnter();
                    }
                };
                tick();
            }, initialDelay);

            return 'queued';
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    static func findJS(for query: String) -> String? {
        guard let data = try? JSONEncoder().encode(query),
              let qJSON = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function(){
            if(window.__fc)window.__fc();
            var q=\(qJSON),lq=q.toLowerCase(),ql=q.length;
            var ranges=[];
            var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{
                acceptNode:function(n){
                    var t=n.parentElement&&n.parentElement.tagName;
                    return(t==='SCRIPT'||t==='STYLE'||t==='NOSCRIPT')
                        ?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_ACCEPT;
                }
            });
            var node;
            while(node=walker.nextNode()){
                var txt=node.textContent.toLowerCase(),idx=0;
                while((idx=txt.indexOf(lq,idx))!==-1){
                    var r=document.createRange();
                    r.setStart(node,idx);r.setEnd(node,idx+ql);
                    ranges.push(r);idx++;
                }
            }
            var marks=[];
            for(var i=ranges.length-1;i>=0;i--){
                try{
                    var m=document.createElement('mark');
                    m.setAttribute('data-find','');
                    m.style.cssText='background:rgba(255,213,0,0.55);color:inherit;border-radius:2px;padding:0;';
                    ranges[i].surroundContents(m);
                    marks.unshift(m);
                }catch(e){}
            }
            var cur=0;
            function hl(i){
                marks.forEach(function(m,j){
                    m.style.background=j===i?'rgba(255,120,0,0.85)':'rgba(255,213,0,0.55)';
                });
                if(marks[i])marks[i].scrollIntoView({block:'center',behavior:'smooth'});
            }
            if(marks.length)hl(0);
            window.__fn=function(){if(!marks.length)return;cur=(cur+1)%marks.length;hl(cur);};
            window.__fp=function(){if(!marks.length)return;cur=(cur-1+marks.length)%marks.length;hl(cur);};
            window.__fc=function(){
                marks.forEach(function(m){
                    var p=m.parentNode;
                    if(p){
                        p.replaceChild(document.createTextNode(m.textContent),m);
                        p.normalize();
                    }
                });
                delete window.__fn;delete window.__fp;delete window.__fc;
            };
            return marks.length;
        })()
        """
    }

    func initFind(_ query: String, completion: @escaping (Int) -> Void) {
        guard !query.isEmpty, let js = Self.findJS(for: query) else { clearFind(); completion(0); return }
        let v = ProvidersVisibility.shared
        let webViews: [WKWebView] = [
            v.showChatGPT ? chatGPTView : nil,
            v.showClaude  ? claudeView  : nil,
            v.showGemini  ? geminiView  : nil
        ].compactMap { $0 }
        var total = 0
        let group = DispatchGroup()
        for wv in webViews {
            group.enter()
            wv.evaluateJavaScript(js) { result, error in
                if let error { print("[Find] JS error: \(error)") }
                if let n = result as? Int { total += n }
                else { print("[Find] unexpected result: \(String(describing: result))") }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(total) }
    }

    func navigateFind(forward: Bool) {
        let js = forward ? "if(window.__fn)window.__fn();" : "if(window.__fp)window.__fp();"
        let v = ProvidersVisibility.shared
        if v.showChatGPT { chatGPTView.evaluateJavaScript(js, completionHandler: nil) }
        if v.showClaude  { claudeView.evaluateJavaScript(js, completionHandler: nil) }
        if v.showGemini  { geminiView.evaluateJavaScript(js, completionHandler: nil) }
    }

    func clearFind() {
        let js = "if(window.__fc)window.__fc();"
        for wv in [chatGPTView, claudeView, geminiView] {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - Custom multi-line input

struct MultilineInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var onSubmit: () -> Void
    var onPasteAttachments: ([ChatAttachment]) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let tv = PaddedTextView()
        tv.delegate = context.coordinator
        tv.onPasteAttachments = { atts in
            DispatchQueue.main.async { onPasteAttachments(atts) }
        }
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.textContainer?.widthTracksTextView = true
        tv.placeholderString = placeholder

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PaddedTextView else { return }
        if tv.string != text { tv.string = text }
        tv.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInput
        init(_ parent: MultilineInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false // let NSTextView insert a newline
                }
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

final class PaddedTextView: NSTextView {
    var placeholderString: String = "" { didSet { needsDisplay = true } }
    var onPasteAttachments: (([ChatAttachment]) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 2, y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.shift) == false {
            switch event.charactersIgnoringModifiers {
            case "v": paste(nil); return
            case "x": cut(nil); return
            case "c": copy(nil); return
            case "a": selectAll(nil); return
            case "z": undoManager?.undo(); return
            default: break
            }
        }
        if event.modifierFlags.contains([.command, .shift]),
           event.charactersIgnoringModifiers == "z" {
            undoManager?.redo(); return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if let type = pb.availableType(from: imageTypes), let data = pb.data(forType: type) {
            let (bytes, mime, ext) = PaddedTextView.normalizeImageData(data, type: type)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).\(ext)")
            try? bytes.write(to: tmp)
            onPasteAttachments?([ChatAttachment(url: tmp, data: bytes, mimeType: mime)])
            return
        }

        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            let atts = urls.compactMap { ChatAttachment.load(from: $0) }
            if !atts.isEmpty {
                onPasteAttachments?(atts)
                return
            }
        }

        super.paste(sender)
    }

    static func normalizeImageData(_ data: Data, type: NSPasteboard.PasteboardType) -> (Data, String, String) {
        if type == .png { return (data, "image/png", "png") }
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "image/png", "png")
        }
        return (data, "image/tiff", "tiff")
    }
}

// MARK: - Find-in-page state

@MainActor
final class FindController: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var matchCount = 0
    private var eventMonitor: Any?

    func install() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "f" {
                Task { @MainActor in self.isVisible = true }
                return nil
            }
            if event.keyCode == 53, self.isVisible {
                Task { @MainActor in
                    self.isVisible = false
                    self.query = ""
                }
                return nil
            }
            return event
        }
    }

    func uninstall() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
    }
}

// MARK: - Main view

struct ProviderWebAuthView: View {
    @StateObject private var controller   = DualChatController()
    @StateObject private var visibility   = ProvidersVisibility.shared
    @StateObject private var usageService = UsageService.shared
    @StateObject private var sessionStore = ChatSessionStore.shared
    @StateObject private var find = FindController()
    @State private var inputText: String  = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var isDropTargeted: Bool = false
    @State private var isFullScreen: Bool   = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                HSplitView {
                    if visibility.showChatGPT {
                        VStack(spacing: 0) {
                            HeaderBar(title: "ChatGPT", windows: usageService.chatGptWindows, isFullScreen: isFullScreen)
                            WebViewHost(webView: controller.chatGPTView)
                        }
                    }
                    if visibility.showClaude {
                        VStack(spacing: 0) {
                            HeaderBar(title: "Claude", windows: usageService.claudeWindows, isFullScreen: isFullScreen)
                            WebViewHost(webView: controller.claudeView)
                        }
                    }
                    if visibility.showGemini {
                        VStack(spacing: 0) {
                            HeaderBar(title: "Gemini", windows: usageService.geminiWindows, isFullScreen: isFullScreen)
                            WebViewHost(webView: controller.geminiView)
                        }
                    }
                }
                .id(splitterKey)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                    isFullScreen = true
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                    isFullScreen = false
                }

                Divider()

                VStack(spacing: 6) {
                    SessionBar(controller: controller, sessionStore: sessionStore)

                    if !attachments.isEmpty {
                        AttachmentChipBar(attachments: $attachments)
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        Button(action: pickFiles) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.borderless)
                        .help("Attach files")

                        MultilineInput(text: $inputText,
                                       placeholder: "Ask all enabled chats…",
                                       onSubmit: send,
                                       onPasteAttachments: { atts in attachments.append(contentsOf: atts) })
                            .frame(minHeight: 36, maxHeight: 140)

                        Button("Send", action: send)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(canSend == false)
                    }
                }
                .padding(10)
                .background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
            }
            .frame(minWidth: 1500, minHeight: 700)

            if find.isVisible {
                FindBar(
                    query: $find.query,
                    matchCount: find.matchCount,
                    onNext: { controller.navigateFind(forward: true) },
                    onPrevious: { controller.navigateFind(forward: false) },
                    onDismiss: {
                        find.isVisible = false
                        find.query = ""
                        controller.clearFind()
                    }
                )
                .padding(12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: find.isVisible)
        .onAppear { setupSessionCapture(); find.install() }
        .onDisappear { find.uninstall() }
        .onChange(of: find.isVisible) { visible in
            if !visible { controller.clearFind() }
        }
        .onChange(of: find.query) { query in
            controller.initFind(query) { find.matchCount = $0 }
        }
    }

    private var splitterKey: String {
        "\(visibility.showChatGPT)-\(visibility.showClaude)-\(visibility.showGemini)"
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.send(text: text, attachments: attachments)

        // Auto-save a new session named after the message, triggered reactively when URLs change
        if !text.isEmpty && sessionStore.activeSessionID == nil {
            let name = String(text.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
            controller.startWatchingForConversationURLs(name: name)
        }

        inputText = ""
        attachments = []
    }

    private func setupSessionCapture() {
        controller.onSessionURLsReady = { [weak sessionStore = sessionStore] name, chatGPT, claude, gemini in
            guard let store = sessionStore else { return }
            store.saveNewSession(name: name, chatGPTURL: chatGPT, claudeURL: claude, geminiURL: gemini)
            print("[Session] saved '\(name)'")
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let att = ChatAttachment.load(from: url) { attachments.append(att) }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, let att = ChatAttachment.load(from: url) else { return }
                DispatchQueue.main.async { attachments.append(att) }
            }
        }
        return handled
    }
}

// MARK: - Subviews

private struct SessionManageView: View {
    @ObservedObject var sessionStore: ChatSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved Sessions")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if sessionStore.sessions.isEmpty {
                Text("No saved sessions")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(12)
            } else {
                ForEach(sessionStore.sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).lineLimit(1)
                            Text([session.chatGPTURL, session.claudeURL, session.geminiURL]
                                .compactMap { $0 }
                                .first ?? "no URLs")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            sessionStore.delete(id: session.id)
                        } label: {
                            Image(systemName: "trash").foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        }
        .frame(minWidth: 340)
    }
}

private struct SaveSessionPopover: View {
    @ObservedObject var controller: DualChatController
    @ObservedObject var sessionStore: ChatSessionStore
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save Current Session").font(.headline)
            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.escape, modifiers: [])
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        sessionStore.saveNewSession(
            name: trimmed,
            chatGPTURL: controller.chatGPTCurrentURL,
            claudeURL:  controller.claudeCurrentURL,
            geminiURL:  controller.geminiCurrentURL
        )
        isPresented = false
    }
}

private struct SessionBar: View {
    @ObservedObject var controller: DualChatController
    @ObservedObject var sessionStore: ChatSessionStore
    @State private var showingManage = false
    @State private var showingSave = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            Picker("", selection: Binding(
                get: { sessionStore.activeSessionID },
                set: { id in
                    print("[Picker] selected id: \(id?.uuidString ?? "nil"), current: \(sessionStore.activeSessionID?.uuidString ?? "nil")")
                    guard id != sessionStore.activeSessionID else { return }
                    sessionStore.setActive(id: id)
                    if let id, let session = sessionStore.sessions.first(where: { $0.id == id }) {
                        controller.navigate(to: session)
                    }
                }
            )) {
                Text("— no session —").tag(nil as UUID?)
                if !sessionStore.sessions.isEmpty {
                    Divider()
                    ForEach(sessionStore.sessions) { session in
                        Text(session.name).tag(session.id as UUID?)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            .labelsHidden()

            Button {
                sessionStore.setActive(id: nil)
                controller.navigateToHomepages()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Start a new chat and clear session selection")

            Button {
                showingSave.toggle()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Save current chats as a named session")
            .popover(isPresented: $showingSave, arrowEdge: .bottom) {
                SaveSessionPopover(controller: controller, sessionStore: sessionStore,
                                   isPresented: $showingSave)
            }

            Button {
                showingManage.toggle()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Manage saved sessions")
            .popover(isPresented: $showingManage, arrowEdge: .bottom) {
                SessionManageView(sessionStore: sessionStore)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct HeaderBar: View {
    let title: String
    var windows: [UsageWindow] = []
    var isFullScreen: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            if isFullScreen && !windows.isEmpty {
                ForEach(windows) { w in
                    Text(w.resetsAt.map { "\(w.label): \(w.percentRemaining)% · resets \(formatReset($0))" } ?? "\(w.label): \(w.percentRemaining)%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(w.percentRemaining < 20 ? .orange : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                        .cornerRadius(4)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func formatReset(_ date: Date) -> String { formatResetDate(date) }
}

private struct FindBar: View {
    @Binding var query: String
    let matchCount: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find in page…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($focused)
                .onSubmit { onNext() }

            if !query.isEmpty {
                Text(matchCount == 0 ? "No results" : "\(matchCount) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .leading)
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(query.isEmpty || matchCount == 0)
            .help("Previous match (⌘⇧G)")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(query.isEmpty || matchCount == 0)
            .help("Next match (⌘G)")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .onAppear { focused = true }
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Single-provider auth view

final class AuthWebController: NSObject, ObservableObject, WKUIDelegate {
    let webView: WKWebView
    private var popupWebView: WKWebView?
    private var popupWindow: NSWindow?

    init(url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Suppress Google One Tap auto-prompt but allow the full Google library to load
        let suppressOneTap = WKUserScript(
            source: """
            (function() {
                var _google;
                Object.defineProperty(window, 'google', {
                    configurable: true,
                    get: function() { return _google; },
                    set: function(v) {
                        _google = v;
                        if (_google && _google.accounts && _google.accounts.id) {
                            _google.accounts.id.prompt = function() {};
                        }
                    }
                });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(suppressOneTap)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        super.init()
        webView.uiDelegate = self
        webView.load(URLRequest(url: url))
    }

    // Open OAuth popups (e.g. Google Sign-In) in a real window so they're visible and functional
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 640), configuration: configuration)
        popup.uiDelegate = self
        popupWebView = popup

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in with Google"
        window.contentView = popup
        window.center()
        window.isReleasedWhenClosed = false
        popupWindow = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView {
            popupWindow?.close()
            popupWindow = nil
            popupWebView = nil
        }
    }
}

struct ProviderAuthView: View {
    let provider: AuthProvider
    let onComplete: () -> Void

    @StateObject private var webController: AuthWebController
    @StateObject private var usageService = UsageService.shared
    @State private var pollTimer: Timer?

    init(provider: AuthProvider, onComplete: @escaping () -> Void) {
        self.provider = provider
        self.onComplete = onComplete
        _webController = StateObject(wrappedValue: AuthWebController(url: provider.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to \(provider.name)").font(.headline)
                Spacer()
                Button("Cancel") { finish() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            WebViewHost(webView: webController.webView)
        }
        .frame(minWidth: 480, minHeight: 640)
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                UsageService.shared.fetchAllUsages()
            }
        }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
        .onReceive(usageService.objectWillChange) { _ in
            DispatchQueue.main.async { if isLoggedIn { finish() } }
        }
    }

    private var isLoggedIn: Bool {
        switch provider {
        case .chatGPT: return usageService.chatGptError == nil && !usageService.chatGptWindows.isEmpty
        case .claude:  return usageService.claudeError  == nil && !usageService.claudeWindows.isEmpty
        }
    }

    private func finish() {
        pollTimer?.invalidate()
        pollTimer = nil
        onComplete()
    }
}

// MARK: - Gemini OAuth webview (intercepts redirect to extract code)

final class GeminiAuthWebController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private let verifier: String
    var onComplete: (() -> Void)?

    override init() {
        verifier = Self.generateVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView = wv
        super.init()
        webView.navigationDelegate = self

        let scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"),
            URLQueryItem(name: "redirect_uri",           value: "https://codeassist.google.com/authcode"),
            URLQueryItem(name: "response_type",          value: "code"),
            URLQueryItem(name: "scope",                  value: scopes),
            URLQueryItem(name: "access_type",            value: "offline"),
            URLQueryItem(name: "prompt",                 value: "consent"),
            URLQueryItem(name: "code_challenge",         value: challenge),
            URLQueryItem(name: "code_challenge_method",  value: "S256"),
        ]
        webView.load(URLRequest(url: comps.url!))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url,
              url.host == "codeassist.google.com",
              url.path == "/authcode",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" })?.value
        else { decisionHandler(.allow); return }

        decisionHandler(.cancel)
        UsageService.shared.handleOAuthCode(code, verifier: verifier)
        onComplete?()
    }

    private static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return verifier }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct GeminiAuthView: View {
    let onComplete: () -> Void
    @StateObject private var controller = GeminiAuthWebController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Gemini").font(.headline)
                Spacer()
                Button("Cancel") { onComplete() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            WebViewHost(webView: controller.webView)
        }
        .frame(minWidth: 480, minHeight: 640)
        .onAppear {
            controller.onComplete = {
                DispatchQueue.main.async {
                    UsageService.shared.fetchAllUsages()
                    onComplete()
                }
            }
        }
    }
}

private struct AttachmentChipBar: View {
    @Binding var attachments: [ChatAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { att in
                    HStack(spacing: 4) {
                        Image(systemName: iconName(for: att.mimeType))
                        Text(att.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160)
                        Button {
                            attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.15))
                    )
                }
            }
        }
    }

    private func iconName(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}
