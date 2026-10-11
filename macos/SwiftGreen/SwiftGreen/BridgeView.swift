import SwiftUI
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Files, both ways, in one tab. Two sides, each said plainly:
/// **Phone** — everything on your phone; open any folder, bring a file to this Mac.
/// **Mac Folder** — one folder on this Mac that your phone can open.
struct BridgeView: View {
    @ObservedObject var server: mDNSQuicServer
    @AppStorage("bridge_side") private var side: Side = .phone
    @State private var preview: URL?
    @Namespace private var thumb

    enum Side: String, CaseIterable {
        case phone = "Phone", mac = "Mac Folder"

        var glyph: String { self == .phone ? "iphone" : "laptopcomputer" }
        var subtitle: String {
            switch self {
            case .phone: return "Everything on your phone — open any folder, bring a file to this Mac"
            case .mac: return "A folder on this Mac that your phone can open"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.sgCanvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: SG.Space.lg) {
                HStack(alignment: .center) {
                    SGScreenHeader(title: "Bridge", subtitle: side.subtitle)
                    Spacer()
                    sidePicker.padding(.top, SG.Space.xl)
                }

                switch side {
                case .phone: PhoneBrowser(server: server, preview: $preview)
                case .mac: MacFolderPane(server: server, preview: $preview)
                }
            }
            .padding(.horizontal, SG.Space.xxl)
            .padding(.bottom, SG.Space.xxl)
        }
        .quickLookPreview($preview)
    }

