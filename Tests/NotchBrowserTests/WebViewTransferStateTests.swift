import AppKit
import WebKit
import XCTest
@testable import NotchBrowser

final class WebViewTransferStateTests: XCTestCase {
    func testCompletionGateIgnoresLateCallbacks() {
        let gate = WebTransferCompletionGate()
        var count = 0
        gate.run { count += 1 } // timeout wins
        gate.run { count += 1 } // late WebKit callback
        XCTAssertEqual(count, 1)
    }

    @MainActor
    private func localPage(_ html: String) async -> (WKWebView, NSWindow) {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        let loaded = expectation(description: "Selection fixture loaded")
        let delegate = Navigation(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        withExtendedLifetime(delegate) {}
        return (web, window)
    }

    @MainActor
    func testNativeResponderAndInputSelectionSurviveMovingToAnotherWindow() async throws {
        let (web, source) = await localPage("<input id='input' value='abcdefgh'>")
        source.makeKeyAndOrderFront(nil)
        XCTAssertTrue(source.makeFirstResponder(web))
        _ = try await web.evaluateJavaScript("document.getElementById('input').focus(); document.getElementById('input').setSelectionRange(2,5,'backward')")
        let focus = WebTransferResponderState(webView: web, sourceWindow: source)
        _ = try await web.evaluateJavaScript(WebViewTransferState.capture, in: nil, contentWorld: .defaultClient)
        let target = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        defer { target.orderOut(nil); source.orderOut(nil) }
        source.contentView = nil
        target.contentView = web
        target.makeKeyAndOrderFront(nil)
        let restoreFocus = focus.restore(to: target, contentVisible: true)
        XCTAssertTrue(restoreFocus)
        _ = try await web.callAsyncJavaScript(WebViewTransferState.restore, arguments: ["restoreFocus": restoreFocus], in: nil, contentWorld: .defaultClient)
        let responder = try XCTUnwrap(target.firstResponder as? NSView)
        XCTAssertTrue(responder === web || responder.isDescendant(of: web))
        let selection = try await web.evaluateJavaScript("[document.activeElement.selectionStart,document.activeElement.selectionEnd,document.activeElement.selectionDirection].join(':')") as? String
        XCTAssertEqual(selection, "2:5:backward")
    }

    @MainActor
    func testNonWebFieldEditorIsRestoredWithoutWebFocus() throws {
        _ = NSApplication.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        field.stringValue = "abcdefgh"
        let web = WKWebView(frame: NSRect(x: 0, y: 40, width: 600, height: 360))
        root.addSubview(web)
        root.addSubview(field)
        let source = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let target = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        target.isReleasedWhenClosed = false
        defer { source.orderOut(nil); target.orderOut(nil) }
        source.contentView = root
        source.makeKeyAndOrderFront(nil)
        XCTAssertTrue(source.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let focus = WebTransferResponderState(webView: web, sourceWindow: source)
        source.contentView = nil
        target.contentView = root
        target.makeKeyAndOrderFront(nil)
        XCTAssertFalse(focus.restore(to: target, contentVisible: true))
        let restored = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(target.firstResponder === restored)
        XCTAssertEqual(restored.selectedRange(), NSRange(location: 2, length: 3))
    }

    @MainActor
    func testInputCaretPartialSelectionDirectionAndTextareaAreRestored() async throws {
        let (web, window) = await localPage("<input id='input' value='abcdefgh'><textarea id='area'>abcdefgh</textarea>")
        defer { window.orderOut(nil) }
        for (id, start, end, direction) in [("input", 3, 3, "forward"), ("input", 2, 6, "backward"), ("area", 1, 5, "forward")] {
            _ = try await web.callAsyncJavaScript("const e=document.getElementById(id); e.focus(); e.setSelectionRange(start,end,direction)",
                                                  arguments: ["id": id, "start": start, "end": end, "direction": direction], in: nil, contentWorld: .defaultClient)
            _ = try await web.evaluateJavaScript(WebViewTransferState.capture, in: nil, contentWorld: .defaultClient)
            _ = try await web.evaluateJavaScript("document.activeElement.select()")
            _ = try await web.callAsyncJavaScript(WebViewTransferState.restore, arguments: ["restoreFocus": true], in: nil, contentWorld: .defaultClient)
            let result = try await web.evaluateJavaScript("[document.activeElement.selectionStart,document.activeElement.selectionEnd,document.activeElement.selectionDirection].join(':')") as? String
            XCTAssertEqual(result, "\(start):\(end):\(direction)")
        }
    }

    @MainActor
    func testBackwardContenteditableSelectionIsRestoredAcrossNodes() async throws {
        let (web, window) = await localPage("<div id='edit' contenteditable><span id='a'>abcd</span><span id='b'>efgh</span></div>")
        defer { window.orderOut(nil) }
        _ = try await web.evaluateJavaScript("document.getElementById('edit').focus(); window.getSelection().setBaseAndExtent(document.getElementById('b').firstChild,3,document.getElementById('a').firstChild,1)")
        _ = try await web.evaluateJavaScript(WebViewTransferState.capture, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("window.getSelection().selectAllChildren(document.getElementById('edit'))")
        _ = try await web.callAsyncJavaScript(WebViewTransferState.restore, arguments: ["restoreFocus": true], in: nil, contentWorld: .defaultClient)
        let result = try await web.evaluateJavaScript("(()=>{const s=window.getSelection();return [s.anchorNode.parentElement.id,s.anchorOffset,s.focusNode.parentElement.id,s.focusOffset].join(':')})()") as? String
        XCTAssertEqual(result, "b:3:a:1")
    }
    private final class Navigation: NSObject, WKNavigationDelegate {
        let finished: XCTestExpectation
        init(_ finished: XCTestExpectation) { self.finished = finished }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
    }

    @MainActor
    func testAnchorAndFocusedFormSurviveReflowAndScrollJump() async throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 500))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let loaded = expectation(description: "Local HTML loaded")
        let navigation = Navigation(loaded)
        web.navigationDelegate = navigation
        let paragraphs = (0..<80).map { "<p id='p\($0)'>\(String(repeating: "リフローしても見ていた段落を保ちます。", count: 30))</p>" }.joined()
        web.loadHTMLString("<html><body><input id='form' value='入力中'>\(paragraphs)</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await web.evaluateJavaScript("document.getElementById('form').focus({preventScroll:true}); window.scrollTo(0, document.getElementById('p20').offsetTop + 12)")
        _ = try await web.evaluateJavaScript(WebViewTransferState.capture, in: nil, contentWorld: .defaultClient)
        let anchorValue = try await web.evaluateJavaScript("globalThis.__notchTransfer.anchor.id", in: nil, contentWorld: .defaultClient)
        let anchor = try XCTUnwrap(anchorValue as? String)
        let offsetValue = try await web.evaluateJavaScript("globalThis.__notchTransfer.offset", in: nil, contentWorld: .defaultClient)
        let offset = try XCTUnwrap(offsetValue as? Double)
        window.setContentSize(NSSize(width: 1000, height: 500))
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 0)")
        _ = try await web.callAsyncJavaScript(WebViewTransferState.restore, arguments: ["restoreFocus": true], in: nil, contentWorld: .defaultClient)
        let restoredValue = try await web.callAsyncJavaScript("return document.getElementById(id).getBoundingClientRect().top", arguments: ["id": anchor], in: nil, contentWorld: .defaultClient)
        let restored = try XCTUnwrap(restoredValue as? Double)
        XCTAssertEqual(restored, offset, accuracy: 2)
        let active = try await web.evaluateJavaScript("document.activeElement.id + ':' + document.activeElement.value") as? String
        XCTAssertEqual(active, "form:入力中")
        XCTAssertFalse(web.isLoading)
        let savedY = try await web.evaluateJavaScript("window.scrollY") as? Double
        _ = try await web.evaluateJavaScript(WebViewTransferState.capture, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("globalThis.__notchTransfer.anchor.remove(); window.scrollTo(0, 0)", in: nil, contentWorld: .defaultClient)
        _ = try await web.callAsyncJavaScript(WebViewTransferState.restore, arguments: ["restoreFocus": false], in: nil, contentWorld: .defaultClient)
        let fallbackY = try await web.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(try XCTUnwrap(fallbackY), try XCTUnwrap(savedY), accuracy: 2)
    }
}
