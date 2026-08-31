import Foundation
import Combine

struct QueuedUpload: Identifiable, Codable, Hashable {
    enum State: String, Codable {
        case queued
        case uploading
        case failed
        case completed
    }

    let id: UUID
    var localPath: String
    var displayName: String
    var folderID: UUID?
    var tagIDs: [UUID]
    var byteSize: Int64
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var state: State
    var lastError: String?

    init(
        id: UUID = UUID(),
        localPath: String,
        displayName: String,
        folderID: UUID?,
        tagIDs: [UUID],
        byteSize: Int64,
        createdAt: Date = Date(),
        state: State = .queued
    ) {
        self.id = id
        self.localPath = localPath
        self.displayName = displayName
        self.folderID = folderID
        self.tagIDs = tagIDs
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.state = state
    }
}

@MainActor
final class UploadQueueManager: ObservableObject {
    @Published private(set) var items: [QueuedUpload] = []
    @Published var isPaused = false
    @Published private(set) var isPreparingFiles = false
    @Published var lastError: String?

    private let cloud: CloudStore
    private let preferences: AppPreferences
    private let network: TGNetworkMonitor
    private var cancellables = Set<AnyCancellable>()
    private var activeID: UUID?
    private var activeFileCount = 0

    init(cloud: CloudStore, preferences: AppPreferences, network: TGNetworkMonitor) {
        self.cloud = cloud
        self.preferences = preferences
        self.network = network
        load()
        for index in items.indices where items[index].state == .uploading {
            items[index].state = .queued
            items[index].startedAt = nil
        }
        persist()

        cloud.$upload
            .receive(on: RunLoop.main)
            .sink { [weak self] upload in
                guard let self else { return }
                if upload == nil, self.activeID != nil {
                    self.finishActiveUpload()
                } else if upload == nil {
                    self.processNextIfPossible()
                }
            }
            .store(in: &cancellables)

        cloud.telegram.$savedMessagesChatID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.processNextIfPossible() }
            .store(in: &cancellables)

        Publishers.CombineLatest(network.$isConnected, network.$interfaceName)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.processNextIfPossible() }
            .store(in: &cancellables)

        preferences.$wifiOnlyUploads
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.processNextIfPossible() }
            .store(in: &cancellables)
    }

    var queuedCount: Int { items.filter { $0.state == .queued }.count }
    var failedCount: Int { items.filter { $0.state == .failed }.count }
    var activeItem: QueuedUpload? { activeID.flatMap { id in items.first { $0.id == id } } }

    func enqueue(urls: [URL], folderID: UUID?, tagIDs: [UUID] = []) {
        guard !urls.isEmpty else { return }
        isPreparingFiles = true
        lastError = nil

        let root = queueRootURL
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    var result: [QueuedUpload] = []
                    for source in urls {
                        let id = UUID()
                        let itemFolder = root.appendingPathComponent(id.uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                        let preferredName = source.lastPathComponent.isEmpty ? "Upload.bin" : source.lastPathComponent
                        let destination = itemFolder.appendingPathComponent(preferredName)
                        let accessed = source.startAccessingSecurityScopedResource()
                        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                        result.append(
                            QueuedUpload(
                                id: id,
                                localPath: destination.path,
                                displayName: preferredName,
                                folderID: folderID,
                                tagIDs: tagIDs,
                                byteSize: destination.fileByteSize
                            )
                        )
                    }
                    return result
                }.value

                items.append(contentsOf: prepared)
                isPreparingFiles = false
                persist()
                processNextIfPossible()
            } catch {
                isPreparingFiles = false
                lastError = error.localizedDescription
            }
        }
    }

    func enqueuePreparedFile(_ url: URL, folderID: UUID?, tagIDs: [UUID] = []) {
        enqueue(urls: [url], folderID: folderID, tagIDs: tagIDs)
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        processNextIfPossible()
    }

    func retry(_ item: QueuedUpload) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard FileManager.default.fileExists(atPath: items[index].localPath) else {
            items[index].state = .failed
            items[index].lastError = "The queued local copy is missing. Add the file again."
            persist()
            return
        }
        items[index].state = .queued
        items[index].lastError = nil
        items[index].startedAt = nil
        items[index].completedAt = nil
        persist()
        processNextIfPossible()
    }

    func remove(_ item: QueuedUpload) {
        guard item.id != activeID else { return }
        cleanupLocalCopy(for: item)
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clearCompleted() {
        let completed = items.filter { $0.state == .completed }
        completed.forEach(cleanupLocalCopy)
        items.removeAll { $0.state == .completed }
        persist()
    }

    func clearFailed() {
        let failed = items.filter { $0.state == .failed }
        failed.forEach(cleanupLocalCopy)
        items.removeAll { $0.state == .failed }
        persist()
    }

    private func processNextIfPossible() {
        guard !isPaused, activeID == nil, cloud.upload == nil else { return }
        guard network.isConnected else { return }
        if preferences.wifiOnlyUploads && network.interfaceName != "Wi‑Fi" { return }
        guard cloud.telegram.savedMessagesChatID != nil else { return }
        guard let index = items.firstIndex(where: { $0.state == .queued }) else { return }

        let url = URL(fileURLWithPath: items[index].localPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            items[index].state = .failed
            items[index].lastError = "The queued local copy no longer exists."
            persist()
            processNextIfPossible()
            return
        }

        items[index].state = .uploading
        items[index].startedAt = Date()
        items[index].lastError = nil
        activeID = items[index].id
        activeFileCount = cloud.index.files.count
        let item = items[index]
        persist()
        cloud.lastError = nil
        cloud.uploadFile(url, folderID: item.folderID, tagIDs: item.tagIDs)

        if cloud.upload == nil {
            DispatchQueue.main.async { [weak self] in self?.finishActiveUpload() }
        }
    }

    private func finishActiveUpload() {
        guard let id = activeID, let index = items.firstIndex(where: { $0.id == id }) else {
            activeID = nil
            processNextIfPossible()
            return
        }

        let started = items[index].startedAt ?? .distantPast
        let expectedName = items[index].displayName
        let successful = cloud.index.files.count > activeFileCount || cloud.index.files.contains {
            $0.name == expectedName && $0.modifiedAt >= started.addingTimeInterval(-2)
        }

        if successful {
            items[index].state = .completed
            items[index].completedAt = Date()
            items[index].lastError = nil
            cleanupLocalCopy(for: items[index])
        } else {
            items[index].state = .failed
            items[index].lastError = cloud.lastError ?? "Upload did not complete. You can retry it from Transfers."
        }
        activeID = nil
        persist()
        processNextIfPossible()
    }

    private var queueRootURL: URL {
        let documents = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Transfer Queue", isDirectory: true)
    }

    private var persistenceURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let folder = support.appendingPathComponent("TGSpeicher", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("upload-queue-v2.json")
    }

    private func load() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([QueuedUpload].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        guard let url = persistenceURL,
              let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func cleanupLocalCopy(for item: QueuedUpload) {
        let url = URL(fileURLWithPath: item.localPath)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
    }
}
