import SwiftUI
import AppKit
import Combine

// MARK: - Command

struct PaletteCommand: Identifiable {
    enum Group: String {
        case navigate = "Navigate"
        case actions = "Actions"
    }

    /// Titles are unique, and identity must survive re-evaluation: `commands` is a
    /// computed property, so a stored `UUID()` was minted fresh on every access —
    /// the row lookup in `body` then never matched and every row reported index 0.
    var id: String { title }
    let group: Group
    let title: String
    let glyph: String
    let shortcut: String?
    let run: () -> Void
}

// MARK: - Key Handling

/// Owns a keyboard-driven list selection *and* its key monitor, and is a class on
/// purpose. Shared by the ⌘K palette and the ⌘F search popover.
///
/// Escape and the arrows never reach SwiftUI here. The search field is first
/// responder, so AppKit hands them to its field editor; `.keyboardShortcut`,
/// `.onExitCommand` and `.onMoveCommand` were all tried on device and none of
/// them fire — the keys fall through to the window instead, which reads a stray
/// Escape as "exit full screen" and minimises on the arrows. A local monitor runs
/// inside `NSApplication.sendEvent`, ahead of all of that, and returning nil
/// destroys the event before the window can see it. That part was verified
/// working on device.
///
/// The monitor's closure is created once and cannot capture the SwiftUI view by
/// value: writing `@State` through a captured `View` copy does not reach the
/// installed storage, which is why Escape (a `Binding`, carrying live setters)
/// worked while the arrows silently did nothing. A reference type does not have
/// that problem, so the selection lives here.
final class PaletteHighlight: ObservableObject {
    @Published var index = 0

    /// Pushed in by the view — the monitor closure cannot read the view's live
    /// computed `results`.
    var count = 0

    private var monitor: Any?

    func move(_ delta: Int) {
        guard count > 0 else { return }
        index = (index + delta + count) % count
    }

    /// `onEscape` is optional: pass it when the caller owns its own dismissal (the
    /// ⌘K overlay), omit it when the container already closes itself on Escape
    /// (the ⌘F popover, where NSPopover handles it and consuming it here would
    /// break a working dismiss).
    func start(onEscape: (() -> Void)? = nil) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:                             // esc
                guard let onEscape else { return event }
                onEscape()
                return nil
            case 126: self.move(-1); return nil // up
            case 125: self.move(1);  return nil // down
            default:  return event               // Return falls through to onSubmit
            }
        }
    }

    /// The monitor is app-wide while installed, so a leaked one would swallow
    /// these keys everywhere. `deinit` backs up the `onDisappear` call.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

// MARK: - Command Palette

/// ⌘K overlay. Fuzzy-ish prefix matching over a flat command list — the list is
/// a dozen entries, so a real fuzzy matcher would be more code than value.
struct CommandPalette: View {
    @Binding var isPresented: Bool
    @Binding var selectedTab: Tab
    let pairingManager: PairingManager
    let quicServer: mDNSQuicServer
    let onOpenSearch: () -> Void

    @State private var query = ""
    @StateObject private var highlight = PaletteHighlight()
    @FocusState private var fieldFocused: Bool
    /// Last pointer position, in screen space so it is unaffected by scrolling.
    @State private var lastPointer: CGPoint?

    private var commands: [PaletteCommand] {
        var out: [PaletteCommand] = Tab.allCases.map { tab in
            PaletteCommand(
                group: .navigate,
                title: tab.rawValue,
                glyph: tab.icon,
                shortcut: tab.shortcutHint
            ) {
                selectedTab = tab
            }
        }

        // Search has no sidebar row any more — this is the palette's route to it.
        out.append(PaletteCommand(
            group: .actions,
            title: "Search notifications, clipboard, files",
            glyph: "magnifyingglass",
            shortcut: "⌘F",
            run: onOpenSearch
        ))

        out.append(PaletteCommand(
            group: .actions,
            title: "Clear clipboard history",
            glyph: "trash",
            shortcut: nil
        ) {
            ClipboardSyncManager.shared.clearAll()
        })

        out.append(PaletteCommand(
            group: .actions,
            title: "Clear notification history",
            glyph: "bell.slash",
            shortcut: nil
        ) {
            NotificationHistoryManager.shared.clearAll()
        })

        out.append(PaletteCommand(
            group: .actions,
            title: "Send file to Android",
            glyph: "arrow.up.doc",
            shortcut: nil
        ) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if panel.runModal() == .OK, let url = panel.url,
               let server = mDNSQuicServer.activeServer {
                FileTransferSender.shared.sendFile(at: url, via: server)
            }
        })

