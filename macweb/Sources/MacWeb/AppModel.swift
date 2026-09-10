import Foundation
import Combine
import SwiftUI
import WebKit

@MainActor
final class AppModel: ObservableObject {
    @Published var resources: [WebResource] = []
    @Published var selected: Set<UUID> = []
    @Published var filterText: String = ""
    @Published var urlText: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false

    weak var webView: WKWebView?
    var lastURL: URL?

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
        resources.append(WebResource(url: url.absoluteString, kind: .document, method: "GET"))
    }

    func finishNavigation(url: URL?, title: String?) {
        if let url { urlText = url.absoluteString }
        pageTitle = title ?? ""
        syncNavButtons()
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