    /// One track, one sliding thumb — the same control as Calls and Activity.
    private var sidePicker: some View {
        HStack(spacing: 0) {
            ForEach(Side.allCases, id: \.self) { s in
                let active = side == s
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { side = s }
                } label: {
                    Label(s.rawValue, systemImage: s.glyph)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(active ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if active {
                                Capsule().fill(Color.white)
                                    .matchedGeometryEffect(id: "side", in: thumb)
                                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .sgGlassCapsule()
    }
}

// MARK: - Phone

private struct PhoneBrowser: View {
    @ObservedObject var server: mDNSQuicServer
    @Binding var preview: URL?
    @ObservedObject private var store = MediaBrowserStore.shared
    @ObservedObject private var receiver = FileTransferReceiver.shared
    @AppStorage("bridge_grid") private var grid = true
    /// Newest first by default: in Camera, Screenshots and Downloads that's what you're after.
    @AppStorage("bridge_sort") private var sort: SortKey = .date
    @State private var query = ""
    /// Paths asked for this session, so a tile shows "coming" before bytes arrive.
    @State private var requested: Set<String> = []
    @FocusState private var searchFocused: Bool

    enum SortKey: String, CaseIterable { case name = "Name", date = "Date Modified", size = "Size" }

    /// Standard Android folders, one click away from anywhere.
    private static let places: [(name: String, glyph: String, path: String)] = [
        ("Camera", "camera", "DCIM/Camera"),
        ("Screenshots", "camera.viewfinder", "Pictures/Screenshots"),
        ("Downloads", "arrow.down.circle", "Download"),
        ("Documents", "doc.text", "Documents"),
        ("Music", "music.note", "Music"),
        ("Movies", "film", "Movies"),
    ]

    private var isOnline: Bool { server.isTunnelActive }
    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    /// Received files still on disk, by name — what's already on this Mac.
    private var onMac: [String: URL] {
        var out: [String: URL] = [:]
        for r in receiver.transferHistory where r.state == "complete" && out[r.filename] == nil {
            if FileManager.default.fileExists(atPath: r.path) { out[r.filename] = URL(fileURLWithPath: r.path) }
        }
        return out
    }

    private func sorted(_ items: [MediaBrowserItem]) -> [MediaBrowserItem] {
        items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            switch sort {
            case .name: return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
            case .date: return a.dateModifiedMs > b.dateModifiedMs
            case .size: return a.sizeBytes > b.sizeBytes
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SG.Space.md) {
            toolbar
            if !searching { placesRow }
            receivingStrip
            content
        }
        .onAppear { if !store.hasRequested { store.requestList(directory: "") } }
        .onChange(of: isOnline) { _, online in
            // A request in flight when the tunnel drops never gets its reply; on
            // reconnect, re-ask for whatever folder was open.
            if !online { store.cancelLoading() }
            else if store.items.isEmpty { store.requestList(directory: store.directory) }
        }
        .task(id: query) {
            // Debounced: the phone walks its whole storage per query.
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { store.search(query) }
        }
        .onChange(of: onMac.keys.sorted()) { _, _ in
            requested = requested.filter { path in onMac[(path as NSString).lastPathComponent] == nil }
        }
        .background {
            VStack {
                Button("") { searchFocused = true }.keyboardShortcut("f")
                Button("") { if let p = store.parentDirectory { open(p) } }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("") { query = ""; searchFocused = false }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: SG.Space.sm) {
            iconButton("chevron.left", help: "Enclosing folder (⌘↑)", enabled: store.parentDirectory != nil && !searching) {
                if let p = store.parentDirectory { open(p) }
            }
            breadcrumb
            Spacer(minLength: SG.Space.md)
            searchField
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .sgGlassCircle()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by \(sort.rawValue)")
            iconButton(grid ? "list.bullet" : "square.grid.2x2", help: grid ? "Show as list" : "Show as icons", enabled: true) {
                withAnimation(SG.Motion.quick) { grid.toggle() }
            }
        }
    }

    /// Phone › DCIM › Camera — every part is a way back.
    private var breadcrumb: some View {
        let parts = store.directory.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            crumb("Phone", path: "", last: parts.isEmpty || searching)
            if !searching {
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.sgTextSecondary)
                    crumb(parts[i], path: parts[0...i].joined(separator: "/"), last: i == parts.count - 1)
                }
            }
            Text(searching ? "· Search" : "· \(store.items.count) items")
                .font(SG.Font.caption)
                .foregroundColor(.sgTextSecondary)
                .padding(.leading, 4)
                .opacity(isOnline ? 1 : 0)
        }
        .lineLimit(1)
    }

    private func crumb(_ title: String, path: String, last: Bool) -> some View {
        Button { query = ""; open(path) } label: {
            Text(title)
                .font(.system(size: 15, weight: last ? .semibold : .regular))
                .foregroundColor(last ? .white : .sgTextSecondary)
        }
        .buttonStyle(.plain)
        .disabled(last && !searching)
    }

    private var searchField: some View {
        HStack(spacing: SG.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.sgTextSecondary)
            TextField("Search your phone", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.sgTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘F").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 32)
        .sgGlass(radius: SG.Radius.tile)
        .overlay(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous)
            .stroke(Color.white.opacity(searchFocused ? 0.25 : 0)))
        .disabled(!isOnline)
    }

    private var placesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.places, id: \.path) { place in
                    let here = store.directory == place.path
                    Button { open(place.path) } label: {
                        Label(place.name, systemImage: place.glyph)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(here ? .black : .white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background { if here { Capsule().fill(Color.white) } }
                            .sgGlassCapsule(interactive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isOnline)
                }
            }
            .padding(.vertical, 2)   // room for the glass edge inside the scroll view
        }
    }