        if pairingManager.isPaired {
            out.append(PaletteCommand(
                group: .actions,
                title: "Unpair device",
                glyph: "xmark.circle",
                shortcut: nil
            ) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Unpair this device?"
                alert.informativeText = "You'll need to re-pair from your Android device."
                alert.addButton(withTitle: "Unpair")
                alert.addButton(withTitle: "Cancel")
                // Cancel takes the return key: this command is one fuzzy match and
                // one keystroke away in a palette built for fast typing, so a stray
                // Enter must not wipe the Keychain pairing key.
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                if alert.runModal() == .alertFirstButtonReturn {
                    pairingManager.resetPairing()
                }
            })
        }

        return out
    }

    private var results: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { $0.title.lowercased().contains(q) }
    }

    private var groupedResults: [(group: PaletteCommand.Group, items: [PaletteCommand])] {
        let order: [PaletteCommand.Group] = [.navigate, .actions]
        return order.compactMap { group -> (group: PaletteCommand.Group, items: [PaletteCommand])? in
            let items = results.filter { $0.group == group }
            return items.isEmpty ? nil : (group: group, items: items)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop. Click anywhere outside to dismiss.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                // Input row
                HStack(spacing: SG.Space.md) {
                    // Not a magnifying glass: that glyph is the toolbar's ⌘F
                    // content search now, and the two must not read alike.
                    Image(systemName: "command")
                        .font(.system(size: 15))
                        .foregroundColor(.sgTextSecondary)

                    TextField("Search commands…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .focused($fieldFocused)
                        .onSubmit(runHighlighted)
                        .onChange(of: query) { _, _ in highlight.index = 0 }

                    SGKeyHint(text: "esc")
                }
                .padding(.horizontal, SG.Space.lg)
                .padding(.vertical, SG.Space.lg)

                Rectangle()
                    .fill(Color.sgHairline)
                    .frame(height: 1)

                if results.isEmpty {
                    EmptyStateText("No matching command")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(groupedResults, id: \.group) { section in
                                    Text(section.group.rawValue.uppercased())
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.4))
                                        .padding(.horizontal, SG.Space.md)
                                        .padding(.top, SG.Space.md)
                                        .padding(.bottom, SG.Space.xs)

                                    ForEach(section.items) { command in
                                        let index = results.firstIndex { $0.id == command.id } ?? 0
                                        PaletteRow(
                                            command: command,
                                            selected: index == highlight.index
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture { run(command) }
                                        // Not `.onHover`: scrolling the list under a
                                        // stationary cursor raises hover for whatever
                                        // slides beneath it, which would snatch the
                                        // selection back mid-keyboard-navigation. Only
                                        // a pointer that actually moved counts as intent.
                                        .onContinuousHover(coordinateSpace: .global) { phase in
                                            guard case .active(let point) = phase else { return }
                                            guard let last = lastPointer else {
                                                lastPointer = point   // first sighting: record, don't select
                                                return
                                            }
                                            guard last != point else { return }
                                            lastPointer = point
                                            highlight.index = index
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, SG.Space.xs)
                        }
                        .frame(maxHeight: 340)
                        // Keep the highlight on screen. `anchor: nil` scrolls the
                        // minimum needed, so a selection already in view never jumps.
                        .onChange(of: highlight.index) { _, _ in scrollToHighlighted(proxy) }
                        .onChange(of: results.count) { _, _ in scrollToHighlighted(proxy) }
                    }
                }

                Rectangle()
                    .fill(Color.sgHairline)
                    .frame(height: 1)

                HStack(spacing: SG.Space.md) {
                    Text("↑↓ navigate")
                    Text("↵ open")
                    Text("esc dismiss")
                    Spacer()
                }
                .font(SG.Font.caption)
                .foregroundColor(.white.opacity(0.4))
                .padding(.horizontal, SG.Space.lg)
                .padding(.vertical, SG.Space.md)
            }
            .frame(width: 640)
            .sgGlass()
            .padding(.top, 120)
        }
        .onAppear {
            fieldFocused = true
            highlight.count = results.count
            highlight.start { isPresented = false }
        }
        .onDisappear { highlight.stop() }
        // The monitor cannot read the view's live `results`, so keep it fed.
        .onChange(of: results.count) { _, newCount in
            highlight.count = newCount
        }
    }

    private func scrollToHighlighted(_ proxy: ScrollViewProxy) {
        guard results.indices.contains(highlight.index) else { return }
        proxy.scrollTo(results[highlight.index].id, anchor: nil)
    }

    private func runHighlighted() {
        guard results.indices.contains(highlight.index) else { return }
        run(results[highlight.index])
    }

    private func run(_ command: PaletteCommand) {
        isPresented = false
        command.run()
    }
}

// MARK: - Row

private struct PaletteRow: View {
    let command: PaletteCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: SG.Space.md) {
            // The 6% fill step alone is thin for the one affordance that carries
            // keyboard state, so the glyph brightens too. Emphasis, not colour.
            Image(systemName: command.glyph)
                .font(.system(size: 14))
                .foregroundColor(selected ? .white : .sgTextSecondary)
                .frame(width: 20)

            Text(command.title)
                .font(SG.Font.body)
                .foregroundColor(.white)

            Spacer()

            if let shortcut = command.shortcut {
                SGKeyHint(text: shortcut)
            }
        }
        .padding(.horizontal, SG.Space.md)
        .padding(.vertical, SG.Space.md)
        .background(selected ? Color.sgSurfaceHigh : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: SG.Radius.card))
        .padding(.horizontal, SG.Space.sm)
    }
}
