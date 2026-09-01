import SwiftUI
import UIKit

struct SettingsV2: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var network: TGNetworkMonitor
    @ObservedObject var proxy: TGProxyManager
    let runtime: TransferRuntime
    @State private var recoveryMessageID = ""
    @State private var confirmReset = false
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) { ForEach(TGAppearance.allCases) { Text($0.label).tag($0) } }
                Picker("Default file view", selection: $preferences.driveViewMode) { ForEach(TGDriveViewMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) } }
                Picker("Default sort", selection: $preferences.sortMode) { ForEach(TGDriveSortMode.allCases) { Text($0.label).tag($0) } }
                if preferences.driveViewMode == .grid { Slider(value: $preferences.gridScale, in: 0.5...2.0) }
                Toggle("Haptic feedback", isOn: $preferences.hapticsEnabled)
            }
            Section("Transfers") {
                Toggle("Transfer notifications", isOn: $preferences.transferNotifications)
                Toggle("Keep screen awake during transfers", isOn: $preferences.keepScreenAwakeDuringTransfers)
                Toggle("Wi‑Fi only uploads", isOn: $preferences.wifiOnlyUploads)
                Button("Allow notifications", systemImage: "bell.badge") { runtime.requestNotificationPermission() }
                NavigationLink("Offline downloads", destination: LocalDownloadsView())
                LabeledContent("Queued uploads", value: "\(queue.queuedCount)")
            }
            Section("Tags & Organization") { NavigationLink { TagsView(cloud: cloud) } label: { LabeledContent("Manage tags", value: "\(cloud.tags.count)") } }
            Section("Telegram") {
                LabeledContent("Account", value: telegram.accountName)
                LabeledContent("Authorization", value: telegram.lastAuthorizationStateName)
                Button("Log out from Telegram", systemImage: "rectangle.portrait.and.arrow.right") { telegram.logOut() }
            }
            Section("Recovery Catalog") {
                LabeledContent("Status", value: cloud.catalogStatus)
                LabeledContent("Revision", value: "\(cloud.index.revision)")
                Button("Sync catalog now", systemImage: "arrow.up.doc.on.clipboard") { cloud.syncCatalogNow() }.disabled(cloud.isCatalogSyncing)
                Button("Fast restore / refresh", systemImage: "bolt.fill") { cloud.bootstrapFromTelegram() }.disabled(cloud.isRefreshing)
                Button("Full recovery scan", systemImage: "magnifyingglass") { cloud.fullRebuildFromTelegram() }.disabled(cloud.isRefreshing)
                TextField("Catalog pointer message ID", text: $recoveryMessageID).keyboardType(.numberPad)
                Button("Restore from message ID", systemImage: "arrow.down.doc") { cloud.restoreFromCatalogPointer(recoveryMessageID) }.disabled(recoveryMessageID.isEmpty)
            }
            Section("Network") {
                LabeledContent("Connection", value: network.isConnected ? network.interfaceName : "Offline")
                NavigationLink { ProxySettingsView(proxy: proxy, telegram: telegram) } label: { LabeledContent("Telegram Proxy", value: proxy.status) }
            }
            Section("Apple Files") {
                Label("On My iPhone › TGSpeicher › Upload Inbox", systemImage: "folder.badge.plus")
                Label("On My iPhone › TGSpeicher › Downloads", systemImage: "folder.fill")
                Label("On My iPhone › TGSpeicher › Transfer Queue", systemImage: "tray.full.fill")
                Button("Open Files app", systemImage: "folder") { if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) } }
                Button("Refresh Upload Inbox", systemImage: "arrow.clockwise") { cloud.refreshLocalInbox() }
            }
            Section("About TGSpeicher 2") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")
                Text("Native SwiftUI iOS client using TDLib directly on-device.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Local Session") { Button("Erase local Telegram login data", systemImage: "trash.fill", role: .destructive) { confirmReset = true } }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Erase local Telegram login data?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase Local Telegram Data", role: .destructive) { telegram.resetAPICredentials() }
            Button("Cancel", role: .cancel) { }
        }
    }
}

