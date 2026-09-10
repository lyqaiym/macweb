import Foundation
import SwiftUI

enum ResourceKind: String {
    case document
    case script
    case css
    case image
    case xhr
    case fetch
    case font
    case media
    case frame
    case websocket
    case other

    var label: String {
        switch self {
        case .document:  return "文档"
        case .script:    return "脚本"
        case .css:       return "样式"
        case .image:     return "图片"
        case .xhr:       return "XHR"
        case .fetch:     return "Fetch"
        case .font:      return "字体"
        case .media:     return "媒体"
        case .frame:     return "框架"
        case .websocket: return "WS"
        case .other:     return "其他"
        }
    }

    var color: Color {
        switch self {
        case .document:  return .blue
        case .script:    return .orange
        case .css:       return .purple
        case .image:     return .green
        case .xhr:       return .teal
        case .fetch:     return .cyan
        case .font:      return .pink
        case .media:     return .indigo
        case .frame:     return .gray
        case .websocket: return .mint
        case .other:     return .secondary
        }
    }
}

struct WebResource: Identifiable {
    let id = UUID()
    var url: String
    var kind: ResourceKind
    var method: String = ""
    var status: Int? = nil
    var mimeType: String = ""
    var startTime: Double = 0
    var duration: Double? = nil
    var transferSize: Int64 = 0
    var encodedBodySize: Int64 = 0
    var decodedBodySize: Int64 = 0
    var protocolName: String = ""
    var failed: Bool = false
    var hasTiming: Bool = false
    var hasRequest: Bool = false
    var requestHeaders: [String: String] = [:]
    var requestBody: String = ""
    var responseHeaders: [String: String] = [:]
    var responseBody: String = ""

    var host: String { URL(string: url)?.host ?? "" }

    var pathAndQuery: String {
        guard let u = URL(string: url) else { return url }
        var p = u.path
        if p.isEmpty { p = "/" }
        if let q = u.query { p += "?" + q }
        return p
    }

    var isPending: Bool { !hasTiming && status == nil && !failed }

    var curlCommand: String {
        let m = method.isEmpty ? "GET" : method
        var parts = ["curl"]
        if m != "GET" { parts.append("-X \(m)") }
        let skipped: Set<String> = ["host", "content-length", "connection", "accept-encoding"]
        for (k, v) in requestHeaders.sorted(by: { $0.key < $1.key })
        where !skipped.contains(k.lowercased()) {
            parts.append("-H \(Self.shellQuote("\(k): \(v)"))")
        }
        if !requestBody.isEmpty {
            parts.append("--data-raw \(Self.shellQuote(requestBody))")
        }
        parts.append(Self.shellQuote(url))
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
