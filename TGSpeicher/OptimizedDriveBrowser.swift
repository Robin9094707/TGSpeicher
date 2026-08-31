import SwiftUI
import Combine

private struct TGDirectoryFolderUsage: Hashable {
    var bytes: Int64 = 0
    var fileCount: Int = 0
    var childFolderCount: Int = 0
}

private struct TGDirectoryPayload {
    var folders: [CloudFolder]
    var files: [CloudFileEntry]
    var folderUsage: [UUID: TGDirectoryFolderUsage]
    var currentUsage: TGDirectoryFolderUsage
    var tagNames: [UUID: String]
}

@MainActor
private final class TGDirectorySnapshotController: ObservableObject {
    @Published private(set) var folders: [CloudFolder] = []
    @Published private(set) var files: [CloudFileEntry] = []
    @Published private(set) var folderUsage: [UUID: TGDirectoryFolderUsage] = [:]
    @Published private(set) var currentUsage = TGDirectoryFolderUsage()
    @Published private(set) var tagNames: [UUID: String] = [:]
    @Published private(set) var isLoading = true

    private let folderID: UUID?
    private var searchText = ""
    private var sortMode: TGDriveSortMode
    private var latestIndex: CloudIndex
    private var cancellables = Set<AnyCancellable>()
    private var pendingRefresh: DispatchWorkItem?
    private var generation = 0

    init(cloud: CloudStore, folderID: UUID?, sortMode: TGDriveSortMode) {
        self.folderID = folderID
        self.sortMode = sortMode
        self.latestIndex = cloud.index

        cloud.$index
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] index in
                guard let self else { return }
                self.latestIndex = index
                self.scheduleRefresh(delay: 0.05)
            }
            .store(in: &cancellables)

        scheduleRefresh(delay: 0)
    }

    func updateSearch(_ value: String) {
        guard searchText != value else { return }
        searchText = value
        scheduleRefresh(delay: 0.18)
    }

    func updateSort(_ value: TGDriveSortMode) {
        guard sortMode != value else { return }
        sortMode = value
        scheduleRefresh(delay: 0.05)
    }

    func refreshNow() {
        scheduleRefresh(delay: 0)
    }

    private func scheduleRefresh(delay: TimeInterval) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.buildSnapshot() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func buildSnapshot() {
        generation += 1
        let token = generation
        let index = latestIndex
        let folderID = folderID
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sort = sortMode

        if folders.isEmpty && files.isEmpty { isLoading = true }

        DispatchQueue.global(qos: .userInitiated).async {
            let payload = Self.makePayload(index: index, folderID: folderID, search: search, sortMode: sort)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.folders = payload.folders
                self.files = payload.files
                self.folderUsage = payload.folderUsage
                self.currentUsage = payload.currentUsage
                self.tagNames = payload.tagNames
                self.isLoading = false
            }
        }
    }

    nonisolated private static func makePayload(
        index: CloudIndex,
        folderID: UUID?,
        search: String,
        sortMode: TGDriveSortMode
    ) -> TGDirectoryPayload {
        let folderByID = Dictionary(uniqueKeysWithValues: index.folders.map { ($0.id, $0) })
        var usage: [UUID: TGDirectoryFolderUsage] = [:]

        for folder in index.folders {
            usage[folder.id, default: TGDirectoryFolderUsage()].childFolderCount += 0
            if let parent = folder.parentID {
                usage[parent, default: TGDirectoryFolderUsage()].childFolderCount += 1
            }
        }

        // Aggregate a file into its folder and every ancestor exactly once.
        // This replaces the old repeated recursive scans performed by every folder row.
        for file in index.files {
            guard var current = file.folderID else { continue }
            var visited = Set<UUID>()
            var depth = 0
            while !visited.contains(current), depth < 256 {
                visited.insert(current)
                usage[current, default: TGDirectoryFolderUsage()].bytes += max(0, file.totalSize)
                usage[current, default: TGDirectoryFolderUsage()].fileCount += 1
                guard let parent = folderByID[current]?.parentID else { break }
                current = parent
                depth += 1
            }
        }

        var directFolders = index.folders.filter { $0.parentID == folderID }
        directFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let tags = Dictionary(uniqueKeysWithValues: index.tags.map { ($0.id, $0.name) })
        let matchingTagIDs: Set<UUID>
        if search.isEmpty {
            matchingTagIDs = []
        } else {
            matchingTagIDs = Set(index.tags.filter { $0.name.localizedCaseInsensitiveContains(search) }.map(\.id))
            directFolders.removeAll { !$0.name.localizedCaseInsensitiveContains(search) }
        }

        var directFiles = index.files.filter { $0.folderID == folderID }
        if !search.isEmpty {
            directFiles.removeAll { file in
                !file.name.localizedCaseInsensitiveContains(search) && matchingTagIDs.isDisjoint(with: file.tagIDs)
            }
        }
        directFiles = sortMode.sort(directFiles)

        let current: TGDirectoryFolderUsage
        if let folderID {
            current = usage[folderID] ?? TGDirectoryFolderUsage()
        } else {
            current = TGDirectoryFolderUsage(
                bytes: index.files.reduce(Int64(0)) { $0 + max(0, $1.totalSize) },
                fileCount: index.files.count,
                childFolderCount: index.folders.filter { $0.parentID == nil }.count
            )
        }

        return TGDirectoryPayload(
            folders: directFolders,
            files: directFiles,
            folderUsage: usage,
            currentUsage: current,
            tagNames: tags
        )
    }
}