struct ProxySettingsView: View {
    @ObservedObject var proxy: TGProxyManager
    @ObservedObject var telegram: TelegramClient
    var body: some View {
        Form {
            Section {
                Toggle("Use Telegram proxy", isOn: $proxy.enabled)
                Picker("Type", selection: $proxy.type) { ForEach(TGProxyType.allCases) { Text($0.label).tag($0) } }
                TextField("Server", text: $proxy.server).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $proxy.portText).keyboardType(.numberPad)
                if proxy.type != .mtproto { TextField("Username", text: $proxy.username) }
                SecureField(proxy.type == .mtproto ? "MTProto secret" : "Password", text: $proxy.secret)
            }
            Section {
                Button("Apply Proxy", systemImage: "checkmark.circle.fill") { proxy.apply(using: telegram) }
                Button("Test Proxy", systemImage: "network") { proxy.ping(using: telegram) }.disabled(proxy.activeProxyID == nil)
                LabeledContent("Status", value: proxy.status)
            }
        }.navigationTitle("Telegram Proxy")
    }
}

struct NewFolderSheet: View {
    @Binding var name: String; let onCreate: () -> Void; let onCancel: () -> Void
    var body: some View { NavigationStack { Form { TextField("Folder name", text: $name) }.navigationTitle("New Folder").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }; ToolbarItem(placement: .confirmationAction) { Button("Create", action: onCreate).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } }.presentationDetents([.medium]) }
}

struct RemoteImportSheet: View {
    let folderID: UUID?; @ObservedObject var queue: UploadQueueManager; @ObservedObject var importer: RemoteURLImporter; let onDismiss: () -> Void; @State private var urlText = ""
    var body: some View { NavigationStack { Form { Section("Remote URL") { TextField("https://example.com/file.zip", text: $urlText).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Text("Downloads to the iPhone, then uploads through the durable Telegram queue.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Upload from URL").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onDismiss) }; ToolbarItem(placement: .confirmationAction) { Button("Queue") { importer.start(urlString: urlText, folderID: folderID, queue: queue); onDismiss() }.disabled(urlText.isEmpty || importer.isRunning) } } }.presentationDetents([.medium, .large]) }
}

struct FolderSelectionSheet: View {
    @ObservedObject var cloud: CloudStore; let onSelect: (UUID?) -> Void
    var body: some View { NavigationStack { List { Button { onSelect(nil) } label: { Label("TG Drive", systemImage: "externaldrive.fill.badge.icloud") }; ForEach(cloud.index.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in Button { onSelect(folder.id) } label: { Label(cloud.folderPath(for: folder.id).map(\.name).joined(separator: " / "), systemImage: "folder.fill") } } }.navigationTitle("Move to Folder") }.presentationDetents([.medium, .large]) }
}

struct TagSelectionSheet: View {
    @ObservedObject var cloud: CloudStore; let onApply: (Set<UUID>) -> Void; @State private var selected: Set<UUID>
    init(cloud: CloudStore, initialSelection: Set<UUID> = [], onApply: @escaping (Set<UUID>) -> Void) { self.cloud = cloud; self.onApply = onApply; _selected = State(initialValue: initialSelection) }
    var body: some View { NavigationStack { List { ForEach(cloud.tags) { tag in Button { if selected.contains(tag.id) { selected.remove(tag.id) } else { selected.insert(tag.id) } } label: { HStack { Label(tag.name, systemImage: "tag.fill").foregroundStyle(.primary); Spacer(); if selected.contains(tag.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) } } } } }.navigationTitle("Set Tags").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Apply") { onApply(selected) } } } }.presentationDetents([.medium, .large]) }
}

struct CompactTransferGlass: View {
    let progress: UploadProgress
    var body: some View { HStack(spacing: 12) { ProgressView(value: progress.fraction).frame(width: 42); VStack(alignment: .leading) { Text(progress.fileName).font(.subheadline.weight(.semibold)).lineLimit(1); Text(progress.status).font(.caption2).foregroundStyle(.secondary) }; Spacer(); Text("\(Int(progress.fraction * 100))%").font(.caption.monospacedDigit()) }.padding(.horizontal, 14).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).shadow(radius: 10, y: 5).frame(maxWidth: 560) }
}

