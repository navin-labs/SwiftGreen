import SwiftUI
import AppKit
import Combine

// MARK: - Search Popover

/// ⌘F universal search, anchored to the toolbar. Distinct from the ⌘K command
/// palette: this searches *content*, the palette searches commands.
/// 640pt wide to match the palette — FileTransferRow carries an action row and
/// needs the width. The result region is a fixed height so the popover does not
/// resize on every keystroke.
struct SearchPopover: View {
    @StateObject private var viewModel = SearchViewModel()
    @StateObject private var highlight = PaletteHighlight()
    @FocusState private var fieldFocused: Bool

    private var noResults: Bool {
        viewModel.searchResults.notifications.isEmpty &&
        viewModel.searchResults.clipboardEntries.isEmpty &&
        viewModel.searchResults.fileTransfers.isEmpty
    }

    // The three sections are flattened into one index space so ↑/↓ walk the whole
    // result set. Record ids are prefixed because notifications and clipboard
    // entries both key on String and could otherwise collide.
    private var clipboardOffset: Int { viewModel.searchResults.notifications.count }
    private var fileOffset: Int { clipboardOffset + viewModel.searchResults.clipboardEntries.count }

    private var rowIDs: [String] {
        viewModel.searchResults.notifications.map { "n:\($0.id)" } +
        viewModel.searchResults.clipboardEntries.map { "c:\($0.id)" } +
        viewModel.searchResults.fileTransfers.map { "f:\($0.id.uuidString)" }
    }

    private func scrollToHighlighted(_ proxy: ScrollViewProxy) {
        let ids = rowIDs
        guard ids.indices.contains(highlight.index) else { return }
        proxy.scrollTo(ids[highlight.index], anchor: nil)
    }

    /// Return acts on the highlighted row. Results are heterogeneous, so each row type
    /// gets its own explicit action rather than one default: a clipboard entry is
    /// copied (its row's own button), a file is opened (as Return does in Spotlight),
    /// and a notification has no natural action, so Return does nothing there.
    private func performHighlighted() {
        let results = viewModel.searchResults
        let i = highlight.index
        guard i >= clipboardOffset else { return }
        if i < fileOffset {
            let record = results.clipboardEntries[i - clipboardOffset]
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.text, forType: .string)
            return
        }
        let fileIndex = i - fileOffset
        guard results.fileTransfers.indices.contains(fileIndex) else { return }
        let path = results.fileTransfers[fileIndex].path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SG.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.sgTextSecondary)
                TextField("Search notifications, clipboard, files…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(SG.Font.body)
                    .foregroundColor(.white)
                    .focused($fieldFocused)
                    .onChange(of: viewModel.searchQuery) { _, _ in highlight.index = 0 }
                    .onSubmit { performHighlighted() }
            }
            .padding(.horizontal, SG.Space.lg)
            .padding(.vertical, SG.Space.md)

            Rectangle()
                .fill(Color.sgHairline)
                .frame(height: 1)

            Group {
                if viewModel.searchQuery.isEmpty {
                    EmptyStateText("Start typing to search notifications, clipboard and files")
                } else if noResults {
                    EmptyStateText("No results for \"\(viewModel.searchQuery)\"")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: SG.Space.sm) {
                                if !viewModel.searchResults.notifications.isEmpty {
                                    SearchSectionHeader(title: "Notifications")
                                    ForEach(Array(viewModel.searchResults.notifications.enumerated()),
                                            id: \.element.id) { pair in
                                        SearchNotificationRow(record: pair.element,
                                                              selected: highlight.index == pair.offset)
                                            .padding(.horizontal, SG.Space.md)
                                            .id("n:\(pair.element.id)")
                                    }
                                }

                                if !viewModel.searchResults.clipboardEntries.isEmpty {
                                    SearchSectionHeader(title: "Clipboard")
                                    ForEach(Array(viewModel.searchResults.clipboardEntries.enumerated()),
                                            id: \.element.id) { pair in
                                        SearchClipboardRow(record: pair.element,
                                                           selected: highlight.index == clipboardOffset + pair.offset)
                                            .padding(.horizontal, SG.Space.md)
                                            .id("c:\(pair.element.id)")
                                    }
                                }

                                if !viewModel.searchResults.fileTransfers.isEmpty {
                                    SearchSectionHeader(title: "Files")
                                    ForEach(Array(viewModel.searchResults.fileTransfers.enumerated()),
                                            id: \.element.id) { pair in
                                        FileTransferRow(record: pair.element,
                                                        selected: highlight.index == fileOffset + pair.offset)
                                            .padding(.horizontal, SG.Space.md)
                                            .id("f:\(pair.element.id.uuidString)")
                                    }
                                }
                            }
                            .padding(.vertical, SG.Space.sm)
                        }
                        .onChange(of: highlight.index) { _, _ in scrollToHighlighted(proxy) }
                    }
                }
            }
            // Fixed height centres the empty states without the full-height
            // Spacer sandwich a screen would use.
            .frame(height: 340)
        }
        .frame(width: 640)
        .background(Color.sgSurface)
        .onAppear {
            fieldFocused = true
            highlight.count = rowIDs.count
            // No onEscape: NSPopover already closes itself on Escape, and that
            // works today. Only ↑/↓ are claimed here; Return reaches the field's
            // onSubmit (performHighlighted).
            highlight.start()
        }
        .onDisappear { highlight.stop() }
        .onChange(of: rowIDs.count) { _, newCount in highlight.count = newCount }
    }
}

