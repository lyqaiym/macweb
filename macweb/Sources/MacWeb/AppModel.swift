import Foundation
import Combine
import SwiftUI
import WebKit
import AppKit

private struct PendingDocRequest {
    var url: String
    var method: String
    var headers: [String: String]
    var body: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var resources: [WebResource] = []
    @Published var selected: Set<UUID> = []
    @Published var filterText: String = ""
    @Published var urlText: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var jobSecButtonVisible = false
    @Published var jobSecText = ""

    weak var webView: WKWebView?
    var lastURL: URL?
    private var pendingDocRequest: PendingDocRequest?
    private(set) var cookies: [HTTPCookie] = []

    func loadAddress(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") {
            // 本地开发服务器默认走 http，其余默认 https
            let host = s.split(separator: "/").first.map(String.init) ?? s
            s = (host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1"))
                ? "http://" + s : "https://" + s
        }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return }
        urlText = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    func beginNavigation(url: URL) {
        lastURL = url
        resources.removeAll()
        selected.removeAll()
        urlText = url.absoluteString
        jobSecButtonVisible = false
        jobSecText = ""
        var doc = WebResource(url: url.absoluteString, kind: .document, method: "GET")
        if let req = pendingDocRequest, req.url == url.absoluteString {
            doc.method = req.method
            doc.requestHeaders = req.headers
            doc.requestBody = req.body
            doc.hasRequest = true
            pendingDocRequest = nil
        }
        resources.append(doc)
    }

    func finishNavigation(url: URL?, title: String?) {
        if let url { urlText = url.absoluteString }
        pageTitle = title ?? ""
        syncNavButtons()
        updateJobSecVisibility(url: url)
        refreshCookies()
    }