    @ViewBuilder
    private var receivingStrip: some View {
        if receiver.isReceiving {
            HStack(spacing: SG.Space.md) {
                ProgressView().controlSize(.small)
                Text("Bringing \(receiver.receiveFilename) to this Mac")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SGMeter(value: receiver.receiveProgress, height: 4).frame(maxWidth: 200)
                Text("\(Int(receiver.receiveProgress * 100))%")
                    .font(SG.Font.mono(11, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, SG.Space.md)
            .frame(height: 36)
            .sgGlass(radius: SG.Radius.tile)
            .transition(.opacity)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !isOnline {
            centered(EmptyStateText("Connect your phone to browse its files", glyph: "iphone.slash"))
        } else if searching {
            searchContent
        } else if store.isLoading && store.items.isEmpty {
            skeleton
        } else if store.items.isEmpty {
            switch store.error {
            case "permission_required":
                centered(EmptyStateText("On your phone, open SwiftGreen → Settings → All files access", glyph: "lock"))
            case "not_found":
                centered(EmptyStateText("This folder isn't on your phone", glyph: "questionmark.folder"))
            case "no_response":
                centered(EmptyStateText("Your phone didn't answer", glyph: "exclamationmark.arrow.circlepath",
                                        actionLabel: "Try Again") { store.requestList(directory: store.directory) })
            default:
                centered(EmptyStateText("This folder is empty", glyph: "folder"))
            }
        } else {
            items(sorted(store.items), showWhere: false)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        // Still debouncing counts as searching: "no matches" is only said once the
        // phone has answered this exact query.
        let pending = store.searchQuery != query.trimmingCharacters(in: .whitespaces)
        if (store.isSearching || pending) && store.searchResults.isEmpty {
            centered(VStack(spacing: SG.Space.md) {
                ProgressView().controlSize(.small)
                Text("Searching your phone…").font(SG.Font.body).foregroundColor(.sgTextSecondary)
            })
        } else if store.searchUnavailable {
            centered(EmptyStateText("Update SwiftGreen on your phone to search everything", glyph: "arrow.down.app"))
        } else if store.searchResults.isEmpty {
            centered(EmptyStateText("Nothing on your phone matches “\(query.trimmingCharacters(in: .whitespaces))”",
                                    glyph: "magnifyingglass"))
        } else {
            items(sorted(store.searchResults), showWhere: true)
        }
    }

    private func items(_ list: [MediaBrowserItem], showWhere: Bool) -> some View {
        let local = onMac
        return ScrollView {
            if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 132), spacing: SG.Space.sm)],
                          alignment: .leading, spacing: SG.Space.md) {
                    ForEach(list) { item in
                        Button { activate(item, local: local[item.filename]) } label: {
                            FileTile(name: item.filename,
                                     caption: showWhere ? whereLabel(item) : (item.isDir ? nil : size(item.sizeBytes)),
                                     icon: FileIcon.image(name: item.filename, mime: item.mimeType, isDir: item.isDir),
                                     thumbnail: store.thumbnails[item.path],
                                     badge: badge(item, local: local[item.filename]))
                        }
                        .buttonStyle(.plain)
                        .modifier(PhoneItemActions(item: item, local: local[item.filename],
                                                   preview: $preview, bring: { bring(item) }))
                        .onAppear { if item.mimeType.hasPrefix("image") { store.requestThumbnail(path: item.path) } }
                    }
                }
                .padding(.vertical, SG.Space.xs)
            } else {
                LazyVStack(spacing: 0) {
                    listHeader
                    ForEach(list) { item in
                        Button { activate(item, local: local[item.filename]) } label: {
                            FileListRow(name: item.filename,
                                        detail: showWhere ? whereLabel(item) : nil,
                                        icon: FileIcon.image(name: item.filename, mime: item.mimeType, isDir: item.isDir),
                                        date: item.dateModifiedMs,
                                        size: item.isDir ? "—" : size(item.sizeBytes),
                                        badge: badge(item, local: local[item.filename]))
                        }
                        .buttonStyle(.plain)
                        .modifier(PhoneItemActions(item: item, local: local[item.filename],
                                                   preview: $preview, bring: { bring(item) }))
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var listHeader: some View {
        HStack(spacing: SG.Space.md) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28)
            Text("Date Modified").frame(width: 130, alignment: .leading)
            Text("Size").frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.sgTextSecondary)
        .padding(.horizontal, SG.Space.sm)
        .frame(height: 26)
    }

    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 132), spacing: SG.Space.sm)],
                  alignment: .leading, spacing: SG.Space.md) {
            ForEach(0..<12, id: \.self) { _ in
                SGSkeleton(height: 112).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func centered<V: View>(_ view: V) -> some View {
        view.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func open(_ path: String) {
        withAnimation(SG.Motion.quick) { store.requestList(directory: path) }
    }

    /// Folders open; files already here preview; anything else comes over.
    private func activate(_ item: MediaBrowserItem, local: URL?) {
        if item.isDir {
            query = ""
            open(item.path)
        } else if let local {
            preview = local
        } else {
            bring(item)
        }
    }

    private func bring(_ item: MediaBrowserItem) {
        guard !requested.contains(item.path) else { return }
        requested.insert(item.path)
        store.requestFile(path: item.path)
    }

    private func badge(_ item: MediaBrowserItem, local: URL?) -> FileTile.Badge {
        if item.isDir { return .none }
        if local != nil { return .onMac }
        if requested.contains(item.path) || (receiver.isReceiving && receiver.receiveFilename == item.filename) { return .coming }
        return .fetchable
    }

    private func whereLabel(_ item: MediaBrowserItem) -> String {
        let parent = (item.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "Phone" : parent
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func iconButton(_ glyph: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(enabled ? 1 : 0.25))
                .frame(width: 32, height: 32)
                .sgGlassCircle()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Right-click and drag for a phone item: bring it over, or — once it's here —
/// preview, reveal, or drag it straight into another app.
private struct PhoneItemActions: ViewModifier {
    let item: MediaBrowserItem
    let local: URL?
    @Binding var preview: URL?
    let bring: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if !item.isDir {
                    if let local {
                        Button("Quick Look") { preview = local }
                        Button("Open") { NSWorkspace.shared.open(local) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([local]) }
                    } else {
                        Button("Bring to Mac", action: bring)
                    }
                }
                Button("Copy Path on Phone") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("/" + item.path, forType: .string)
                }
            }
            .onDrag {
                guard let local, let provider = NSItemProvider(contentsOf: local) else { return NSItemProvider() }
                return provider
            }
            .help(item.isDir ? "Open \(item.filename)"
                  : local != nil ? "On this Mac — click to preview, drag into any app"
                  : "Click to bring to this Mac")
    }
}

// MARK: - Mac Folder

private struct MacFolderPane: View {
    @ObservedObject var server: mDNSQuicServer
    @Binding var preview: URL?
    @ObservedObject private var store = MacFileBrowserStore.shared
    @State private var targeted = false

    private var phoneConnected: Bool { server.isTunnelActive }

    var body: some View {
        Group {
            if let folder = store.folderURL {
                shared(folder)
            } else {
                intro
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: SG.Radius.card, style: .continuous)
                    .fill(Color.sgBackground.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: SG.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5))
                    .overlay {
                        VStack(spacing: SG.Space.sm) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 32, weight: .light))
                            Text(store.folderURL == nil ? "Drop a folder to share it"
                                 : "Drop to add to “\(store.directoryName)”")
                                .font(SG.Font.rowTitle)
                            if store.folderURL != nil {
                                Text("Copied in — your phone can take them from there")
                                    .font(SG.Font.caption)
                                    .foregroundColor(.sgTextSecondary)
                            }
                        }
                        .foregroundColor(.white)
                    }
                    .transition(.opacity)
            }
        }
        .animation(SG.Motion.quick, value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            let lock = NSLock()
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if store.folderURL == nil {
                    if let dir = urls.first(where: { $0.hasDirectoryPath }) { store.share(dir) }
                } else {
                    store.add(urls)
                }
            }
            return true
        }
    }

    /// Nothing shared yet: what it is, why it's safe, one button.
    private var intro: some View {
        VStack(spacing: SG.Space.lg) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: SG.Space.sm) {
                Text("Share a folder with your phone")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                Text("Your phone can open it and download what's inside.\nNothing else on this Mac is visible.")
                    .font(SG.Font.body)
                    .foregroundColor(.sgTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Button { store.pickDirectory() } label: {
                Text("Choose Folder…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sgBackground)
                    .padding(.horizontal, 20)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            Text("or drop one here")
                .font(SG.Font.caption)
                .foregroundColor(.sgTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shared(_ folder: URL) -> some View {
        VStack(alignment: .leading, spacing: SG.Space.md) {
            HStack(spacing: SG.Space.md) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.directoryName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: phoneConnected ? "circle.fill" : "circle")
                            .font(.system(size: 6))
                            .foregroundColor(phoneConnected ? .sgSuccess : .sgDanger)
                        Text("\(store.items.count) \(store.items.count == 1 ? "file" : "files") · "
                             + (phoneConnected ? "Open on your phone now" : "Your phone sees it when it connects"))
                    }
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                }
                Spacer(minLength: SG.Space.md)
                pill("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                pill("Change…") { store.pickDirectory() }
                Button("Stop Sharing") { withAnimation(SG.Motion.standard) { store.stopSharing() } }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.sgTextSecondary)
                    .buttonStyle(.plain)
                    .padding(.leading, SG.Space.xs)
            }
            .padding(SG.Space.lg)
            .sgGlass()

            Text(store.hasSubfolders
                 ? "Drop files anywhere here to add them. Only files at the top level are shared — subfolders stay private."
                 : "Drop files anywhere here to add them. New files reach your phone automatically.")
                .font(SG.Font.caption)
                .foregroundColor(.sgTextSecondary)
                .padding(.horizontal, SG.Space.xs)

            if store.items.isEmpty {
                EmptyStateText("This folder is empty — drop files here to hand them to your phone", glyph: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 132), spacing: SG.Space.sm)],
                              alignment: .leading, spacing: SG.Space.md) {
                        ForEach(store.items) { item in
                            MacFileTile(item: item, preview: $preview)
                        }
                    }
                    .padding(.vertical, SG.Space.xs)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .sgGlassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
    }
}