struct OptimizedDriveBrowserV2: View {
    let folderID: UUID?
    let title: String
    let cloud: CloudStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var remoteImporter: RemoteURLImporter

    @StateObject private var directory: TGDirectorySnapshotController
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
    @State private var visibleFolderLimit = 80
    @State private var visibleFileLimit = 120

    init(
        folderID: UUID?,
        title: String,
        cloud: CloudStore,
        preferences: AppPreferences,
        queue: UploadQueueManager,
        remoteImporter: RemoteURLImporter
    ) {
        self.folderID = folderID
        self.title = title
        self.cloud = cloud
        self.preferences = preferences
        self.queue = queue
        self.remoteImporter = remoteImporter
        _directory = StateObject(wrappedValue: TGDirectorySnapshotController(
            cloud: cloud,
            folderID: folderID,
            sortMode: preferences.sortMode
        ))
    }

    private var visibleFolders: ArraySlice<CloudFolder> {
        directory.folders.prefix(visibleFolderLimit)
    }

    private var visibleFiles: ArraySlice<CloudFileEntry> {
        directory.files.prefix(visibleFileLimit)
    }

    var body: some View {
        Group {
            if preferences.driveViewMode == .grid { gridBody }
            else { listBody }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(folderID == nil ? .large : .inline)
        .searchable(text: $searchText, prompt: "Files, folders or tags")
        .onChange(of: searchText) { _, value in
            visibleFolderLimit = 80
            visibleFileLimit = 120
            directory.updateSearch(value)
        }
        .onChange(of: preferences.sortMode) { _, value in
            visibleFileLimit = 120
            directory.updateSort(value)
        }
        .toolbar { browserToolbar }
        .safeAreaInset(edge: .bottom) { bulkBar }
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

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
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

    @ViewBuilder
    private var bulkBar: some View {
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

    private var selectedEntries: [CloudFileEntry] {
        cloud.index.files.filter { selectedFiles.contains($0.id) }
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                browserHeader
                    .padding(.bottom, 10)

                if directory.isLoading && directory.folders.isEmpty && directory.files.isEmpty {
                    loadingState
                } else if directory.folders.isEmpty && directory.files.isEmpty {
                    EmptyDriveState(showUpload: { showingPicker = true }, showFolder: { showingNewFolder = true })
                } else {
                    if !visibleFolders.isEmpty {
                        lightweightSectionTitle("Folders", count: directory.folders.count)
                        ForEach(visibleFolders) { folder in
                            NavigationLink {
                                OptimizedDriveBrowserV2(
                                    folderID: folder.id,
                                    title: folder.name,
                                    cloud: cloud,
                                    preferences: preferences,
                                    queue: queue,
                                    remoteImporter: remoteImporter
                                )
                            } label: {
                                OptimizedFolderRow(
                                    folder: folder,
                                    usage: directory.folderUsage[folder.id] ?? TGDirectoryFolderUsage()
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Empty Folder", systemImage: "trash", role: .destructive) { cloud.deleteFolder(folder) }
                            }
                        }
                        if directory.folders.count > visibleFolderLimit {
                            ProgressiveLoadSentinel(text: "More folders") {
                                visibleFolderLimit = min(directory.folders.count, visibleFolderLimit + 80)
                            }
                        }
                    }

                    if !visibleFiles.isEmpty {
                        lightweightSectionTitle("Files", count: directory.files.count)
                            .padding(.top, visibleFolders.isEmpty ? 0 : 8)
                        ForEach(visibleFiles) { file in
                            if isSelecting {
                                Button { toggleSelection(file.id) } label: {
                                    OptimizedFileRow(
                                        file: file,
                                        tagName: firstTagName(file),
                                        selected: selectedFiles.contains(file.id)
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    FileDetailV2(fileID: file.id, cloud: cloud)
                                } label: {
                                    OptimizedFileRow(file: file, tagName: firstTagName(file), selected: false)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Download", systemImage: "arrow.down.doc") { cloud.downloadAndReassemble(file) }
                                    Button("Delete from Telegram", systemImage: "trash", role: .destructive) { cloud.deleteFileFromTelegram(file) }
                                }
                            }
                        }
                        if directory.files.count > visibleFileLimit {
                            ProgressiveLoadSentinel(text: "More files") {
                                visibleFileLimit = min(directory.files.count, visibleFileLimit + 120)
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
            LazyVStack(spacing: 12) {
                browserHeader

                if directory.isLoading && directory.folders.isEmpty && directory.files.isEmpty {
                    loadingState
                } else if directory.folders.isEmpty && directory.files.isEmpty {
                    EmptyDriveState(showUpload: { showingPicker = true }, showFolder: { showingNewFolder = true })
                } else {
                    let minWidth = 145.0 * preferences.gridScale
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10)], spacing: 10) {
                        ForEach(visibleFolders) { folder in
                            NavigationLink {
                                OptimizedDriveBrowserV2(
                                    folderID: folder.id,
                                    title: folder.name,
                                    cloud: cloud,
                                    preferences: preferences,
                                    queue: queue,
                                    remoteImporter: remoteImporter
                                )
                            } label: {
                                OptimizedFolderTile(folder: folder, usage: directory.folderUsage[folder.id] ?? TGDirectoryFolderUsage())
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(visibleFiles) { file in
                            if isSelecting {
                                Button { toggleSelection(file.id) } label: {
                                    OptimizedFileTile(file: file, tagName: firstTagName(file), selected: selectedFiles.contains(file.id))
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink { FileDetailV2(fileID: file.id, cloud: cloud) } label: {
                                    OptimizedFileTile(file: file, tagName: firstTagName(file), selected: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if directory.folders.count > visibleFolderLimit || directory.files.count > visibleFileLimit {
                        ProgressiveLoadSentinel(text: "Load next items") {
                            visibleFolderLimit = min(directory.folders.count, visibleFolderLimit + 80)
                            visibleFileLimit = min(directory.files.count, visibleFileLimit + 120)
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
                OptimizedMiniMetric(title: "Files", value: "\(directory.currentUsage.fileCount)", icon: "doc.fill")
                OptimizedMiniMetric(title: "Size", value: directory.currentUsage.bytes.byteCountString, icon: "externaldrive.fill")
                OptimizedMiniMetric(title: "Visible", value: "\(min(directory.files.count, visibleFileLimit))", icon: "eye.fill")
            }

            HStack(spacing: 8) {
                Image(systemName: directory.isLoading ? "hourglass" : (folderID == nil ? "checkmark.icloud.fill" : "folder.fill"))
                    .foregroundStyle(folderID == nil ? .blue : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderID == nil ? "Telegram cloud workspace" : "Lazy folder view")
                        .font(.subheadline.weight(.semibold))
                    Text(directory.isLoading
                         ? "Building an optimized directory snapshot…"
                         : "Only the visible part is rendered; more items load while scrolling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if directory.isLoading { ProgressView().controlSize(.small) }
            }
            .tgBrowserInfoCard()
        }
        .padding(.top, 4)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Opening folder efficiently…")
                .font(.subheadline.weight(.medium))
            Text("TGSpeicher is indexing this level off the main thread.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func firstTagName(_ file: CloudFileEntry) -> String? {
        for id in file.tagIDs {
            if let name = directory.tagNames[id] { return name }
        }
        return nil
    }

    private func lightweightSectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedFiles.contains(id) { selectedFiles.remove(id) }
        else { selectedFiles.insert(id) }
        preferences.performHaptic()
    }
}

private struct OptimizedMiniMetric: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(.blue)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct OptimizedFolderRow: View {
    let folder: CloudFolder
    let usage: TGDirectoryFolderUsage

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.orange.opacity(0.14))
                Image(systemName: "folder.fill").font(.body).foregroundStyle(.orange)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(usage.fileCount) files • \(usage.bytes.byteCountString)" + (usage.childFolderCount > 0 ? " • \(usage.childFolderCount) folders" : ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 53)
        }
    }
}

private struct OptimizedFileRow: View {
    let file: CloudFileEntry
    let tagName: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.blue.opacity(0.11))
                Image(systemName: file.symbol).font(.body).foregroundStyle(.blue)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 3) {
                    Text(file.totalSize.byteCountString)
                    if file.chunks.count > 1 { Text("• \(file.chunks.count) parts") }
                    if let tagName { Text("• #\(tagName)") }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(selected ? Color.blue : Color.secondary)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 53)
        }
    }
}

private struct OptimizedFolderTile: View {
    let folder: CloudFolder
    let usage: TGDirectoryFolderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.fill").font(.title).foregroundStyle(.orange)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            Text(folder.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
            Text("\(usage.fileCount) files • \(usage.bytes.byteCountString)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OptimizedFileTile: View {
    let file: CloudFileEntry
    let tagName: String?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: file.symbol).font(.title).foregroundStyle(.blue)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            }
            Text(file.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
            Text(file.totalSize.byteCountString).font(.caption2).foregroundStyle(.secondary)
            if let tagName {
                Text("#\(tagName)").font(.caption2.weight(.semibold)).foregroundStyle(.blue).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ProgressiveLoadSentinel: View {
    let text: String
    let load: () -> Void
    @State private var didTrigger = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            guard !didTrigger else { return }
            didTrigger = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { load() }
        }
    }
}
