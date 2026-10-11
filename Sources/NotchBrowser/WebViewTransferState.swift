import AppKit
import WebKit

struct WebTransferResponderState {
    private let webView: WKWebView?
    private let responder: NSResponder?
    private let sourceWindow: NSWindow?
    private let field: NSView?
    private let fieldSelection: NSRange?
    private let shouldFocusWeb: Bool

    init(webView: WKWebView?, sourceWindow: NSWindow?, fallbackToContent: Bool = false) {
        self.webView = webView
        self.sourceWindow = sourceWindow
        responder = sourceWindow?.firstResponder
        let editor = responder as? NSTextView
        field = editor?.isFieldEditor == true ? editor?.delegate as? NSView : nil
        fieldSelection = editor?.isFieldEditor == true ? editor?.selectedRange() : nil
        let nativeView = responder as? NSView
        shouldFocusWeb = fallbackToContent || (webView.map { web in
            nativeView.map { $0 === web || $0.isDescendant(of: web) } ?? false
        } ?? false)
    }

    /// Native focus must precede DOM focus/selection restoration: WebKit may select all here.
    func restore(to window: NSWindow?, contentVisible: Bool) -> Bool {
        if shouldFocusWeb {
            guard contentVisible, let webView else { return false }
            return window?.makeFirstResponder(webView) == true
        }
        if let field, let owner = field.window {
            owner.makeFirstResponder(field)
            if let selection = fieldSelection, let control = field as? NSControl {
                (control.currentEditor() as? NSTextView)?.setSelectedRange(selection)
            }
        } else if let responder {
            let owner = (responder as? NSView)?.window ?? sourceWindow
            owner?.makeFirstResponder(responder)
        }
        return false
    }
}

/// References live only in WebKit's isolated client world, keeping the same DOM nodes
/// across reparenting without changing the page, URL or form values.
enum WebViewTransferState {
    static let capture = #"""
    (() => {
        let anchor = null;
        for (const y of [8, 32, 64, 112]) {
            for (const fraction of [0.3, 0.6, 0.1]) {
                let candidate = document.elementFromPoint(Math.max(1, window.innerWidth * fraction), y);
                let floating = false;
                for (let node = candidate; node; node = node.parentElement) {
                    if (['fixed', 'sticky'].includes(getComputedStyle(node).position)) { floating = true; break; }
                }
                if (floating || !candidate) continue;
                candidate = candidate.closest('p,li,h1,h2,h3,h4,td,pre,blockquote') || candidate;
                if (candidate !== document.body && candidate !== document.documentElement) { anchor = candidate; break; }
            }
            if (anchor) break;
        }
        const active = document.activeElement;
        let textSelection = null, editableSelection = null;
        if (active && /^(INPUT|TEXTAREA)$/.test(active.tagName)) {
            try {
                if (typeof active.selectionStart === 'number')
                    textSelection = {start: active.selectionStart, end: active.selectionEnd, direction: active.selectionDirection};
            } catch (_) {}
        } else if (active && active.isContentEditable) {
            const selection = window.getSelection();
            if (selection && selection.anchorNode && selection.focusNode)
                editableSelection = {anchorNode: selection.anchorNode, anchorOffset: selection.anchorOffset,
                                     focusNode: selection.focusNode, focusOffset: selection.focusOffset};
        }
        globalThis.__notchTransfer = {
            anchor, offset: anchor ? anchor.getBoundingClientRect().top : 0,
            x: window.scrollX, y: window.scrollY, active, textSelection, editableSelection
        };
    })();
    """#

    static let restore = #"""
    const state = globalThis.__notchTransfer;
    if (!state) return;
    return await new Promise(resolve => {
        const apply = () => {
            const y = state.anchor && state.anchor.isConnected
                ? window.scrollY + state.anchor.getBoundingClientRect().top - state.offset : state.y;
            const root = document.documentElement;
            const previous = root.style.scrollBehavior;
            root.style.scrollBehavior = 'auto';
            window.scrollTo({left: state.x, top: y, behavior: 'instant'});
            root.style.scrollBehavior = previous;
        };
        const focusAndSelection = () => {
            if (!restoreFocus || !state.active || !state.active.isConnected) return;
            state.active.focus({preventScroll: true});
            try {
                if (state.textSelection) {
                    const s = state.textSelection;
                    state.active.setSelectionRange(s.start, s.end, s.direction);
                }
                const s = state.editableSelection;
                if (s && s.anchorNode.isConnected && s.focusNode.isConnected)
                    window.getSelection().setBaseAndExtent(s.anchorNode, s.anchorOffset, s.focusNode, s.focusOffset);
            } catch (_) {}
        };
        const finish = () => {
            if (globalThis.__notchTransfer !== state) { resolve(); return; }
            apply();
            focusAndSelection();
            delete globalThis.__notchTransfer;
            resolve();
        };
        // Background WKWebViews may suspend animation frames; still restore their offsets.
        const timeout = setTimeout(finish, 300);
        requestAnimationFrame(() => requestAnimationFrame(() => {
            if (globalThis.__notchTransfer !== state) return;
            apply();
            focusAndSelection();
            requestAnimationFrame(() => requestAnimationFrame(() => {
                clearTimeout(timeout);
                finish();
            }));
        }));
    });
    """#
}

/// Used only on the main queue: a late WebKit callback cannot repeat a timed-out phase.
final class WebTransferCompletionGate {
    private var finished = false
    func run(_ action: () -> Void) {
        guard !finished else { return }
        finished = true
        action()
    }
}