/// A file in the shared folder, with its real Quick Look thumbnail when it has one.
private struct MacFileTile: View {
    let item: MacFileBrowserItem
    @Binding var preview: URL?
    @State private var thumbnail: NSImage?

    var body: some View {
        Button { preview = item.url } label: {
            FileTile(name: item.filename,
                     caption: ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file),
                     icon: NSWorkspace.shared.icon(forFile: item.url.path),
                     thumbnail: thumbnail,
                     badge: .none)
        }
        .buttonStyle(.plain)
        .task(id: item.url) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64),
                                                       scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Quick Look") { preview = item.url }
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .help("Click to preview · drag into any app")
    }
}

// MARK: - Shared pieces

/// The Finder icon for a file type, from its extension first (the phone's MIME
/// type is often a generic octet-stream).
private enum FileIcon {
    static func image(name: String, mime: String, isDir: Bool) -> NSImage {
        if isDir { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? UTType(mimeType: mime) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// An icon-view cell, Finder style: a big icon or thumbnail, the name under it.
private struct FileTile: View {
    enum Badge { case none, fetchable, coming, onMac }

    let name: String
    let caption: String?
    let icon: NSImage
    let thumbnail: NSImage?
    let badge: Badge
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                } else {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                }
            }
            .frame(width: 72, height: 72)
            .overlay(alignment: .bottomTrailing) { badgeView.offset(x: 4, y: 4) }

            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: 30, alignment: .top)
            Text(caption ?? " ")
                .font(.system(size: 10))
                .foregroundColor(.sgTextSecondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(SG.Space.sm)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hovering ? Color.sgSurface : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .none: EmptyView()
        case .onMac:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.black, .white)
                .help("On this Mac")
        case .coming:
            ProgressView().controlSize(.mini)
                .padding(3)
                .background(Circle().fill(Color.sgSurfaceHigh))
        case .fetchable:
            if hovering {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.black, .white)
            }
        }
    }
}

/// The list-view row: name, date, size — Finder's columns.
private struct FileListRow: View {
    let name: String
    let detail: String?
    let icon: NSImage
    let date: Int64
    let size: String
    let badge: FileTile.Badge
    @State private var hovering = false

    private static let dateF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy, HH:mm"; return f
    }()

    var body: some View {
        HStack(spacing: SG.Space.md) {
            HStack(spacing: SG.Space.sm) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                switch badge {
                case .onMac: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(.white)
                case .coming: ProgressView().controlSize(.mini)
                case .fetchable where hovering:
                    Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundColor(.white)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.dateF.string(from: Date(timeIntervalSince1970: Double(date) / 1000)))
                .frame(width: 130, alignment: .leading)
            Text(size).frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundColor(.sgTextSecondary)
        .padding(.horizontal, SG.Space.sm)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous)
            .fill(hovering ? Color.sgSurface : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
    }
}
