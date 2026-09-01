import Foundation
import Combine

struct PhotoBackupQueueMetadata: Codable, Hashable {
    let resourceKey: String
    let assetLocalIdentifier: String
    let resourceTypeRawValue: Int
    let fileName: String
    let mediaKind: String
    let creationDate: Date?
}

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
    var cloudFileID: UUID?
    var photoBackup: PhotoBackupQueueMetadata?
    var automaticRetryCount: Int?

    init(
        id: UUID = UUID(),
        localPath: String,
        displayName: String,
        folderID: UUID?,
        tagIDs: [UUID],
        byteSize: Int64,
        createdAt: Date = Date(),
        state: State = .queued,
        cloudFileID: UUID? = nil,
        photoBackup: PhotoBackupQueueMetadata? = nil,
        automaticRetryCount: Int? = nil
    ) {
        self.id = id
        self.localPath = localPath
        self.displayName = displayName
        self.folderID = folderID
        self.tagIDs = tagIDs
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.state = state
        self.cloudFileID = cloudFileID
        self.photoBackup = photoBackup
        self.automaticRetryCount = automaticRetryCount
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

    init(cloud: CloudStore, preferences: AppPreferences, network: TGNetworkMonitor) {
        self.cloud = cloud
        self.preferences = preferences
        self.network = network
        load()
        recoverStagedUploads()
        recoverInterruptedUploads()
        persist()
        removeRecoveredStagingReceipts()

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

        cloud.$isCatalogSyncing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] syncing in
                if !syncing { self?.processNextIfPossible() }
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

    func enqueuePreparedFile(
        _ url: URL,
        folderID: UUID?,
        tagIDs: [UUID] = [],
        photoBackup: PhotoBackupQueueMetadata? = nil
    ) {
        isPreparingFiles = true
        lastError = nil

        let root = queueRootURL
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let id = UUID()
                    let itemFolder = root.appendingPathComponent(id.uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                    let preferredName = url.lastPathComponent.isEmpty ? "Upload.bin" : url.lastPathComponent
                    let destination = itemFolder.appendingPathComponent(preferredName)
                    let stagedItem = QueuedUpload(
                        id: id,
                        localPath: destination.path,
                        displayName: preferredName,
                        folderID: folderID,
                        tagIDs: tagIDs,
                        byteSize: url.fileByteSize,
                        photoBackup: photoBackup
                    )
                    let receiptURL = itemFolder.appendingPathComponent("staged-upload.json")
                    try JSONEncoder().encode(stagedItem).write(to: receiptURL, options: [.atomic])

                    do {
                        try FileManager.default.moveItem(at: url, to: destination)
                    } catch {
                        try FileManager.default.copyItem(at: url, to: destination)
                        try? FileManager.default.removeItem(at: url)
                    }

                    var preparedItem = stagedItem
                    preparedItem.byteSize = destination.fileByteSize
                    return preparedItem
                }.value

                items.append(prepared)
                isPreparingFiles = false
                persist()
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: prepared.localPath)
                        .deletingLastPathComponent()
                        .appendingPathComponent("staged-upload.json")
                )
                processNextIfPossible()
            } catch {
                isPreparingFiles = false
                lastError = error.localizedDescription
            }
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        processNextIfPossible()
    }

    func retry(_ item: QueuedUpload, automatic: Bool = false) {
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
        if automatic {
            items[index].automaticRetryCount = (items[index].automaticRetryCount ?? 0) + 1
        } else {
            items[index].automaticRetryCount = 0
        }
        persist()
        processNextIfPossible()
    }

    func remove(_ item: QueuedUpload) {
        guard item.id != activeID else { return }
        cleanupLocalCopy(for: item, after: item.state == .completed ? 8 : 0)
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clearCompleted() {
        let completed = items.filter { $0.state == .completed }
        completed.forEach { cleanupLocalCopy(for: $0, after: 8) }
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
        guard !isPaused, activeID == nil, cloud.upload == nil, !cloud.isCatalogSyncing else { return }
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
        if let uploadedFile = matchingCloudFile(for: items[index], since: started) {
            items[index].state = .completed
            items[index].completedAt = Date()
            items[index].lastError = nil
            items[index].cloudFileID = uploadedFile.id
            cleanupLocalCopy(for: items[index], after: 8)
        } else {
            items[index].state = .failed
            items[index].lastError = cloud.lastError ?? "Upload did not complete. You can retry it from Transfers."
        }
        activeID = nil
        persist()
        processNextIfPossible()
    }

    private func recoverInterruptedUploads() {
        for index in items.indices where items[index].state == .uploading {
            if let started = items[index].startedAt,
               let uploadedFile = matchingCloudFile(for: items[index], since: started) {
                items[index].state = .completed
                items[index].completedAt = Date()
                items[index].lastError = nil
                items[index].cloudFileID = uploadedFile.id
                cleanupLocalCopy(for: items[index])
            } else {
                items[index].state = .queued
                items[index].startedAt = nil
            }
        }
    }

    private func recoverStagedUploads() {
        let root = queueRootURL
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let knownIDs = Set(items.map(\.id))
        for folder in folders {
            let receipt = folder.appendingPathComponent("staged-upload.json")
            guard let data = try? Data(contentsOf: receipt),
                  let staged = try? JSONDecoder().decode(QueuedUpload.self, from: data) else { continue }
            if knownIDs.contains(staged.id) { continue }
            if FileManager.default.fileExists(atPath: staged.localPath) {
                items.append(staged)
            } else {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private func removeRecoveredStagingReceipts() {
        for item in items {
            let receipt = URL(fileURLWithPath: item.localPath)
                .deletingLastPathComponent()
                .appendingPathComponent("staged-upload.json")
            try? FileManager.default.removeItem(at: receipt)
        }
    }

    private func matchingCloudFile(for item: QueuedUpload, since started: Date) -> CloudFileEntry? {
        cloud.index.files
            .filter {
                $0.folderID == item.folderID &&
                $0.name == item.displayName &&
                $0.modifiedAt >= started.addingTimeInterval(-3)
            }
            .max(by: { $0.modifiedAt < $1.modifiedAt })
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

    private func cleanupLocalCopy(for item: QueuedUpload, after delay: TimeInterval = 0) {
        let url = URL(fileURLWithPath: item.localPath)
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let root = queueRootURL.standardizedFileURL
        guard parent.path.hasPrefix(root.path + "/") else { return }
        let remove: () -> Void = { try? FileManager.default.removeItem(at: parent) }
        if delay > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: remove)
        } else {
            remove()
        }
    }
}