// MARK: - Section Header

private struct SearchSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(SG.Font.section)
            .foregroundColor(.white)
            .padding(.horizontal, SG.Space.md)
            .padding(.top, SG.Space.md)
            .padding(.bottom, SG.Space.xs)
    }
}

// MARK: - Notification Row

private struct SearchNotificationRow: View {
    let record: NotificationHistoryManager.NotificationRecord
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if let img = searchDecodeImage(record.senderPhoto) ?? searchDecodeImage(record.appIcon) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: SG.Radius.tile))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: SG.Radius.tile)
                        .fill(Color.sgSurfaceHigh)
                        .frame(width: 28, height: 28)
                    Image(systemName: "bell")
                        .font(.system(size: 12))
                        .foregroundColor(.sgTextSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(record.appName)
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white)
                    Spacer()
                    Text(searchRelativeTime(record.timestampMs))
                        .font(.system(size: 9))
                        .foregroundColor(.sgTextSecondary)
                }
                Text(record.title)
                    .font(.caption2)
                    .foregroundColor(.white)
                Text(record.body)
                    .font(.caption2)
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
            }
        }
        .sgRow(selected: selected)
    }
}

// MARK: - Clipboard Row

private struct SearchClipboardRow: View {
    let record: ClipboardRecord
    var selected: Bool = false
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.text)
                    .font(.caption)
                    .bold()
                    .foregroundColor(.white)
                    .lineLimit(2)
                let sourceText = record.source == "mac" ? "From Mac" : "From Android"
                let timeText = timeFormatter.string(from: Date(timeIntervalSince1970: Double(record.timestampMs) / 1000))
                Text("\(sourceText) · \(timeText)")
                    .font(.caption2)
                    .foregroundColor(.sgTextSecondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(.sgTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel("Copy clipboard entry")
        }
        .sgRow(selected: selected)
    }
}

// MARK: - File Transfer Row

struct FileTransferRow: View {
    let record: FileTransferReceiver.TransferRecord
    /// Defaulted so the Overview call site (ContentView) is unaffected.
    var selected: Bool = false
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var fileURL: URL? {
        guard !record.path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: record.path)
        return FileManager.default.fileExists(atPath: record.path) ? url : nil
    }

    /// Transfer outcome is carried entirely by the glyph — a filled check for
    /// success, a minus for cancelled, a cross for failure. There is no red.
    private var stateIcon: String {
        switch record.state {
        case "complete", "sent": return "checkmark.circle"
        case "cancelled":        return "minus.circle"
        default:                 return "xmark.circle"
        }
    }

    private var stateLabel: String {
        switch record.state {
        case "complete":  return "Received"
        case "sent":      return "Sent"
        case "cancelled": return "Cancelled"
        default:          return "Failed"
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SG.Space.sm) {
            HStack(spacing: SG.Space.md) {
                Image(systemName: stateIcon)
                    .font(.system(size: 16))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.filename)
                        .font(SG.Font.rowTitle)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text("\(stateLabel) · \(sizeText) · \(timeFormatter.string(from: record.date))")
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                }
                Spacer()

                if let url = fileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundColor(.sgTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(record.filename) in Finder")
                }
            }

            if record.path.isEmpty {
                // no path — cancelled or error, no actions
            } else if let url = fileURL {
                HStack(spacing: SG.Space.sm) {
                    RowAction("Open") { NSWorkspace.shared.open(url) }
                    RowAction("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.path, forType: .string)
                    }
                    RowAction("Resend") {
                        if let server = mDNSQuicServer.activeServer {
                            FileTransferSender.shared.sendFile(at: url, via: server)
                        }
                    }
                }
            } else {
                Text("File no longer available")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
            }
        }
        .sgRow(selected: selected)
        // Rich right-click actions, matching Finder's own vocabulary.
        .contextMenu {
            if let url = fileURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.path, forType: .string)
                }
                Button("Resend to Android") {
                    if let server = mDNSQuicServer.activeServer {
                        FileTransferSender.shared.sendFile(at: url, via: server)
                    }
                }
            }
        }
    }
}

/// Small text action used inside row cards.
private struct RowAction: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.sgTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.sgSurfaceHigh)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Private Helpers

private func searchRelativeTime(_ timestampMs: Int64) -> String {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let diff = now - timestampMs
    if diff < 60_000 { return "Just now" }
    if diff < 3_600_000 { return "\(diff / 60_000)m ago" }
    if diff < 86_400_000 { return "\(diff / 3_600_000)h ago" }
    let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM dd"
    return fmt.string(from: date)
}

private func searchDecodeImage(_ base64: String?) -> NSImage? {
    guard let str = base64, !str.isEmpty,
          let data = Data(base64Encoded: str) else { return nil }
    return NSImage(data: data)
}
