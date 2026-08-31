import SwiftUI

// MARK: - File Detail / Preview

struct FileDetailV2: View {
    let fileID: UUID
    @ObservedObject var cloud: CloudStore
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var showingPreview = false
    @State private var previewAfterDownload = false

    private var file: CloudFileEntry? { cloud.index.files.first { $0.id == fileID } }
    private var localURL: URL? {
        guard let file else { return nil }
        return TGLocalDownloads.matching(file, preferred: cloud.lastExportURL)
    }

    var body: some View {
        ScrollView {
            if let file {
                VStack(spacing: 14) {
                    VStack(spacing: 12) {
                        Image(systemName: file.symbol).font(.system(size: 48)).foregroundStyle(file.tint)
                        Text(file.name).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(file.totalSize.byteCountString).foregroundStyle(.secondary)
                        HStack {
                            Button(localURL == nil ? "Download" : "Refresh", systemImage: "arrow.down.doc.fill") {
                                previewAfterDownload = false
                                cloud.downloadAndReassemble(file)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(cloud.isDownloading)

                            if localURL != nil {
                                Button("Preview", systemImage: "eye.fill") { showingPreview = true }
                                    .buttonStyle(.bordered)
                            } else {
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
                        Label("Location", systemImage: "folder.fill").font(.headline)
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
                        LabeledContent("Chunks", value: "\(file.chunks.count)")
                        LabeledContent("Modified", value: file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        if let hash = file.sha256 {
                            Text(hash).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
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
        .onChange(of: cloud.isDownloading) { downloading in
            if !downloading, previewAfterDownload, localURL != nil {
                previewAfterDownload = false
                showingPreview = true
            }
        }
        .sheet(isPresented: $showingPreview) {
            if let localURL {
                NavigationStack {
                    QuickLookPreview(url: localURL)
                        .ignoresSafeArea()
                        .navigationTitle(localURL.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
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
