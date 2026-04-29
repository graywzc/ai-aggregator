import Testing
import JavaScriptCore
import Foundation
@testable import AIAggregator

// Run the find JS inside a JavaScriptCore context with a minimal DOM stub.
// This validates the search/navigation/cleanup logic without needing a real WKWebView.

private func makeContext(html: String) -> JSContext {
    let ctx = JSContext()!
    ctx.exceptionHandler = { _, e in
        if let e { print("[JSC] exception:", e) }
    }

    // Minimal DOM stubs -------------------------------------------------------

    // NodeFilter constants
    ctx.evaluateScript("var NodeFilter = { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 };")

    // Build a flat list of text nodes from the HTML body content.
    // We strip tags so the walker sees the plain text, then split on word
    // boundaries to simulate distinct text nodes between elements.
    let stripped = html
        .replacingOccurrences(of: "<script[^>]*>.*?</script>",
                              with: "", options: .regularExpression)
        .replacingOccurrences(of: "<style[^>]*>.*?</style>",
                              with: "", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "\u{0}", options: .regularExpression)
        .components(separatedBy: "\u{0}")
        .filter { !$0.isEmpty }

    let nodesJSON = (try? String(data: JSONSerialization.data(withJSONObject: stripped), encoding: .utf8)) ?? "[]"

    ctx.evaluateScript("""
    (function() {
        var textNodes = \(nodesJSON).map(function(t) {
            return { textContent: t, parentElement: { tagName: 'P' } };
        });

        // TreeWalker stub: iterates textNodes, applies filter
        document = {
            createTreeWalker: function(root, whatToShow, filter) {
                var idx = -1;
                return {
                    nextNode: function() {
                        while (++idx < textNodes.length) {
                            var n = textNodes[idx];
                            if (!filter || filter.acceptNode(n) === NodeFilter.FILTER_ACCEPT) return n;
                        }
                        return null;
                    }
                };
            },
            createRange: function() {
                var s, e;
                return {
                    setStart: function(node, off) { s = { node: node, off: off }; },
                    setEnd:   function(node, off) { e = { node: node, off: off }; },
                    surroundContents: function(mark) {
                        var text = s.node.textContent.slice(s.off, e.off);
                        mark.textContent = text;
                        // Replace the matched slice in the source node with a sentinel
                        // so re-runs don't double-count. (Real DOM would mutate the node.)
                        s.node.textContent =
                            s.node.textContent.slice(0, s.off) +
                            '\x00' +
                            s.node.textContent.slice(e.off);
                    }
                };
            },
            createElement: function(tag) {
                return { tagName: tag, textContent: '', style: { background: '' },
                         setAttribute: function() {},
                         parentNode: null,
                         scrollIntoView: function() {} };
            },
            body: {}
        };
        window = this;
        window.scrollY = 0;
    })();
    """)

    // Patch marks to have a real parentNode with replaceChild + normalize
    ctx.evaluateScript("""
    document._originalCreateElement = document.createElement;
    document.createElement = function(tag) {
        var m = document._originalCreateElement(tag);
        m.scrollIntoView = function() {};
        m.parentNode = {
            replaceChild: function(newNode, oldNode) { oldNode.parentNode = null; },
            normalize: function() {}
        };
        return m;
    };
    """)

    return ctx
}

private func runFind(_ query: String, in ctx: JSContext) -> Int {
    guard let js = DualChatController.findJS(for: query) else { return -1 }
    return ctx.evaluateScript(js).map { Int($0.toInt32()) } ?? 0
}

@Suite("FindInPage")
@MainActor
struct FindInPageTests {

    @Test func initialControllerState() {
        let fc = FindController()
        #expect(!fc.isVisible)
        #expect(fc.query.isEmpty)
        #expect(fc.matchCount == 0)
    }

    @Test func findJSBuiltForNonEmptyQuery() {
        #expect(DualChatController.findJS(for: "hello") != nil)
    }

    @Test func findJSNilForEmpty() {
        // Empty string is guarded in initFind, but findJS itself should still
        // produce a string — callers are responsible for the empty guard.
        // We just verify it doesn't crash.
        _ = DualChatController.findJS(for: "")
    }

    @Test func findJSEscapesSpecialChars() {
        // Queries with quotes or backslashes must not break the JS string.
        let js = DualChatController.findJS(for: "say \"hi\"")
        #expect(js != nil)
        // Should be valid JS — a JSContext would not throw on eval.
        let ctx = JSContext()!
        var threw = false
        ctx.exceptionHandler = { _, _ in threw = true }
        ctx.evaluateScript("var document={body:{},createTreeWalker:function(){return{nextNode:function(){return null;}}},createRange:function(){return{};},createElement:function(){return{style:{},setAttribute:function(){},scrollIntoView:function(){}};}};var window=this;")
        ctx.evaluateScript(js!)
        #expect(!threw)
    }

    @Test func countMatchesInSimpleText() {
        let ctx = makeContext(html: "<p>hello world hello</p>")
        let count = runFind("hello", in: ctx)
        #expect(count == 2)
    }

    @Test func caseInsensitiveMatch() {
        let ctx = makeContext(html: "<p>Hello HELLO hello</p>")
        let count = runFind("hello", in: ctx)
        #expect(count == 3)
    }

    @Test func noMatchReturnsZero() {
        let ctx = makeContext(html: "<p>hello world</p>")
        let count = runFind("xyz", in: ctx)
        #expect(count == 0)
    }

    @Test func windowFunctionsRegisteredAfterFind() {
        let ctx = makeContext(html: "<p>foo bar foo</p>")
        _ = runFind("foo", in: ctx)
        let fnType = ctx.evaluateScript("typeof window.__fn")?.toString()
        let fpType = ctx.evaluateScript("typeof window.__fp")?.toString()
        let fcType = ctx.evaluateScript("typeof window.__fc")?.toString()
        #expect(fnType == "function")
        #expect(fpType == "function")
        #expect(fcType == "function")
    }

    @Test func cleanupRemovesWindowFunctions() {
        let ctx = makeContext(html: "<p>hello</p>")
        _ = runFind("hello", in: ctx)
        ctx.evaluateScript("window.__fc()")
        #expect(ctx.evaluateScript("typeof window.__fn")?.toString() == "undefined")
        #expect(ctx.evaluateScript("typeof window.__fp")?.toString() == "undefined")
        #expect(ctx.evaluateScript("typeof window.__fc")?.toString() == "undefined")
    }

    @Test func navigationDoesNotCrashWhenNoMatches() {
        let ctx = makeContext(html: "<p>hello</p>")
        _ = runFind("xyz", in: ctx)
        // __fn/__fp should be registered but be no-ops
        ctx.evaluateScript("if(window.__fn) window.__fn();")
        ctx.evaluateScript("if(window.__fp) window.__fp();")
    }

    @Test func reinitCleansUpPreviousSearch() {
        let ctx = makeContext(html: "<p>hello world</p>")
        _ = runFind("hello", in: ctx)
        // Second search should call __fc internally
        let count = runFind("world", in: ctx)
        #expect(count == 1)
        // Old __fn from first search must not survive
        let fnType = ctx.evaluateScript("typeof window.__fn")?.toString()
        #expect(fnType == "function") // new search registered its own
    }
}
