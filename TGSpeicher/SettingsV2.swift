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
            Section("Darstellung") {
                Picker("Darstellung", selection: $preferences.appearance) { ForEach(TGAppearance.allCases) { Text($0.label).tag($0) } }
                Picker("Standardansicht", selection: $preferences.driveViewMode) { ForEach(TGDriveViewMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) } }
                Picker("Standardsortierung", selection: $preferences.sortMode) { ForEach(TGDriveSortMode.allCases) { Text($0.label).tag($0) } }
                if preferences.driveViewMode == .grid { Slider(value: $preferences.gridScale, in: 0.5...2.0) }
                Toggle("Haptisches Feedback", isOn: $preferences.hapticsEnabled)
            }
            Section("Übertragungen") {
                Toggle("Mitteilungen zu Übertragungen", isOn: $preferences.transferNotifications)
                Toggle("Bildschirm bei Übertragungen eingeschaltet lassen", isOn: $preferences.keepScreenAwakeDuringTransfers)
                Toggle("Nur über WLAN hochladen", isOn: $preferences.wifiOnlyUploads)
                Button("Mitteilungen erlauben", systemImage: "bell.badge") { runtime.requestNotificationPermission() }
                NavigationLink("Offline-Dateien", destination: LocalDownloadsView())
                LabeledContent("Wartende Uploads", value: "\(queue.queuedCount)")
            }
            Section {
                LabeledContent("Kontotyp", value: telegram.premiumLabel)
                Toggle("Premium-Dateigröße automatisch nutzen", isOn: $telegram.usePremiumUploads)
                LabeledContent("Neue Dateiteile bis", value: telegram.maxUploadBytes.byteCountString)
                Button("Kontostatus aktualisieren", systemImage: "arrow.clockwise") { telegram.refreshUploadLimits(force: true) }
                    .disabled(telegram.isCheckingUploadLimits)
                Text(telegram.uploadLimitStatus).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Dateigröße & Premium") } footer: {
                Text("Mit erkanntem Premium bis zu 4 GB, sonst bis zu 2 GB pro Datei. Größere Dateien werden verlustfrei aufgeteilt. Telegram kann niedrigere Grenzen vorgeben. Bereits begonnene Uploads behalten ihre ursprünglichen Teilgrenzen.")
            }
            Section("Tags & Organisation") { NavigationLink { TagsView(cloud: cloud) } label: { LabeledContent("Tags verwalten", value: "\(cloud.tags.count)") } }
            Section("Telegram") {
                LabeledContent("Konto", value: telegram.accountName)
                LabeledContent("Anmeldung", value: telegram.authorizationStage == .ready ? "Verbunden" : "Nicht verbunden")
                Button("Von Telegram abmelden", systemImage: "rectangle.portrait.and.arrow.right") { telegram.logOut() }
            }
            Section("Datensicherung") {
                NavigationLink { RecoveryCenterView(cloud: cloud) } label: {
                    Label("Sichern & Wiederherstellen", systemImage: "checkmark.shield")
                }
                Text(cloud.catalogStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Netzwerk") {
                LabeledContent("Verbindung", value: network.isConnected ? network.interfaceName : "Offline")
                NavigationLink { ProxySettingsView(proxy: proxy, telegram: telegram) } label: { LabeledContent("Telegram-Proxy", value: proxy.status) }
            }
            Section("Dateien-App") {
                Label("Auf meinem iPhone › TGSpeicher › Upload Inbox", systemImage: "folder.badge.plus")
                Label("Auf meinem iPhone › TGSpeicher › Downloads", systemImage: "folder.fill")
                Label("Auf meinem iPhone › TGSpeicher › Transfer Queue", systemImage: "tray.full.fill")
                Button("Dateien-App öffnen", systemImage: "folder") { if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) } }
                Button("Datei-Eingang aktualisieren", systemImage: "arrow.clockwise") { cloud.refreshLocalInbox() }
            }
            Section("Über TGSpeicher") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")
                Text("Deine Dateien und Medien direkt in deinem Telegram-Konto.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Lokale Sitzung") { Button("Lokale Telegram-Anmeldedaten löschen", systemImage: "trash.fill", role: .destructive) { confirmReset = true } }
        }
        .navigationTitle("Einstellungen")
        .confirmationDialog("Lokale Telegram-Anmeldedaten löschen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Lokale Telegram-Daten löschen", role: .destructive) { telegram.resetAPICredentials() }
            Button("Abbrechen", role: .cancel) { }
        }
    }
}

