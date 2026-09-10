import SwiftUI

// MARK: - File Detail / Preview

struct FileDetailV2: View {
    @EnvironmentObject private var music: MusicPlayer
    let fileID: UUID
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: CloudStore
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var showingPreview = false
    @State private var showingCloudPreview = false
    @State private var previewAfterDownload = false

    private var file: CloudFileEntry? { cloud.index.files.first { $0.id == fileID } }
    private var localURL: URL? {
        guard let file else { return nil }
        return TGLocalDownloads.matching(file, preferred: cloud.lastExportURL)
    }

    var body: some View {
        ScrollView {
            if let file {
                VStack(spacing: 12) {
                    VStack(spacing: 11) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(file.tint.opacity(0.12))
                            Image(systemName: file.symbol).font(.system(size: 44)).foregroundStyle(file.tint)
                        }
                        .frame(width: 78, height: 78)

                        Text(file.name).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(file.totalSize.byteCountString).foregroundStyle(.secondary)

                        if file.isMusic {
                            HStack {
                                Button("Musik abspielen", systemImage: "play.circle.fill") { music.play([file.id]); music.showingPlayer = true }.buttonStyle(.borderedProminent)
                                Menu { MusicTrackMenu(file: file, cloud: cloud) } label: { Image(systemName: "music.note.list").accessibilityLabel("Musik-Aktionen") }.buttonStyle(.bordered)
                            }.disabled(!cloud.recoveryReady)
                        }
                        if file.isTGImage || file.isTGVideo {
                            Button(file.isTGVideo ? "Originalvideo öffnen" : "Telegram-Vorschau", systemImage: file.isTGVideo ? "play.circle.fill" : "photo.fill") {
                                showingCloudPreview = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(file.chunks.isEmpty)
                        }

                        HStack {
                            Button(localURL == nil ? "Herunterladen" : "Aktualisieren", systemImage: "arrow.down.doc.fill") {
                                previewAfterDownload = false
                                cloud.downloadAndReassemble(file)
                            }
                            .buttonStyle(.bordered)
                            .disabled(cloud.isDownloading)

                            if localURL != nil {
                                Button("Vorschau", systemImage: "eye.fill") { showingPreview = true }
                                    .buttonStyle(.bordered)
                            } else if !file.isTGImage && !file.isTGVideo {
                                Button("Vorschau", systemImage: "eye.fill") {
                                    previewAfterDownload = true
                                    cloud.downloadAndReassemble(file)
                                }
                                .buttonStyle(.bordered)
                                .disabled(cloud.isDownloading)
                            }
                        }

                        if let localURL {
                            ShareLink(item: localURL) {
                                Label("Teilen / Öffnen in …", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Information", systemImage: "info.circle.fill").font(.headline)
                        LabeledContent("Größe", value: file.totalSize.byteCountString)
                        LabeledContent("Dateiteile", value: "\(file.chunks.count)")
                        LabeledContent("Typ", value: file.typeLabel)
                        LabeledContent("Erstellt", value: file.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Geändert", value: file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Telegram-Quelle", value: file.telegramChatID == nil || file.telegramChatID == cloud.telegram.savedMessagesChatID ? "Gespeichertes" : "Sicherungskanal")
                        if let folderID = file.folderID {
                            let path = cloud.folderPath(for: folderID).map(\.name).joined(separator: " / ")
                            LabeledContent("Ordner", value: path.isEmpty ? "Meine Dateien" : path)
                        } else {
                            LabeledContent("Ordner", value: "Meine Dateien")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tags", systemImage: "tag.fill").font(.headline)
                        if cloud.tags.isEmpty {
                            Text("Noch keine Tags. Erstelle welche in den Einstellungen.").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ForEach(cloud.tags) { tag in
                                Button {
                                    var ids = file.tagIDs
                                    if ids.contains(tag.id) { ids.removeAll { $0 == tag.id } }
                                    else { ids.append(tag.id) }
                                    cloud.setTags(ids, for: file)
                                } label: {
                                    HStack {
                                        Text(tag.name).foregroundStyle(.primary)
                                        Spacer()
                                        if file.tagIDs.contains(tag.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Speicherort", systemImage: "folder.fill").font(.headline).foregroundStyle(.orange)
                        Picker("Ordner", selection: Binding(
                            get: { file.folderID },
                            set: { cloud.moveFile(file, to: $0) }
                        )) {
                            Text("Meine Dateien").tag(UUID?.none)
                            ForEach(cloud.index.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                                Text(cloud.folderPath(for: folder.id).map(\.name).joined(separator: " / ")).tag(Optional(folder.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Umbenennen", systemImage: "pencil").font(.headline)
                        TextField(file.name, text: $renameText).textFieldStyle(.roundedBorder)
                        Button("Datei umbenennen") {
                            cloud.renameFile(file, to: renameText)
                            renameText = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Integrität", systemImage: "checkmark.shield.fill").font(.headline)
                        LabeledContent("Telegram-Dateiteile", value: "\(file.chunks.count)")
                        if let hash = file.sha256 {
                            Text(hash).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                        } else {
                            Text("Für diese Datei ist keine vollständige SHA-256-Prüfsumme gespeichert.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    Button(cloud.deletingFileIDs.contains(fileID) ? "Löschung vorgemerkt …" : "Aus Telegram löschen", systemImage: "trash.fill", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.bordered)
                        .disabled(cloud.deletingFileIDs.contains(fileID) || !cloud.recoveryReady)
                }
                .padding(14)
            } else {
                ContentUnavailableView("Datei nicht gefunden", systemImage: "doc.questionmark")
            }
        }
        .onChange(of: file == nil) { _, removed in if removed { dismiss() } }
        .navigationTitle("Datei")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: cloud.isDownloading) { _, downloading in
            if !downloading, previewAfterDownload, localURL != nil {
                previewAfterDownload = false
                showingPreview = true
            }
        }
        .sheet(isPresented: $showingPreview) {
            if let localURL { QuickLookPreviewSheet(url: localURL) }
        }
        .sheet(isPresented: $showingCloudPreview) {
            if let file { CloudMediaPreviewSheet(file: file, cloud: cloud) }
        }
        .alert("Datei löschen?", isPresented: $confirmDelete, presenting: file) { file in
            Button("Ja", role: .destructive) { cloud.deleteFileFromTelegram(file) }
            Button("Nein", role: .cancel) { }
        } message: { file in Text("„\(file.name)“ aus Telegram löschen?") }
    }
}

// MARK: - Search

struct SearchHubV2: View {
    @ObservedObject var cloud: CloudStore
    @ObservedObject var preferences: AppPreferences
    @State private var query = ""

    private var results: [CloudFileEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return preferences.sortMode.sort(Array(cloud.index.files.prefix(30)))
        }
        return preferences.sortMode.sort(cloud.searchFiles(query))
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section("Tags") {
                    if cloud.tags.isEmpty {
                        Text("Noch keine Tags").foregroundStyle(.secondary)
                    } else {
                        ForEach(cloud.tags) { tag in
                            NavigationLink {
                                TagFilesView(tag: tag, cloud: cloud)
                            } label: {
                                HStack {
                                    Label(tag.name, systemImage: "tag.fill")
                                    Spacer()
                                    Text("\(cloud.files(tagged: tag.id).count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section(query.isEmpty ? "Zuletzt verwendete Dateien" : "Ergebnisse") {
                if results.isEmpty {
                    ContentUnavailableView("Keine Ergebnisse", systemImage: "magnifyingglass", description: Text("Keine Dateien für „\(query)“ gefunden."))
                } else {
                    ForEach(results) { file in
                        NavigationLink {
                            FileDetailV2(fileID: file.id, cloud: cloud)
                        } label: {
                            FileRow(file: file, cloud: cloud)
                        }
                    }
                }
            }
        }
        .navigationTitle("Suchen")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name oder Tag")
    }
}



