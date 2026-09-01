import SwiftUI

// MARK: - Drive Browser

struct DriveBrowserV2: View {
    let folderID: UUID?
    let title: String
    @ObservedObject var cloud: CloudStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var remoteImporter: RemoteURLImporter

    @State private var searchText = ""
    @State private var showingPicker = false
    @State private var showingNewFolder = false
    @State private var showingRemoteURL = false
    @State private var folderName = ""
    @State private var isSelecting = false
    @State private var selectedFiles = Set<UUID>()
    @State private var showingBulkMove = false
    @State private var showingBulkTags = false
    @State private var confirmBulkDelete = false

    private var folders: [CloudFolder] {
        let value = cloud.children(of: folderID)
        guard !searchText.isEmpty else { return value }
        return value.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var files: [CloudFileEntry] {
        let value = cloud.files(in: folderID)
        let filtered = searchText.isEmpty ? value : value.filter { file in
            if file.name.localizedCaseInsensitiveContains(searchText) { return true }
            return cloud.tags
                .filter { file.tagIDs.contains($0.id) }
                .contains { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return preferences.sortMode.sort(filtered)
    }

    var body: some View {
        Group {
            if preferences.driveViewMode == .grid { gridBody }
            else { listBody }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(folderID == nil ? .large : .inline)
        .searchable(text: $searchText, prompt: "Files, folders or tags")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selectedFiles.removeAll() }
                    preferences.performHaptic()
                } label: {
                    Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                }

                Menu {
                    Picker("View", selection: $preferences.driveViewMode) {
                        ForEach(TGDriveViewMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    Picker("Sort", selection: $preferences.sortMode) {
                        ForEach(TGDriveSortMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    Divider()
                    Button("Upload Files", systemImage: "arrow.up.doc") { showingPicker = true }
                    Button("Upload from URL", systemImage: "link.badge.plus") { showingRemoteURL = true }
                    Button("New Folder", systemImage: "folder.badge.plus") { showingNewFolder = true }
                    Divider()
                    Button("Refresh from Telegram", systemImage: "arrow.triangle.2.circlepath") { cloud.bootstrapFromTelegram() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selectedFiles.isEmpty {
                BulkActionBar(
                    count: selectedFiles.count,
                    onMove: { showingBulkMove = true },
                    onTags: { showingBulkTags = true },
                    onDelete: { confirmBulkDelete = true },
                    onCancel: { selectedFiles.removeAll(); isSelecting = false }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .fullScreenCover(isPresented: $showingPicker) {
            TGDocumentPicker(
                allowsMultipleSelection: true,
                onPicked: { urls in
                    showingPicker = false
                    queue.enqueue(urls: urls, folderID: folderID)
                },
                onCancel: { showingPicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderSheet(name: $folderName) {
                cloud.createFolder(name: folderName, parentID: folderID)
                folderName = ""
                showingNewFolder = false
                preferences.performHaptic(.medium)
            } onCancel: {
                folderName = ""
                showingNewFolder = false
            }
        }
        .sheet(isPresented: $showingRemoteURL) {
            RemoteImportSheet(folderID: folderID, queue: queue, importer: remoteImporter) { showingRemoteURL = false }
        }
        .sheet(isPresented: $showingBulkMove) {
            FolderSelectionSheet(cloud: cloud) { destination in
                selectedEntries.forEach { cloud.moveFile($0, to: destination) }
                selectedFiles.removeAll(); isSelecting = false; showingBulkMove = false
            }
        }
        .sheet(isPresented: $showingBulkTags) {
            TagSelectionSheet(cloud: cloud) { tags in
                selectedEntries.forEach { cloud.setTags(Array(tags), for: $0) }
                selectedFiles.removeAll(); isSelecting = false; showingBulkTags = false
            }
        }
        .confirmationDialog("Delete \(selectedFiles.count) selected file(s) from Telegram?", isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("Delete from Telegram", role: .destructive) {
                let entries = selectedEntries
                selectedFiles.removeAll(); isSelecting = false
                entries.forEach(cloud.deleteFileFromTelegram)
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var selectedEntries: [CloudFileEntry] {
        cloud.index.files.filter { selectedFiles.contains($0.id) }
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                browserHeader
                if folders.isEmpty && files.isEmpty {
                    EmptyDriveState(showUpload: { showingPicker = true }, showFolder: { showingNewFolder = true })
                } else {
                    ForEach(folders) { folder in
                        NavigationLink {
                            DriveBrowserV2(
                                folderID: folder.id,
                                title: folder.name,
                                cloud: cloud,
                                preferences: preferences,
                                queue: queue,
                                remoteImporter: remoteImporter
                            )
                        } label: {
                            FolderRowV2(folder: folder, cloud: cloud)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Empty Folder", systemImage: "trash", role: .destructive) { cloud.deleteFolder(folder) }
                        }
                    }

                    ForEach(files) { file in
                        if isSelecting {
                            Button { toggleSelection(file.id) } label: {
                                FileRowV2(file: file, cloud: cloud, selected: selectedFiles.contains(file.id))
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                FileDetailV2(fileID: file.id, cloud: cloud)
                            } label: {
                                FileRowV2(file: file, cloud: cloud, selected: false)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Download", systemImage: "arrow.down.doc") { cloud.downloadAndReassemble(file) }
                                Button("Delete from Telegram", systemImage: "trash", role: .destructive) { cloud.deleteFileFromTelegram(file) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 110)
        }
        .refreshable { cloud.bootstrapFromTelegram() }
    }

    private var gridBody: some View {
        ScrollView {
            VStack(spacing: 12) {
                browserHeader
                if folders.isEmpty && files.isEmpty {
                    EmptyDriveState(showUpload: { showingPicker = true }, showFolder: { showingNewFolder = true })
                } else {
                    let minWidth = 145.0 * preferences.gridScale
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10)], spacing: 10) {
                        ForEach(folders) { folder in
                            NavigationLink {
                                DriveBrowserV2(
                                    folderID: folder.id,
                                    title: folder.name,
                                    cloud: cloud,
                                    preferences: preferences,
                                    queue: queue,
                                    remoteImporter: remoteImporter
                                )
                            } label: { FolderTileV2(folder: folder, cloud: cloud) }
                            .buttonStyle(.plain)
                        }
                        ForEach(files) { file in
                            if isSelecting {
                                Button { toggleSelection(file.id) } label: {
                                    FileTileV2(file: file, cloud: cloud, selected: selectedFiles.contains(file.id))
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink { FileDetailV2(fileID: file.id, cloud: cloud) } label: {
                                    FileTileV2(file: file, cloud: cloud, selected: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 110)
        }
        .refreshable { cloud.bootstrapFromTelegram() }
    }

    private var browserHeader: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                MiniMetric(title: "Files", value: "\(cloud.recursiveFolderFileCount(folderID))", icon: "doc.fill")
                MiniMetric(title: "Size", value: cloud.recursiveFolderBytes(folderID).byteCountString, icon: "externaldrive.fill")
                MiniMetric(title: "Queue", value: "\(queue.queuedCount)", icon: "arrow.up.circle.fill")
            }
            if folderID == nil {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Telegram cloud workspace").font(.headline)
                        Text("\(cloud.totalTrackedBytes.byteCountString) across \(cloud.index.files.count) tracked files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: cloud.isCatalogSyncing ? "arrow.triangle.2.circlepath.icloud.fill" : "checkmark.icloud.fill")
                        .font(.title2).foregroundStyle(cloud.isCatalogSyncing ? .blue : .green)
                }
                .tgBrowserInfoCard()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    Text("This folder including subfolders: \(cloud.recursiveFolderFileCount(folderID)) files • \(cloud.recursiveFolderBytes(folderID).byteCountString)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .tgBrowserInfoCard()
            }
        }
        .padding(.top, 4)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedFiles.contains(id) { selectedFiles.remove(id) }
        else { selectedFiles.insert(id) }
        preferences.performHaptic()
    }
}

struct MiniMetric: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(.blue)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct FolderRowV2: View {
    let folder: CloudFolder
    @ObservedObject var cloud: CloudStore
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.14))
                Image(systemName: "folder.fill").font(.title3).foregroundStyle(.orange)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(cloud.recursiveFolderFileCount(folder.id)) files • \(cloud.recursiveFolderBytes(folder.id).byteCountString)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !cloud.children(of: folder.id).isEmpty {
                Text("\(cloud.children(of: folder.id).count)").font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .tgBrowserRowCard()
    }
}

struct FileRowV2: View {
    let file: CloudFileEntry
    @ObservedObject var cloud: CloudStore
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(file.tint.opacity(0.12))
                Image(systemName: file.symbol).font(.title3).foregroundStyle(file.tint)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(file.totalSize.byteCountString)
                    if file.chunks.count > 1 { Text("• \(file.chunks.count) parts") }
                    let tags = cloud.tags.filter { file.tagIDs.contains($0.id) }.map(\.name)
                    if let first = tags.first { Text("• #\(first)") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(selected ? Color.blue : Color.secondary)
                .font(.caption.weight(.semibold))
        }
        .tgBrowserRowCard()
    }
}

struct FolderTileV2: View {
    let folder: CloudFolder
    @ObservedObject var cloud: CloudStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.orange)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            Text(folder.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
            Text("\(cloud.recursiveFolderFileCount(folder.id)) files • \(cloud.recursiveFolderBytes(folder.id).byteCountString)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .tgGlassCard()
    }
}

struct FileTileV2: View {
    let file: CloudFileEntry
    @ObservedObject var cloud: CloudStore
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: file.symbol).font(.largeTitle).foregroundStyle(file.tint)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            }
            Text(file.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
            Text(file.totalSize.byteCountString).font(.caption).foregroundStyle(.secondary)
            let names = cloud.tags.filter { file.tagIDs.contains($0.id) }.map(\.name)
            if !names.isEmpty {
                Text(names.prefix(2).map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.blue).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .tgGlassCard()
    }
}

struct EmptyDriveState: View {
    let showUpload: () -> Void
    let showFolder: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 48)).foregroundStyle(.blue)
            Text("This folder is empty").font(.title3.bold())
            Text("Upload files, add a remote URL, or create a folder. Everything stays linked to your Telegram account.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Upload", systemImage: "arrow.up.doc", action: showUpload).buttonStyle(.borderedProminent)
                Button("Folder", systemImage: "folder.badge.plus", action: showFolder).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .tgGlassCard()
    }
}

struct BulkActionBar: View {
    let count: Int
    let onMove: () -> Void
    let onTags: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(count)").font(.headline).monospacedDigit().frame(minWidth: 28)
            Button(action: onMove) { Image(systemName: "folder") }
            Button(action: onTags) { Image(systemName: "tag") }
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
            Spacer()
            Button("Done", action: onCancel).fontWeight(.semibold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 10, y: 5)
    }
}

private extension View {
    @ViewBuilder
    func tgBrowserRowCard() -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            self
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    func tgBrowserInfoCard() -> some View {
        if #available(iOS 26.0, *) {
            self.padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            self.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
