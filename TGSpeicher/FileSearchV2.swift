import SwiftUI

// MARK: - File Detail / Preview

struct FileDetailV2: View {
    let fileID: UUID
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
                            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.blue.opacity(0.12))
                            Image(systemName: file.symbol).font(.system(size: 44)).foregroundStyle(.blue)
                        }
                        .frame(width: 78, height: 78)

                        Text(file.name).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(file.totalSize.byteCountString).foregroundStyle(.secondary)

                        if file.isTGImage || file.isTGVideo {
                            Button(file.isTGVideo ? "Stream from Telegram" : "Cloud Preview", systemImage: file.isTGVideo ? "play.circle.fill" : "photo.fill") {
                                showingCloudPreview = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(file.chunks.isEmpty)
                        }

                        HStack {
                            Button(localURL == nil ? "Download" : "Refresh", systemImage: "arrow.down.doc.fill") {
                                previewAfterDownload = false
                                cloud.downloadAndReassemble(file)
                            }
                            .buttonStyle(file.isTGImage || file.isTGVideo ? .bordered : .borderedProminent)
                            .disabled(cloud.isDownloading)

                            if localURL != nil {
                                Button("Preview", systemImage: "eye.fill") { showingPreview = true }
                                    .buttonStyle(.bordered)
                            } else if !file.isTGImage && !file.isTGVideo {
                                Button("Preview", systemImage: "eye.fill") {
                                    previewAfterDownload = true
                                    cloud.downloadAndReassemble(file)
                                }
                                .buttonStyle(.bordered)
                                .disabled(cloud.isDownloading)
                            }
                        }

                        if let localURL {
                            ShareLink(item: localURL) {
                                Label("Share / Open In…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Information", systemImage: "info.circle.fill").font(.headline)
                        LabeledContent("Size", value: file.totalSize.byteCountString)
                        LabeledContent("Chunks", value: "\(file.chunks.count)")
                        LabeledContent("Type", value: file.mimeType ?? (file.fileExtension.isEmpty ? "Unknown" : file.fileExtension.uppercased()))
                        LabeledContent("Created", value: file.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Modified", value: file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Cloud source", value: "Telegram Saved Messages")
                        if let folderID = file.folderID {
                            let path = cloud.folderPath(for: folderID).map(\.name).joined(separator: " / ")
                            LabeledContent("Folder", value: path.isEmpty ? "TG Drive" : path)
                        } else {
                            LabeledContent("Folder", value: "TG Drive")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tags", systemImage: "tag.fill").font(.headline)
                        if cloud.tags.isEmpty {
                            Text("No tags yet. Create tags in Settings.").font(.subheadline).foregroundStyle(.secondary)
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
                        Label("Location", systemImage: "folder.fill").font(.headline).foregroundStyle(.orange)
                        Picker("Folder", selection: Binding(
                            get: { file.folderID },
                            set: { cloud.moveFile(file, to: $0) }
                        )) {
                            Text("TG Drive").tag(UUID?.none)
                            ForEach(cloud.index.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                                Text(cloud.folderPath(for: folder.id).map(\.name).joined(separator: " / ")).tag(Optional(folder.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Rename", systemImage: "pencil").font(.headline)
                        TextField(file.name, text: $renameText).textFieldStyle(.roundedBorder)
                        Button("Rename File") {
                            cloud.renameFile(file, to: renameText)
                            renameText = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Integrity", systemImage: "checkmark.shield.fill").font(.headline)
                        LabeledContent("Telegram parts", value: "\(file.chunks.count)")
                        if let hash = file.sha256 {
                            Text(hash).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                        } else {
                            Text("No whole-file SHA-256 stored for this entry.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tgGlassCard()

                    Button("Delete from Telegram", systemImage: "trash.fill", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.bordered)
                }
                .padding(14)
            } else {
                ContentUnavailableView("File not found", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle("File")
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
            if let file { CloudMediaPreviewSheet(file: file, telegram: cloud.telegram) }
        }
        .confirmationDialog("Delete this file from Telegram Saved Messages?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let file { Button("Delete from Telegram", role: .destructive) { cloud.deleteFileFromTelegram(file) } }
            Button("Cancel", role: .cancel) { }
        }
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
                        Text("No tags yet").foregroundStyle(.secondary)
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

            Section(query.isEmpty ? "Recent files" : "Results") {
                if results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("No files match \(query)."))
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
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or tag")
    }
}