struct ProxySettingsView: View {
    @ObservedObject var proxy: TGProxyManager
    @ObservedObject var telegram: TelegramClient
    var body: some View {
        Form {
            Section {
                Toggle("Telegram-Proxy verwenden", isOn: $proxy.enabled)
                Picker("Typ", selection: $proxy.type) { ForEach(TGProxyType.allCases) { Text($0.label).tag($0) } }
                TextField("Server", text: $proxy.server).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $proxy.portText).keyboardType(.numberPad)
                if proxy.type != .mtproto { TextField("Benutzername", text: $proxy.username) }
                SecureField(proxy.type == .mtproto ? "MTProto-Schlüssel" : "Passwort", text: $proxy.secret)
            }
            Section {
                Button("Proxy übernehmen", systemImage: "checkmark.circle.fill") { proxy.apply(using: telegram) }
                Button("Proxy testen", systemImage: "network") { proxy.ping(using: telegram) }.disabled(proxy.activeProxyID == nil)
                LabeledContent("Status", value: proxy.status)
            }
        }.navigationTitle("Telegram-Proxy")
    }
}

struct NewFolderSheet: View {
    @Binding var name: String; let onCreate: () -> Void; let onCancel: () -> Void
    var body: some View { NavigationStack { Form { TextField("Ordnername", text: $name) }.navigationTitle("Neuer Ordner").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", action: onCancel) }; ToolbarItem(placement: .confirmationAction) { Button("Erstellen", action: onCreate).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } }.presentationDetents([.medium]) }
}

struct RemoteImportSheet: View {
    let folderID: UUID?; @ObservedObject var queue: UploadQueueManager; @ObservedObject var importer: RemoteURLImporter; let onDismiss: () -> Void; @State private var urlText = ""
    var body: some View { NavigationStack { Form { Section("Download-Link") { TextField("https://example.com/file.zip", text: $urlText).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Text("Die Datei wird zuerst aufs iPhone geladen und anschließend über die gespeicherte Warteschlange in Telegram gesichert.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Von einem Link hochladen").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: onDismiss) }; ToolbarItem(placement: .confirmationAction) { Button("Warteschlange") { importer.start(urlString: urlText, folderID: folderID, queue: queue); onDismiss() }.disabled(urlText.isEmpty || importer.isRunning) } } }.presentationDetents([.medium, .large]) }
}

struct FolderSelectionSheet: View {
    @ObservedObject var cloud: CloudStore; let onSelect: (UUID?) -> Void
    var body: some View { NavigationStack { List { Button { onSelect(nil) } label: { Label("Meine Dateien", systemImage: "externaldrive.fill.badge.icloud") }; ForEach(cloud.index.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in Button { onSelect(folder.id) } label: { Label(cloud.folderPath(for: folder.id).map(\.name).joined(separator: " / "), systemImage: "folder.fill") } } }.navigationTitle("In Ordner verschieben") }.presentationDetents([.medium, .large]) }
}

struct TagSelectionSheet: View {
    @ObservedObject var cloud: CloudStore; let onApply: (Set<UUID>) -> Void; @State private var selected: Set<UUID>
    init(cloud: CloudStore, initialSelection: Set<UUID> = [], onApply: @escaping (Set<UUID>) -> Void) { self.cloud = cloud; self.onApply = onApply; _selected = State(initialValue: initialSelection) }
    var body: some View { NavigationStack { List { ForEach(cloud.tags) { tag in Button { if selected.contains(tag.id) { selected.remove(tag.id) } else { selected.insert(tag.id) } } label: { HStack { Label(tag.name, systemImage: "tag.fill").foregroundStyle(.primary); Spacer(); if selected.contains(tag.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) } } } } }.navigationTitle("Tags zuweisen").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Übernehmen") { onApply(selected) } } } }.presentationDetents([.medium, .large]) }
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
        if isTGImage { return "Bild" }
        if isTGVideo { return "Video" }
        if mimeType?.hasPrefix("audio/") == true || ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) { return "Audio" }
        if ext == "pdf" { return "PDF-Dokument" }
        if ["xls", "xlsx", "csv", "tsv", "ods", "numbers"].contains(ext) { return "Tabelle" }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { return "Präsentation" }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"].contains(ext) { return "Archiv" }
        if let mimeType, !mimeType.isEmpty { return mimeType }
        return ext.isEmpty ? "Datei" : ext.uppercased() + "-Datei"
    }
}

