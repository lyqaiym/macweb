import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VSplitView {
                WebView(model: model)
                    .frame(minHeight: 260)
                resourcePanel
                    .frame(minHeight: 200, idealHeight: 300)
            }
        }
        .frame(minWidth: 980, minHeight: 660)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: { model.goBack() }) {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            .help("后退")

            Button(action: { model.goForward() }) {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForward)
            .help("前进")

            Button(action: { model.reload() }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新加载")

            TextField("输入网址，例如 www.apple.com，回车访问", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .onSubmit { model.loadAddress(model.urlText) }

            Button("前往") { model.loadAddress(model.urlText) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 资源面板

    private var resourcePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("网络资源").font(.headline)
                Text(kindSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("过滤 URL / 类型", text: $model.filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button(action: { model.clearResources() }) {
                    Label("清空", systemImage: "trash")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Table(model.filteredResources, selection: $model.selected) {
                TableColumn("类型") { r in kindBadge(r.kind) }
                    .width(68)

                TableColumn("状态") { r in
                    Text(statusText(r))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(statusColor(r))
                }
                .width(60)

                TableColumn("方法") { r in
                    Text(r.method.isEmpty ? "—" : r.method)
                        .font(.system(.body, design: .monospaced))
                }
                .width(64)

                TableColumn("资源") { r in
                    Text(resourceAttributed(r))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                TableColumn("MIME") { r in
                    Text(r.mimeType.isEmpty ? "—" : r.mimeType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(150)

                TableColumn("大小") { r in
                    Text(formatBytes(sizeFor(r)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(sizeFor(r) > 0 ? .primary : .secondary)
                }
                .width(76)

                TableColumn("耗时") { r in
                    Text(r.duration.map { String(format: "%.0f ms", $0) } ?? "—")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(r.duration != nil ? .primary : .secondary)
                }
                .width(76)
            }

            if let r = model.selectedResource {
                Divider()
                detailView(r)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - 单元格辅助

    private func kindBadge(_ kind: ResourceKind) -> some View {
        Text(kind.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.color.opacity(0.16), in: Capsule())
            .foregroundStyle(kind.color)
    }

    private func resourceAttributed(_ r: WebResource) -> AttributedString {
        var host = AttributedString(r.host.isEmpty ? r.url : r.host)
        host.font = .system(.body, design: .monospaced).bold()
        var rest = AttributedString(r.host.isEmpty ? "" : r.pathAndQuery)
        rest.font = .system(.caption, design: .monospaced)
        rest.foregroundColor = .secondary
        return host + rest
    }

    private func statusText(_ r: WebResource) -> String {
        if r.failed || (r.status == 0) { return "失败" }
        if let s = r.status { return String(s) }
        return r.isPending ? "…" : "—"
    }

    private func statusColor(_ r: WebResource) -> Color {
        if r.failed || (r.status != nil && r.status! >= 400) || r.status == 0 { return .red }
        guard let s = r.status else { return .secondary }
        if s >= 200 && s < 300 { return .green }
        if s >= 300 && s < 400 { return .orange }
        return .primary
    }

    private func sizeFor(_ r: WebResource) -> Int64 {
        r.transferSize > 0 ? r.transferSize : r.encodedBodySize
    }

    private func formatBytes(_ n: Int64) -> String {
        guard n > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }

    private var kindSummary: String {
        let counts = model.kindCounts
        let order: [ResourceKind] = [.document, .script, .css, .image, .xhr, .fetch, .font, .media, .websocket, .frame, .other]
        let parts = order.compactMap { k in
            counts[k].map { "\(k.label) \($0)" }
        }
        return "共 \(model.resources.count) 条 · " + parts.joined(separator: "  ")
    }

    // MARK: - 详情

    private func detailView(_ r: WebResource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.url)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            HStack(spacing: 14) {
                detailChip("类型", r.kind.label)
                detailChip("方法", r.method.isEmpty ? "—" : r.method)
                detailChip("状态", statusText(r))
                if !r.mimeType.isEmpty { detailChip("MIME", r.mimeType) }
                if !r.protocolName.isEmpty { detailChip("协议", r.protocolName) }
                if r.transferSize > 0 { detailChip("传输", formatBytes(r.transferSize)) }
                if r.encodedBodySize > 0 { detailChip("编码体", formatBytes(r.encodedBodySize)) }
                if let d = r.duration { detailChip("耗时", String(format: "%.1f ms", d)) }
                if r.failed { detailChip("结果", "请求失败") }
            }
        }
    }

    private func detailChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary)
        }
        .font(.caption)
    }
}