extension CloudFileEntry {
    private var normalizedExtension: String { (name as NSString).pathExtension.lowercased() }

    var symbol: String {
        let ext = normalizedExtension
        if mimeType?.hasPrefix("image/") == true || ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "dng", "raw", "svg"].contains(ext) { return "photo.fill" }
        if mimeType?.hasPrefix("video/") == true || ["mp4", "mov", "m4v", "mkv", "avi", "webm", "hevc", "mpeg", "mpg"].contains(ext) { return "film.fill" }
        if mimeType?.hasPrefix("audio/") == true || ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "alac", "wma"].contains(ext) { return "music.note.list" }
        if ext == "pdf" { return "doc.richtext.fill" }
        if ["doc", "docx", "odt", "rtf", "pages", "txt", "text", "md", "markdown"].contains(ext) { return "doc.text.fill" }
        if ["xls", "xlsx", "csv", "tsv", "ods", "numbers"].contains(ext) { return "tablecells.fill" }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { return "rectangle.on.rectangle.angled" }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"].contains(ext) { return "archivebox.fill" }
        if ["swift", "js", "ts", "jsx", "tsx", "py", "java", "kt", "kts", "c", "h", "cpp", "hpp", "cs", "go", "rs", "php", "rb", "sh", "html", "css", "scss", "json", "xml", "yaml", "yml", "toml"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if ["sqlite", "sqlite3", "db", "sql", "mdb"].contains(ext) { return "cylinder.fill" }
        if ["epub", "mobi", "azw", "azw3"].contains(ext) { return "books.vertical.fill" }
        if ["ttf", "otf", "woff", "woff2"].contains(ext) { return "textformat" }
        if ["usdz", "obj", "stl", "gltf", "glb", "fbx"].contains(ext) { return "cube.fill" }
        if ["ipa", "apk", "app", "dmg", "pkg", "exe", "msi", "jar"].contains(ext) { return "shippingbox.fill" }
        if ["vcf"].contains(ext) { return "person.crop.circle.fill" }
        if ["ics"].contains(ext) { return "calendar" }
        return chunks.count > 1 ? "square.stack.3d.up.fill" : "doc.fill"
    }

    var tint: Color {
        let ext = normalizedExtension
        if isTGImage { return .pink }
        if isTGVideo { return .purple }
        if mimeType?.hasPrefix("audio/") == true || ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "alac", "wma"].contains(ext) { return .orange }
        if ext == "pdf" { return .red }
        if ["xls", "xlsx", "csv", "tsv", "ods", "numbers"].contains(ext) { return .green }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { return .orange }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"].contains(ext) { return .brown }
        if ["swift", "js", "ts", "py", "java", "kt", "c", "cpp", "cs", "go", "rs", "html", "css", "json", "xml", "yaml", "yml"].contains(ext) { return .indigo }
        return .blue
    }

    var typeLabel: String {
        let ext = normalizedExtension
        if isTGImage { return "Image" }
        if isTGVideo { return "Video" }
        if mimeType?.hasPrefix("audio/") == true || ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) { return "Audio" }
        if ext == "pdf" { return "PDF document" }
        if ["xls", "xlsx", "csv", "tsv", "ods", "numbers"].contains(ext) { return "Spreadsheet" }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { return "Presentation" }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"].contains(ext) { return "Archive" }
        if let mimeType, !mimeType.isEmpty { return mimeType }
        return ext.isEmpty ? "File" : ext.uppercased() + " file"
    }
}
