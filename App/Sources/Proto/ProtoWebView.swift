#if DEBUG
import SwiftUI
import WebKit

// THROWAWAY PROTOTYPE: a real WKWebView on a real page, with no cookies kept
// (WKWebsiteDataStore.nonPersistent) unless asked, zoomed onto the game link a
// scene names, the way a player would pinch onto a desktop page.
struct ProtoWebView: UIViewRepresentable {
    let page: ProtoPage
    var persistent = false
    /// A narrow column on an iPad or an open Duo lays a desktop page out
    /// at its own width unless asked for the mobile layout.
    var mobile = false

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = persistent ? .default() : .nonPersistent()
        if mobile { config.defaultWebpagePreferences.preferredContentMode = .mobile }
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .white
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: page.url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let page: ProtoPage
        private var tries = 0
        private var done = false

        init(page: ProtoPage) { self.page = page }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { self.focus(webView) }
        }

        private func focus(_ webView: WKWebView) {
            guard let selector = page.focus, !done else { return }
            let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let press = page.pressed
                ? "a.style.background='rgba(120,120,128,0.45)';a.style.borderRadius='4px';a.style.boxShadow='0 0 0 3px rgba(120,120,128,0.45)';"
                : ""
            let js = """
            (function(){var a=document.querySelector('\(escaped)');if(!a){return null;}
            \(press)
            var r=a.getBoundingClientRect();
            return [r.left+window.scrollX, r.top+window.scrollY, r.width, r.height, document.documentElement.scrollWidth];})()
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                guard let r = result as? [Double], r.count == 5 else {
                    self.tries += 1
                    if self.tries < 60 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.focus(webView) }
                    }
                    return
                }
                self.done = true
                // Again once any presentation has settled: a cover still
                // animating in reports the wrong bounds.
                for delay in [1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.zoom(webView, x: r[0], y: r[1], w: r[2], h: r[3], docWidth: r[4])
                    }
                }
            }
        }

        private func zoom(_ webView: WKWebView, x: Double, y: Double, w: Double, h: Double, docWidth: Double) {
            let bounds = webView.bounds.size
            let scroll = webView.scrollView
            var visibleCSSWidth = docWidth
            if docWidth / Double(bounds.width) > 1.6 {
                // A desktop page on a narrow window: zoom the way a pinch would.
                visibleCSSWidth = page.zoomWidth
            }
            let scale = Double(bounds.width) / visibleCSSWidth
            if visibleCSSWidth < docWidth {
                scroll.setZoomScale(CGFloat(scale), animated: false)
            }
            let z = Double(scroll.zoomScale)
            let cx = x + w / 2, cy = y + h / 2
            let insets = scroll.adjustedContentInset
            let visibleHeight = Double(bounds.height - insets.top - insets.bottom)
            var left = cx * z - Double(bounds.width) / 2
            left = min(max(0, left), max(0, docWidth * z - Double(bounds.width)))
            let top = max(-Double(insets.top), cy * z - visibleHeight * 0.45 - Double(insets.top))
            scroll.setContentOffset(CGPoint(x: left, y: top), animated: false)
        }
    }
}
#endif
