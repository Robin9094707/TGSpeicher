import Foundation
import Combine
import AVFoundation

@MainActor
final class UploadQueueManager: ObservableObject {
    @Published private(set) var items: [QueuedUpload] = []
    @Published var isPaused = UserDefaults.standard.bool(forKey: "queue.paused.v3") {
        didSet { UserDefaults.standard.set(isPaused, forKey: "queue.paused.v3") }
    }
    @Published private(set) var isPreparingFiles = false
    @Published var lastError: String?

    private let cloud: CloudStore
    private let preferences: AppPreferences
    private let network: TGNetworkMonitor
    private var cancellables = Set<AnyCancellable>()
    private var activeID: UUID?
    private var pendingCleanupItems: [UUID: DispatchWorkItem] = [:]
    private var preparingPhotoResourceKeys = Set<String>()
    private var hashingItemIDs = Set<UUID>()

    init(cloud: CloudStore, preferences: AppPreferences, network: TGNetworkMonitor) {
        self.cloud = cloud
        self.preferences = preferences
        self.network = network
        load()
        recoverStagedUploads()
        if let owner = cloud.index.recovery?.accountID, owner != 0 {
            for i in items.indices where items[i].accountID == nil { items[i].accountID = owner }
        }
        recoverInterruptedUploads()
        deduplicatePhotoBackupItems()
        if persist() { removeRecoveredStagingReceipts() }

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

        cloud.$isDeleting.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] deleting in
            if !deleting { self?.processNextIfPossible() }
        }.store(in: &cancellables)

        cloud.$isCatalogSyncing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] syncing in
                if !syncing { self?.processNextIfPossible() }
            }
            .store(in: &cancellables)

        cloud.$recoveryReady
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] ready in if ready { self?.processNextIfPossible() } }
            .store(in: &cancellables)

        cloud.$isRefreshing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] refreshing in
                if !refreshing { self?.processNextIfPossible() }
            }
            .store(in: &cancellables)

        cloud.telegram.$savedMessagesChatID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Let CloudStore begin its catalog restore first. Otherwise a recovered
                // queue entry could be resent before its existing cloud ID is visible.
                DispatchQueue.main.async { self?.processNextIfPossible() }
            }
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

    func enqueue(urls: [URL], folderID: UUID?, tagIDs: [UUID] = [], musicDestinationChatID: Int64? = nil) {
        guard !urls.isEmpty else { return }
        ContinuedTransfers.shared.start()
        isPreparingFiles = true
        lastError = nil

        let root = queueRootURL
        let ownerAccountID = cloud.telegram.savedMessagesChatID
        Task {
            do {
                let copied = try await Task.detached(priority: .userInitiated) {
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
                        if musicDestinationChatID != nil, !result.isEmpty {
                            result[result.count - 1].musicDestinationChatID = musicDestinationChatID
                        }
                        if var receipt = result.last {
                            receipt.accountID = ownerAccountID
                            try JSONEncoder().encode(receipt).write(to: itemFolder.appendingPathComponent("staged-upload.json"), options: [.atomic])
                        }
                    }
                    return result
                }.value

                var prepared = copied
                if musicDestinationChatID != nil {
                    for i in prepared.indices {
                        let url = URL(fileURLWithPath: prepared[i].localPath)
                        let metadata = await MusicMetadata.read(AVURLAsset(url: url))
                        prepared[i].musicDescriptor = NativeMediaUploadDescriptor(kind: "audio", width: 0, height: 0,
                            duration: Int(min(Double(Int32.max), max(0, metadata.info.duration ?? 0))),
                            title: metadata.info.title ?? (prepared[i].displayName as NSString).deletingPathExtension,
                            performer: metadata.info.artist)
                        prepared[i].accountID = ownerAccountID
                        try JSONEncoder().encode(prepared[i]).write(to: url.deletingLastPathComponent().appendingPathComponent("staged-upload.json"), options: [.atomic])
                    }
                }
                let owned = prepared.map { item -> QueuedUpload in
                    var item = item
                    item.accountID = ownerAccountID
                    return item
                }
                items.append(contentsOf: owned)
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
        let scope = photoBackup.map {
            CatalogCodec.resourceIdentity(sourceKey: $0.resourceKey, accountID: cloud.telegram.savedMessagesChatID,
                destination: $0.destinationChatID ?? cloud.telegram.savedMessagesChatID)
        }
        if let resourceKey = photoBackup?.resourceKey, let scope {
            let alreadyQueued = items.contains {
                $0.photoBackup?.resourceKey == resourceKey &&
                ($0.photoBackup?.destinationChatID ?? cloud.telegram.savedMessagesChatID) == (photoBackup?.destinationChatID ?? cloud.telegram.savedMessagesChatID) &&
                ($0.accountID == nil || $0.accountID == cloud.telegram.savedMessagesChatID)
            }
            guard !alreadyQueued,
                  preparingPhotoResourceKeys.insert(scope).inserted else {
                discardPreparedPhotoExport(url)
                return
            }
        }
        isPreparingFiles = true
        lastError = nil

        let root = queueRootURL
        let ownerAccountID = cloud.telegram.savedMessagesChatID
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let id = UUID()
                    let itemFolder = root.appendingPathComponent(id.uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                    let stagedName: String
                    if photoBackup?.nativeMedia?.kind == "photo" {
                        let original = photoBackup?.fileName ?? "Foto"
                        stagedName = (original as NSString).deletingPathExtension + ".jpg"
                    } else {
                        stagedName = url.lastPathComponent.isEmpty ? "Upload.bin" : url.lastPathComponent
                    }
                    let destination = itemFolder.appendingPathComponent(stagedName)
                    var stagedItem = QueuedUpload(
                        id: id,
                        localPath: destination.path,
                        displayName: photoBackup?.fileName ?? stagedName,
                        folderID: folderID,
                        tagIDs: tagIDs,
                        byteSize: url.fileByteSize,
                        photoBackup: photoBackup
                    )
                    stagedItem.accountID = ownerAccountID
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
                    if let chat = photoBackup?.destinationChatID {
                        let hash = try FileChunker.sha256(of: destination)
                        preparedItem.cloudFileID = CatalogCodec.stableMediaID(hash: hash, chatID: chat)
                    }
                    try JSONEncoder().encode(preparedItem).write(to: receiptURL, options: [.atomic])
                    return preparedItem
                }.value

                items.append(prepared)
                if let scope { preparingPhotoResourceKeys.remove(scope) }
                isPreparingFiles = false
                if persist() {
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: prepared.localPath)
                            .deletingLastPathComponent()
                            .appendingPathComponent("staged-upload.json")
                    )
                }
                processNextIfPossible()
            } catch {
                if let scope { preparingPhotoResourceKeys.remove(scope) }
                isPreparingFiles = false
                lastError = error.localizedDescription
            }
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        if queuedCount > 0 { ContinuedTransfers.shared.start() }
        isPaused = false
        processNextIfPossible()
    }

    func retry(_ item: QueuedUpload, automatic: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        cancelPendingCleanup(for: item.id)
        guard FileManager.default.fileExists(atPath: items[index].localPath) else {
            items[index].state = .failed
            items[index].lastError = "Die lokale Kopie fehlt. Bitte füge die Datei erneut hinzu."
            if automatic {
                items[index].automaticRetryCount = (items[index].automaticRetryCount ?? 0) + 1
            }
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
        failed.forEach { cleanupLocalCopy(for: $0) }
        items.removeAll { $0.state == .failed }
        persist()
    }

    private func processNextIfPossible() {
        guard !isPaused, activeID == nil, cloud.upload == nil,
              cloud.recoveryReady, !cloud.isCatalogSyncing, !cloud.isRefreshing, !cloud.isDeleting else { return }
        guard network.isConnected else { return }
        if cloud.checkpointBeforeNextUpload() { return }
        if preferences.wifiOnlyUploads && network.interfaceName != "Wi‑Fi" { return }
        guard cloud.telegram.savedMessagesChatID != nil else { return }
        guard let account = cloud.telegram.savedMessagesChatID else { return }
        guard let index = items.firstIndex(where: { $0.state == .queued && ($0.accountID == nil || $0.accountID == account) }) else { return }
        items[index].accountID = account

        if items[index].photoBackup != nil, items[index].cloudFileID == nil,
           matchingCloudFile(for: items[index]) == nil,
           FileManager.default.fileExists(atPath: items[index].localPath) {
            let item = items[index]
            guard hashingItemIDs.insert(item.id).inserted else { return }
            let chat = item.photoBackup?.destinationChatID ?? account
            Task {
                do {
                    let hash = try await Task.detached(priority: .utility) {
                        try FileChunker.sha256(of: URL(fileURLWithPath: item.localPath))
                    }.value
                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                        items[i].cloudFileID = CatalogCodec.stableMediaID(hash: hash, chatID: chat)
                    }
                    persist()
                } catch {
                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                        items[i].state = .failed
                        items[i].lastError = "Die lokale Datei konnte nicht geprüft werden: \(error.localizedDescription)"
                    }
                    persist()
                }
                hashingItemIDs.remove(item.id)
                processNextIfPossible()
            }
            return
        }

        if let photo = items[index].photoBackup, cloud.isPhotoExcluded(photo.resourceKey, chatID: photo.destinationChatID) {
            items[index].state = .failed
            items[index].lastError = "Bewusst aus Telegram gelöscht; die automatische Sicherung überspringt diese Datei."
            persist()
            DispatchQueue.main.async { [weak self] in self?.processNextIfPossible() }
            return
        }
        cloud.telegram.refreshUploadLimits()
        let stableCloudFileID = items[index].cloudFileID ?? items[index].id
        items[index].cloudFileID = stableCloudFileID
        if let existing = matchingCloudFile(for: items[index]) {
            items[index].cloudFileID = existing.id
            items[index].state = .completed
            items[index].completedAt = Date()
            items[index].lastError = nil
            persist()
            DispatchQueue.main.async { [weak self] in self?.processNextIfPossible() }
            return
        }

        let url = URL(fileURLWithPath: items[index].localPath)
        cancelPendingCleanup(for: items[index].id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            items[index].state = .failed
            items[index].lastError = "Die lokale Datei in der Warteschlange ist nicht mehr vorhanden."
            persist()
            processNextIfPossible()
            return
        }

        items[index].state = .uploading
        items[index].startedAt = Date()
        items[index].lastError = nil
        activeID = items[index].id
        guard persist() else {
            items[index].state = .queued
            activeID = nil
            return
        }
        cloud.lastError = nil
        let expectedCloudFileID = cloud.uploadFile(
            url,
            folderID: items[index].folderID,
            tagIDs: items[index].tagIDs,
            stableFileID: stableCloudFileID,
            sourceKey: items[index].photoBackup?.resourceKey,
            destinationChatID: items[index].musicDestinationChatID ?? items[index].photoBackup?.destinationChatID,
            nativeMedia: items[index].musicDescriptor ?? items[index].musicDestinationChatID.map { _ in NativeMediaUploadDescriptor(kind: "audio", width: 0, height: 0, duration: 0) } ?? items[index].photoBackup?.nativeMedia,
            photoBackup: items[index].photoBackup
        )
        if let expectedCloudFileID {
            items[index].cloudFileID = expectedCloudFileID
            persist()
        }

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

        if let uploadedFile = matchingCloudFile(for: items[index]) {
            items[index].state = .completed
            items[index].completedAt = Date()
            items[index].lastError = nil
            items[index].cloudFileID = uploadedFile.id
            cleanupLocalCopy(for: items[index], after: 30)
        } else {
            items[index].state = .failed
            items[index].lastError = cloud.lastUploadFailure ?? cloud.lastError ?? "Upload nicht abgeschlossen. Du kannst ihn unter „Übertragungen“ erneut prüfen."
        }
        activeID = nil
        persist()
        processNextIfPossible()
    }

    private func recoverInterruptedUploads() {
        for index in items.indices where items[index].state == .uploading {
            if let uploadedFile = matchingCloudFile(for: items[index]) {
                items[index].state = .completed
                items[index].completedAt = Date()
                items[index].lastError = nil
                items[index].cloudFileID = uploadedFile.id
                cleanupLocalCopy(for: items[index], after: 8)
            } else {
                items[index].state = .queued
                items[index].startedAt = nil
            }
        }
    }

    private func deduplicatePhotoBackupItems() {
        let groups = Dictionary(grouping: items.filter { $0.photoBackup != nil }) {
            CatalogCodec.resourceIdentity(sourceKey: $0.photoBackup!.resourceKey, accountID: $0.accountID,
                destination: $0.photoBackup?.destinationChatID)
        }
        var duplicateIDs = Set<UUID>()
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted {
                let lhs = queueRecoveryPriority($0.state)
                let rhs = queueRecoveryPriority($1.state)
                if lhs != rhs { return lhs < rhs }
                return $0.createdAt < $1.createdAt
            }
            for duplicate in ordered.dropFirst() {
                duplicateIDs.insert(duplicate.id)
                cleanupLocalCopy(for: duplicate)
            }
        }
        if !duplicateIDs.isEmpty {
            items.removeAll { duplicateIDs.contains($0.id) }
        }
    }

    private func queueRecoveryPriority(_ state: QueuedUpload.State) -> Int {
        switch state {
        case .completed: return 0
        case .uploading: return 1
        case .queued: return 2
        case .failed: return 3
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
                  var staged = try? JSONDecoder().decode(QueuedUpload.self, from: data),
                  folder.lastPathComponent == staged.id.uuidString else { continue }
            if knownIDs.contains(staged.id) { continue }
            if !FileManager.default.fileExists(atPath: staged.localPath) {
                // iOS may move the app container during updates. Resolve against
                // this receipt's current directory; never delete an unknown copy.
                staged.localPath = folder.appendingPathComponent(URL(fileURLWithPath: staged.localPath).lastPathComponent).path
            }
            if FileManager.default.fileExists(atPath: staged.localPath) { items.append(staged) }
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

    private func matchingCloudFile(for item: QueuedUpload) -> CloudFileEntry? {
        let destination = item.musicDestinationChatID ?? item.photoBackup?.destinationChatID ?? cloud.telegram.savedMessagesChatID
        return cloud.index.files.first { file in
            file.isComplete && (file.telegramChatID ?? cloud.telegram.savedMessagesChatID) == destination &&
            (file.id == (item.cloudFileID ?? item.id) ||
             (item.photoBackup?.resourceKey != nil && file.sourceKey == item.photoBackup?.resourceKey))
        }
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
        items = decoded.map { item in
            var recovered = item
            if !FileManager.default.fileExists(atPath: recovered.localPath) {
                let name = URL(fileURLWithPath: recovered.localPath).lastPathComponent
                recovered.localPath = queueRootURL.appendingPathComponent(recovered.id.uuidString).appendingPathComponent(name).path
            }
            return recovered
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            guard let url = persistenceURL else { throw CocoaError(.fileWriteUnknown) }
            try JSONEncoder().encode(items).write(to: url, options: [.atomic])
            return true
        } catch {
            isPaused = true
            lastError = "Die Warteschlange konnte nicht gespeichert werden. Uploads wurden angehalten: \(error.localizedDescription)"
            return false
        }
    }

    private func cleanupLocalCopy(for item: QueuedUpload, after delay: TimeInterval = 0) {
        let url = URL(fileURLWithPath: item.localPath)
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let root = queueRootURL.standardizedFileURL
        guard parent.path.hasPrefix(root.path + "/") else { return }
        cancelPendingCleanup(for: item.id)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCleanupItems[item.id] = nil
            guard self.activeID != item.id else { return }
            if let live = self.items.first(where: { $0.id == item.id }), live.state != .completed {
                return
            }
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: parent)
            }
        }
        pendingCleanupItems[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func cancelPendingCleanup(for itemID: UUID) {
        pendingCleanupItems.removeValue(forKey: itemID)?.cancel()
    }

    private func discardPreparedPhotoExport(_ url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicherPhotoBackup", isDirectory: true)
            .standardizedFileURL
        guard parent.path.hasPrefix(root.path + "/") else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}