    func refreshCookies() {
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] list in
            let sorted = list.sorted { $0.name < $1.name }
            Task { @MainActor in self?.cookies = sorted }
        }
    }

    private func updateJobSecVisibility(url: URL?) {
        guard let url else { jobSecButtonVisible = false; return }
        let isMobileDetail = url.host == "m.zhipin.com" && url.path.hasPrefix("/job_detail")
        let isSearchList = url.host == "www.zhipin.com" && url.absoluteString.contains("/geek/jobs?query=")
        let isJob_detail = url.host == "www.zhipin.com" && url.absoluteString.contains("/job_detail/")
        jobSecButtonVisible = isMobileDetail || isSearchList || isJob_detail
    }

    func extractJobSec(completion: @escaping () -> Void = {}) {
        guard let webView else { completion(); return }
        let js = "document.querySelector('.job-sec') ? document.querySelector('.job-sec').innerText : ''"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            let text = (result as? String) ?? ""
            Task { @MainActor in
                if !text.isEmpty { self?.jobSecText = text }
                completion()
            }
        }
    }

    // MARK: - 职位描述：从原始 HTML 响应体抓明文（绕过 mixup 反爬）

    private let htmlFetcher: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// WKWebView 拿不到主文档响应体；mixup 又会把 DOM 文字打乱。
    /// 这里用 URLSession 带同样 Cookie 重新拉取原始 HTML，直接解析明文。
    func fetchRawJobSec(completion: @escaping () -> Void = {}) {
        guard let url = webView?.url ?? lastURL else { completion(); return }
        var request = URLRequest(url: url)
        request.setValue(WebView.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let cookie = WebResource.cookieHeader(for: url, cookies: cookies) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        htmlFetcher.dataTask(with: request) { [weak self] data, _, _ in
            let html = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
            let text = html.flatMap { self?.extractJobSecFromHTML($0) } ?? ""
            Task { @MainActor in
                if !text.isEmpty {
                    self?.jobSecText = text
                    NSLog("[职位描述] 已从原始 HTML 提取 job-sec-text（%d 字符）", text.count)
                }
                completion()
            }
        }.resume()
    }

    private func extractJobSecFromHTML(_ html: String) -> String? {
        // 桌面版：<div class="job-sec-text">…</div>
        if let text = extractFragment(html, opening: #"<div class="job-sec-text"[^>]*>"#) { return text }
        // 移动版：<div class="job-sec">…<div class="text">…</div>
        if let text = extractFragment(html, opening: #"<div class="text"[^>]*>"#) { return text }
        return nil
    }

    private func extractFragment(_ html: String, opening: String) -> String? {
        guard let start = html.range(of: opening, options: .regularExpression) else { return nil }
        let tail = html[start.upperBound...]
        guard let end = tail.range(of: "</div>") else { return nil }
        var fragment = String(tail[..<end.lowerBound])
        // mixup 噪音 span（如 <span>boss</span> / <span>直聘</span>）整段剔除
        fragment = fragment.replacingOccurrences(
            of: #"<span[^>]*>[\s\S]*?</span>"#, with: "", options: .regularExpression
        )
        return decodeHTMLEntities(fragment)
    }

    private func decodeHTMLEntities(_ fragment: String) -> String {
        let data = Data("<body>\(fragment)</body>".utf8)
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
            let s = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        var s = fragment.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&rdquo;", with: "”")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 文档（主页面导航）的请求/响应捕获

    func documentRequest(url: URL, method: String, headers: [String: String], body: String) {
        pendingDocRequest = PendingDocRequest(
            url: url.absoluteString, method: method, headers: headers, body: truncateBody(body)
        )
    }

    func documentResponse(url: URL, status: Int, mimeType: String, headers: [String: String]) {
        guard let idx = resources.firstIndex(where: { $0.kind == .document && $0.url == url.absoluteString }) else { return }
        resources[idx].status = status
        resources[idx].mimeType = mimeType
        resources[idx].responseHeaders = headers
    }

    func documentBody(url: URL, body: String) {
        guard let idx = resources.firstIndex(where: { $0.kind == .document && $0.url == url.absoluteString }) else { return }
        resources[idx].responseBody = truncateBody(body)
    }

    private func truncateBody(_ s: String, _ max: Int = 20000_000) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)) + "…[已截断，共 \(s.count) 字符]"
    }

    /// 仅在值真正变化时写入，避免 @Published 触发 SwiftUI 反馈循环
    func setNavButtons(back: Bool, forward: Bool) {
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
    }

    func syncNavButtons() {
        setNavButtons(back: webView?.canGoBack ?? false,
                      forward: webView?.canGoForward ?? false)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func clearResources() {
        resources.removeAll()
        selected.removeAll()
    }

    // MARK: - Messages from injected JS

    func handle(message dict: [String: Any]) {
        switch dict["source"] as? String {
        case "timing": ingestTiming(dict)
        case "req":    ingestRequest(dict)
        default: break
        }
    }

    private func ingestTiming(_ d: [String: Any]) {
        guard let url = d["url"] as? String else { return }
        let kind = ResourceKind(rawValue: d["kind"] as? String ?? "") ?? .other
        let startTime = d["startTime"] as? Double ?? 0
        let status = d["status"] as? Int

        if let idx = mergeIndex(url: url, kind: kind, startTime: startTime, needsTiming: true) {
            resources[idx].duration = d["duration"] as? Double
            resources[idx].transferSize = int64(d["transferSize"])
            resources[idx].encodedBodySize = int64(d["encodedBodySize"])
            resources[idx].decodedBodySize = int64(d["decodedBodySize"])
            resources[idx].protocolName = d["protocol"] as? String ?? ""
            resources[idx].hasTiming = true
            if resources[idx].startTime == 0 { resources[idx].startTime = startTime }
            if status != nil { resources[idx].status = status }
        } else {
            var r = WebResource(
                url: url, kind: kind,
                startTime: startTime,
                duration: d["duration"] as? Double,
                transferSize: int64(d["transferSize"]),
                encodedBodySize: int64(d["encodedBodySize"]),
                decodedBodySize: int64(d["decodedBodySize"]),
                protocolName: d["protocol"] as? String ?? "",
                hasTiming: true
            )
            r.status = status
            if kind == .document, r.method.isEmpty { r.method = "GET" }
            resources.append(r)
        }
    }

    private func ingestRequest(_ d: [String: Any]) {
        guard let url = d["url"] as? String,
              let kindRaw = d["kind"] as? String else { return }
        let kind = ResourceKind(rawValue: kindRaw) ?? .other
        let startTime = d["startTime"] as? Double ?? 0
        let failed = d["failed"] as? Bool ?? false
        let requestHeaders = d["requestHeaders"] as? [String: String] ?? [:]
        let requestBody = d["requestBody"] as? String ?? ""
        let responseHeaders = d["responseHeaders"] as? [String: String] ?? [:]
        let responseBody = d["responseBody"] as? String ?? ""
        captureJobDescription(url: url, responseBody: responseBody)

        if let idx = mergeIndex(url: url, kind: kind, startTime: startTime, needsTiming: false) {
            resources[idx].method = d["method"] as? String ?? "GET"
            resources[idx].mimeType = d["mimeType"] as? String ?? ""
            resources[idx].failed = failed
            resources[idx].hasRequest = true
            if resources[idx].startTime == 0 { resources[idx].startTime = startTime }
            if let status = d["status"] as? Int { resources[idx].status = status }
            resources[idx].requestHeaders = requestHeaders
            resources[idx].requestBody = requestBody
            resources[idx].responseHeaders = responseHeaders
            resources[idx].responseBody = responseBody
        } else {
            resources.append(WebResource(
                url: url,
                kind: kind,
                method: d["method"] as? String ?? "GET",
                status: d["status"] as? Int,
                mimeType: d["mimeType"] as? String ?? "",
                startTime: startTime,
                failed: failed,
                hasRequest: true,
                requestHeaders: requestHeaders,
                requestBody: requestBody,
                responseHeaders: responseHeaders,
                responseBody: responseBody
            ))
        }
    }

    /// detail.json 接口返回的职位描述直接写入 jobSecText
    private func captureJobDescription(url: String, responseBody: String) {
        guard url.contains("wapi/zpgeek/job/detail.json") else { return }
        guard let data = responseBody.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any],
              let zpData = json["zpData"] as? [String: Any],
              let jobInfo = zpData["jobInfo"] as? [String: Any],
              let post = jobInfo["postDescription"] as? String,
              !post.isEmpty else { return }
        jobSecText = post
        NSLog("[职位描述] 已从 detail.json 提取 postDescription（%d 字符）", post.count)
    }

    /// Match an incoming report to an existing row that is still missing this side of data.
    /// Timing reports merge into rows without timing; request reports merge into rows without request info.
    private func mergeIndex(url: String, kind: ResourceKind, startTime: Double, needsTiming: Bool) -> Int? {
        var best: Int? = nil
        var bestDiff = 1500.0 // ms
        for (i, r) in resources.enumerated() where r.url == url && r.kind == kind {
            let alreadyHasThisSide = needsTiming ? r.hasTiming : r.hasRequest
            if alreadyHasThisSide { continue }
            let ref = r.startTime > 0 ? r.startTime : startTime
            let diff = abs(ref - startTime)
            if diff <= bestDiff { bestDiff = diff; best = i }
        }
        return best
    }

    private func int64(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        return 0
    }

    var filteredResources: [WebResource] {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return resources }
        return resources.filter {
            $0.url.lowercased().contains(q) || $0.kind.rawValue.contains(q) || $0.kind.label.contains(q)
        }
    }

    var selectedResource: WebResource? {
        guard let id = selected.first else { return nil }
        return resources.first { $0.id == id }
    }

    var kindCounts: [ResourceKind: Int] {
        var counts: [ResourceKind: Int] = [:]
        for r in resources { counts[r.kind, default: 0] += 1 }
        return counts
    }
}
