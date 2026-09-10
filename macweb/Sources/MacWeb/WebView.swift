import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "macweb")
        userContent.addUserScript(
            WKUserScript(source: MonitorScript.source,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // WKWebView 默认 UA 不含 Safari/Version 标识，部分站点（如百度）会据此下发
        // 反复 http/https 跳转的页面，配合 HSTS 形成导航死循环
        webView.customUserAgent = Self.safariUserAgent
        webView.setValue(false, forKey: "drawsBackground")

        model.webView = webView
        context.coordinator.install(webView: webView)
        // 切换面板布局会重建本 representable，恢复上次 URL 而不是回到欢迎页
        if let last = model.lastURL, let scheme = last.scheme,
           ["http", "https"].contains(scheme.lowercased()) {
            webView.load(URLRequest(url: last))
        } else {
            webView.loadHTMLString(Self.welcomeHTML, baseURL: nil)
        }
        return webView
    }

    // 不要在此处写任何 @Published 状态：资源消息高频触发 body 重算，
    // 若在这里回写 ObservableObject 会形成 SwiftUI 更新反馈循环
    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "macweb")
    }

    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    private static let welcomeHTML = #"""
    <!DOCTYPE html>
    <html lang="zh">
    <head><meta charset="utf-8"><style>
      body { font-family: -apple-system, "PingFang SC", sans-serif; height: 100%;
             margin: 0; display: flex; align-items: center; justify-content: center;
             background: #f5f5f7; color: #1d1d1f; }
      .card { text-align: center; }
      h1 { font-size: 28px; margin-bottom: 8px; }
      p { color: #6e6e73; font-size: 15px; margin: 4px 0; }
      code { background: #e8e8ed; padding: 2px 6px; border-radius: 4px; }
    </style></head>
    <body><div class="card">
      <h1>MacWeb 资源监视器</h1>
      <p>在上方地址栏输入网址并回车，页面加载的所有资源</p>
      <p>（文档 / 脚本 / 样式 / 图片 / XHR / Fetch / 字体 / WebSocket 等）会显示在下方面板。</p>
    </div></body></html>
    """#
}

extension WebView {
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let model: AppModel
        weak var webView: WKWebView?
        private var observations: [NSKeyValueObservation] = []

        init(model: AppModel) { self.model = model }

        func install(webView: WKWebView) {
            self.webView = webView
            // KVO 只在值真实变化时回调，避免轮询写 @Published 触发更新循环
            observations.append(
                webView.observe(\.canGoBack) { [weak self] wv, _ in self?.navChanged(wv) }
            )
            observations.append(
                webView.observe(\.canGoForward) { [weak self] wv, _ in self?.navChanged(wv) }
            )
            model.syncNavButtons()
        }

        private func navChanged(_ wv: WKWebView) {
            let back = wv.canGoBack
            let forward = wv.canGoForward
            Task { @MainActor in model.setNavButtons(back: back, forward: forward) }
        }

        // MARK: WKUIDelegate

        // 处理 target="_blank" 链接和 window.open：默认 WKWebView 会静默忽略这类
        // "新窗口"导航，这里改为在当前 webView 中加载，否则点击链接无反应
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            Task { @MainActor in model.handle(message: dict) }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame == true,
               let url = navigationAction.request.url {
                var headers: [String: String] = [:]
                if let h = navigationAction.request.allHTTPHeaderFields { headers = h }
                var body = ""
                if let data = navigationAction.request.httpBody {
                    body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                }
                let method = navigationAction.request.httpMethod ?? "GET"
                Task { @MainActor in model.documentRequest(url: url, method: method, headers: headers, body: body) }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let url = navigationResponse.response.url,
               let http = navigationResponse.response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headers[String(describing: k)] = String(describing: v)
                }
                Task { @MainActor in
                    model.documentResponse(url: url, status: http.statusCode, mimeType: http.mimeType ?? "", headers: headers)
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            Task { @MainActor in model.beginNavigation(url: url) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url
            let title = webView.title
            Task { @MainActor in model.finishNavigation(url: url, title: title) }
            autofillJenkinsLogin(webView)
            if let url {
                webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML.slice(0, 200000) : ''") { [weak self] result, _ in
                    let html = result as? String ?? ""
                    Task { @MainActor in self?.model.documentBody(url: url, body: html) }
                }
            }
        }

        // Jenkins 登录页自动填入用户名（本机调试用）
        private func autofillJenkinsLogin(_ webView: WKWebView) {
            guard let url = webView.url,
                  (url.host == "127.0.0.1" || url.host == "localhost"),
                  url.port == 8080,
                  url.path == "/login" else { return }
            webView.evaluateJavaScript(
                "document.getElementById('j_username').value = 'android';" +
                "document.getElementById('j_password').value = 'android'",
                completionHandler: nil
            )
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let url = webView.url
            let title = webView.title
            Task { @MainActor in model.finishNavigation(url: url, title: title) }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            let url = webView.url
            let title = webView.title
            Task { @MainActor in model.finishNavigation(url: url, title: title) }
        }
    }
}
