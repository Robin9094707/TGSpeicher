import Foundation
import Combine
import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct PhotoBackupRecord: Identifiable, Codable, Hashable {
    var id: String { resourceKey }
    let resourceKey: String
    let assetLocalIdentifier: String
    let resourceTypeRawValue: Int
    let fileName: String
    let mediaKind: String
    let cloudFileID: UUID
    let creationDate: Date?
    let uploadedAt: Date
}

struct PhotoBackupFailureRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let occurredAt: Date
    let stage: String
    let fileName: String?
    let resourceKey: String?
    let message: String
    let attempt: Int

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        stage: String,
        fileName: String?,
        resourceKey: String?,
        message: String,
        attempt: Int
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.stage = stage
        self.fileName = fileName
        self.resourceKey = resourceKey
        self.message = message
        self.attempt = attempt
    }
}

private struct PhotoBackupSnapshot: Codable {
    var schema = 2
    var revision: Int64
    var updatedAt: Date
    var records: [PhotoBackupRecord]
    var files: [CloudFileEntry]? = nil
}

private struct PhotoBackupJournalEvent: Codable {
    let record: PhotoBackupRecord
}

private struct PhotoBackupCandidate {
    let assetLocalIdentifier: String
    let resourceTypeRawValue: Int
    let fileName: String
    let mediaKind: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Int

    var resourceKey: String {
        "\(assetLocalIdentifier)|\(resourceTypeRawValue)|\(fileName)"
    }

    func queueMetadata(destinationChatID: Int64) -> PhotoBackupQueueMetadata {
        PhotoBackupQueueMetadata(
            resourceKey: resourceKey,
            assetLocalIdentifier: assetLocalIdentifier,
            resourceTypeRawValue: resourceTypeRawValue,
            fileName: fileName,
            mediaKind: mediaKind,
            creationDate: creationDate,
            destinationChatID: destinationChatID,
            nativeMedia: NativeMediaUploadDescriptor(
                kind: mediaKind,
                width: pixelWidth,
                height: pixelHeight,
                duration: duration
            )
        )
    }
}

@MainActor
final class PhotoBackupManager: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var totalAssets = 0
    @Published private(set) var totalResources = 0
    @Published private(set) var backedUpAssets = 0
    @Published private(set) var backedUpResources = 0
    @Published private(set) var pendingResources = 0
    @Published private(set) var deletableAssetCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var isNightMode = false
    @Published private(set) var isExportingFromPhotos = false
    @Published private(set) var isVerifying = false
    @Published private(set) var isScanningLibrary = false
    @Published private(set) var currentFileName: String?
    @Published private(set) var iCloudProgress: Double = 0
    @Published private(set) var statusText = "Photo backup is ready"
    @Published private(set) var latestCompletedRecord: PhotoBackupRecord?
    @Published private(set) var recentFailures: [PhotoBackupFailureRecord] = []
    @Published var lastError: String?
    @Published private(set) var backupDestinations: [TelegramBackupDestination] = []
    @Published private(set) var selectedDestinationID: Int64?
    @Published private(set) var selectedDestinationTitle = "Saved Messages"
    @Published var autoResumeOnLaunch: Bool {
        didSet { defaults.set(autoResumeOnLaunch, forKey: Self.autoResumeKey) }
    }

    private let cloud: CloudStore
    private let queue: UploadQueueManager
    private let telegram: TelegramClient
    private let defaults = UserDefaults.standard
    private let libraryScanQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.photos.scan", qos: .utility)
    private let indexIOQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.photos.index", qos: .utility)
    private var cancellables = Set<AnyCancellable>()
    private var candidates: [PhotoBackupCandidate] = []
    private var pendingCandidates: [PhotoBackupCandidate] = []
    private var pendingCandidateCursor = 0
    private var recordsByKey: [String: PhotoBackupRecord] = [:]
    private var requiredResourceCountByAssetID: [String: Int] = [:]
    private var backedResourceCountByAssetID: [String: Int] = [:]
    private var fullyBackedUpAssetIDsCache = Set<String>()
    private var currentCandidate: PhotoBackupCandidate?
    private var currentQueueItemID: UUID?
    private var currentExportURL: URL?
    private var syncWorkItem: DispatchWorkItem?
    private var recordsSinceLocalSnapshot = 0
    private var recordsSinceRemoteSnapshot = 0
    private var lastRemoteSnapshotAt = Date.distantPast
    private var scheduledRetryIDs = Set<UUID>()
    private var photoExportRetryCount: [String: Int] = [:]
    private var deferredCandidateKeys = Set<String>()
    private var deferredRetryCycles: [String: Int] = [:]
    private var infrastructureRetryKeys = Set<String>()
    private var remoteIndexReady = false
    private var previousBrightness: CGFloat?
    private var previousIdleTimerDisabled: Bool?
    private var snapshotMessageID: Int64?
    private var libraryScanGeneration = UUID()
    private var lastLibraryScanAt: Date?
    private var backupRunGeneration = UUID()

    private static let autoResumeKey = "photos.autoResumeOnLaunch.v1"
    private static let backupEnabledKey = "photos.backupEnabled"
    private static let pausedKey = "photos.backupPaused.v2"
    private static let nightModeKey = "photos.nightModeRequested.v2"
    private static let marker = "#TGSpeicherPhotoBackupIndexV1"
    private static let destinationKey = "photos.backupDestinationChatID.v1"

    init(cloud: CloudStore, queue: UploadQueueManager, telegram: TelegramClient) {
        self.cloud = cloud
        self.queue = queue
        self.telegram = telegram
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.autoResumeOnLaunch = defaults.object(forKey: Self.autoResumeKey) as? Bool ?? true
        self.snapshotMessageID = defaults.object(forKey: "photos.snapshotMessageID") as? Int64
        self.selectedDestinationID = defaults.string(forKey: Self.destinationKey).flatMap(Int64.init)
        loadLocalIndex()
        loadFailureHistory()
        self.isPaused = defaults.bool(forKey: Self.backupEnabledKey)
            && defaults.bool(forKey: Self.pausedKey)
        self.isNightMode = defaults.bool(forKey: Self.backupEnabledKey)
            && !defaults.bool(forKey: Self.pausedKey)
            && defaults.bool(forKey: Self.nightModeKey)
        cleanupStalePhotoExports()

        queue.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.handleQueue(items) }
            .store(in: &cancellables)

        queue.$lastError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.captureOperationalError(message, stage: "Upload queue") }
            .store(in: &cancellables)

        cloud.$lastError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.captureOperationalError(message, stage: "Telegram upload") }
            .store(in: &cancellables)

        telegram.$lastError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.captureOperationalError(message, stage: "Telegram") }
            .store(in: &cancellables)

        telegram.$savedMessagesChatID
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] savedID in
                guard let self else { return }
                if self.selectedDestinationID == nil { self.selectBackupDestinationID(savedID, title: "Saved Messages", restore: false) }
                self.rebuildDestinationList()
                if let selected = self.selectedDestinationID, selected != savedID {
                    self.telegram.send(["@type": "getChat", "chat_id": selected]) { [weak self] chat in
                        guard let self, chat["@type"] as? String != "error" else { return }
                        self.selectedDestinationTitle = chat["title"] as? String ?? self.selectedDestinationTitle
                    }
                }
                self.restoreRemoteIndex()
            }
            .store(in: &cancellables)

        telegram.$writableBackupChannels
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildDestinationList() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard self.hasLibraryAccess else { return }
                guard self.remoteIndexReady else {
                    self.statusText = "Restoring the Telegram photo index…"
                    return
                }
                // Do not repeatedly rescan a large iCloud library every time a sheet closes
                // or the app becomes active. A fresh scan can still be requested manually.
                if self.lastLibraryScanAt == nil || Date().timeIntervalSince(self.lastLibraryScanAt!) > 600 {
                    self.refreshLibrary()
                } else {
                    self.maybeAutoStart()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistLocalIndex()
                self?.syncIndexSoon(delay: 0.2)
            }
            .store(in: &cancellables)

        // The remote photo index callback starts the first background scan. Waiting
        // for it prevents a huge iCloud library from being enumerated twice at launch.
    }

    var hasLibraryAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var records: [PhotoBackupRecord] {
        recordsByKey.values.sorted { $0.uploadedAt > $1.uploadedAt }
    }

    func refreshBackupDestinations() { telegram.refreshWritableBackupChannels() }

    func selectBackupDestination(_ destination: TelegramBackupDestination) {
        guard cloud.upload == nil, currentQueueItemID == nil else {
            lastError = "Pause the current upload before changing the Telegram backup channel."
            return
        }
        selectBackupDestinationID(destination.id, title: destination.title, restore: true)
    }

    private func selectBackupDestinationID(_ id: Int64, title: String, restore: Bool) {
        selectedDestinationID = id
        selectedDestinationTitle = title
        defaults.set(String(id), forKey: Self.destinationKey)
        snapshotMessageID = nil
        defaults.removeObject(forKey: "photos.snapshotMessageID")
        if restore {
            remoteIndexReady = false
            statusText = "Restoring backup index from \(title)…"
            restoreRemoteIndex()
        }
    }

    private func rebuildDestinationList() {
        var result = telegram.writableBackupChannels
        if let saved = telegram.savedMessagesChatID {
            result.insert(TelegramBackupDestination(id: saved, title: "Saved Messages", isSavedMessages: true), at: 0)
        }
        backupDestinations = result
        if let selectedDestinationID,
           let current = result.first(where: { $0.id == selectedDestinationID }) {
            selectedDestinationTitle = current.title
        }
    }

    func galleryRecordSnapshot() -> [PhotoBackupRecord] {
        Array(recordsByKey.values)
    }

    var cloudGalleryFiles: [CloudFileEntry] {
        let ids = Set(recordsByKey.values.map(\.cloudFileID))
        return cloud.index.files.filter { ids.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }

    func requestFullAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationStatus = status
                if self.hasLibraryAccess {
                    self.statusText = status == .limited ? "Limited Photos access granted" : "Full Photos access granted"
                    self.refreshLibrary()
                } else {
                    self.lastError = "TGSpeicher needs Photos access to back up your library."
                }
            }
        }
    }

    func refreshLibrary() {
        guard hasLibraryAccess else { return }
        guard !isScanningLibrary else { return }

        let generation = UUID()
        libraryScanGeneration = generation
        isScanningLibrary = true
        statusText = "Scanning Photos library in background…"
        let knownRecords = recordsByKey
        let cloudFiles = cloud.index.files

        libraryScanQueue.async { [weak self] in
            guard let self else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let fetch = PHAsset.fetchAssets(with: options)
            let assetCount = fetch.count
            var newCandidates: [PhotoBackupCandidate] = []
            var newPendingCandidates: [PhotoBackupCandidate] = []
            var requiredCounts: [String: Int] = [:]
            var backedCounts: [String: Int] = [:]
            var fullyBackedAssetIDs = Set<String>()
            var recoveredRecords: [String: PhotoBackupRecord] = [:]
            let cloudIDs = Set(cloudFiles.map(\.id))
            var cloudFileBySourceKey: [String: CloudFileEntry] = [:]
            for file in cloudFiles {
                guard let sourceKey = file.sourceKey else { continue }
                if let existing = cloudFileBySourceKey[sourceKey], existing.createdAt <= file.createdAt { continue }
                cloudFileBySourceKey[sourceKey] = file
            }
            newCandidates.reserveCapacity(max(assetCount, 1))
            newPendingCandidates.reserveCapacity(max(assetCount / 8, 1))

            fetch.enumerateObjects { asset, _, _ in
                var requiredForAsset = 0
                var backedForAsset = 0
                for resource in Self.preferredResourcesBackground(for: asset) {
                    let name = resource.originalFilename.isEmpty
                        ? Self.fallbackNameBackground(asset: asset, resource: resource)
                        : resource.originalFilename
                    let mediaKind = Self.mediaKindBackground(asset: asset, resource: resource)
                    let candidate = PhotoBackupCandidate(
                        assetLocalIdentifier: asset.localIdentifier,
                        resourceTypeRawValue: resource.type.rawValue,
                        fileName: name,
                        mediaKind: mediaKind,
                        creationDate: asset.creationDate,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        duration: asset.duration.isFinite ? Int(max(0, asset.duration.rounded())) : 0
                    )
                    newCandidates.append(candidate)
                    requiredForAsset += 1
                    if let record = knownRecords[candidate.resourceKey], cloudIDs.contains(record.cloudFileID) {
                        backedForAsset += 1
                    } else if let recoveredFile = cloudFileBySourceKey[candidate.resourceKey] {
                        recoveredRecords[candidate.resourceKey] = PhotoBackupRecord(
                            resourceKey: candidate.resourceKey,
                            assetLocalIdentifier: candidate.assetLocalIdentifier,
                            resourceTypeRawValue: candidate.resourceTypeRawValue,
                            fileName: candidate.fileName,
                            mediaKind: candidate.mediaKind,
                            cloudFileID: recoveredFile.id,
                            creationDate: candidate.creationDate,
                            uploadedAt: recoveredFile.createdAt
                        )
                        backedForAsset += 1
                    } else {
                        newPendingCandidates.append(candidate)
                    }
                }
                if requiredForAsset > 0 {
                    requiredCounts[asset.localIdentifier] = requiredForAsset
                    backedCounts[asset.localIdentifier] = backedForAsset
                    if requiredForAsset == backedForAsset {
                        fullyBackedAssetIDs.insert(asset.localIdentifier)
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.libraryScanGeneration == generation else { return }
                if !recoveredRecords.isEmpty {
                    for (key, record) in recoveredRecords where self.recordsByKey[key] == nil {
                        self.recordsByKey[key] = record
                    }
                    self.persistLocalIndex()
                }
                self.candidates = newCandidates
                self.pendingCandidates = newPendingCandidates
                self.pendingCandidateCursor = 0
                self.requiredResourceCountByAssetID = requiredCounts
                self.backedResourceCountByAssetID = backedCounts
                self.fullyBackedUpAssetIDsCache = fullyBackedAssetIDs
                self.totalAssets = assetCount
                self.totalResources = newCandidates.count
                self.backedUpResources = newCandidates.count - newPendingCandidates.count
                self.pendingResources = newPendingCandidates.count
                self.backedUpAssets = fullyBackedAssetIDs.count
                self.deletableAssetCount = fullyBackedAssetIDs.count
                self.isScanningLibrary = false
                self.lastLibraryScanAt = Date()
                self.reconcileRecordsWithCloudIndex()
                self.statusText = self.pendingResources == 0
                    ? "Photos library is fully backed up"
                    : "Photos scan complete • \(self.pendingResources) resource(s) pending"

                if self.isRunning && !self.isPaused {
                    self.processNextIfPossible()
                } else {
                    self.maybeAutoStart()
                }
            }
        }
    }

    func startBackup(nightMode: Bool = false) {
        guard hasLibraryAccess else {
            requestFullAccess()
            return
        }
        backupRunGeneration = UUID()
        persistSession(enabled: true, paused: false, nightMode: nightMode)
        isRunning = true
        isPaused = false
        isNightMode = nightMode
        statusText = nightMode ? "Night backup running" : "Photo backup running"
        if nightMode { applyNightMode() }

        if candidates.isEmpty || lastLibraryScanAt == nil {
            refreshLibrary()
        } else {
            continueCurrentWorkOrStartNext()
        }
    }

    func pauseBackup() {
        backupRunGeneration = UUID()
        isPaused = true
        persistSession(enabled: true, paused: true, nightMode: false)
        statusText = currentQueueItemID == nil ? "Backup paused" : "Pausing after the current upload"
        leaveNightMode()
        syncIndexSoon(delay: 0.1)
    }

    func resumeBackup(nightMode: Bool = false) {
        guard hasLibraryAccess else { requestFullAccess(); return }
        backupRunGeneration = UUID()
        isRunning = true
        isPaused = false
        isNightMode = nightMode
        persistSession(enabled: true, paused: false, nightMode: nightMode)
        if let currentCandidate { photoExportRetryCount[currentCandidate.resourceKey] = 0 }
        if nightMode { applyNightMode() }
        statusText = nightMode ? "Night backup resumed" : "Photo backup resumed"
        if candidates.isEmpty || lastLibraryScanAt == nil {
            refreshLibrary()
        } else {
            continueCurrentWorkOrStartNext()
        }
    }

    func stopBackup() {
        backupRunGeneration = UUID()
        isRunning = false
        isPaused = false
        currentFileName = nil
        persistSession(enabled: false, paused: false, nightMode: false)
        leaveNightMode()
        statusText = "Backup stopped"
        syncIndexSoon(delay: 0.1)
    }

    func activateRestoredNightModeIfNeeded() {
        guard defaults.bool(forKey: Self.backupEnabledKey),
              !defaults.bool(forKey: Self.pausedKey),
              defaults.bool(forKey: Self.nightModeKey) else { return }
        isNightMode = true
        applyNightMode()
        if !isRunning { statusText = "Restoring Night Backup…" }
    }

    func clearFailureHistory() {
        recentFailures = []
        guard let url = failureHistoryURL else { return }
        indexIOQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    func cloudFile(for record: PhotoBackupRecord) -> CloudFileEntry? {
        cloud.index.files.first { $0.id == record.cloudFileID }
    }

    func localAsset(for record: PhotoBackupRecord) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [record.assetLocalIdentifier], options: nil).firstObject
    }

    func deleteFullyBackedUpAssetsFromPhotos() {
        let ids = Array(fullyBackedUpAssetIDsCache)
        guard !ids.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(fetch)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.statusText = "Removed \(fetch.count) fully backed-up item(s) from Photos"
                    self.refreshLibrary()
                } else {
                    self.lastError = error?.localizedDescription ?? "Photos could not delete the selected backed-up items."
                }
            }
        }
    }

    func verifyAndRepairMissingCloudFiles() {
        guard !isVerifying else { return }
        isVerifying = true
        statusText = "Verifying photo backup in Telegram…"
        let values = records
        verifyRecord(values, index: 0, missingKeys: [])
    }

    private func verifyRecord(_ values: [PhotoBackupRecord], index: Int, missingKeys: Set<String>) {
        guard index < values.count else {
            for key in missingKeys {
                if let record = recordsByKey.removeValue(forKey: key),
                   let file = cloud.index.files.first(where: { $0.id == record.cloudFileID }) {
                    cloud.deleteLocalIndexEntry(file)
                }
            }
            persistLocalIndex()
            recalculateCounters()
            isVerifying = false
            statusText = missingKeys.isEmpty ? "Photo backup verified" : "Found \(missingKeys.count) missing resource(s); they will be uploaded again"
            if !missingKeys.isEmpty {
                cloud.syncCatalogNow()
                syncIndexSoon(delay: 0.3)
                if isRunning && !isPaused { processNextIfPossible() }
            }
            return
        }

        let record = values[index]
        guard let file = cloud.index.files.first(where: { $0.id == record.cloudFileID }),
              let chatID = file.telegramChatID ?? telegram.savedMessagesChatID else {
            var missing = missingKeys; missing.insert(record.resourceKey)
            verifyRecord(values, index: index + 1, missingKeys: missing)
            return
        }
        let messageIDs = file.chunks.compactMap(\.telegramMessageID)
        verifyMessageIDs(messageIDs, at: 0, chatID: chatID) { [weak self] valid in
            guard let self else { return }
            var missing = missingKeys
            if !valid { missing.insert(record.resourceKey) }
            self.statusText = "Verifying \(index + 1) / \(values.count)"
            self.verifyRecord(values, index: index + 1, missingKeys: missing)
        }
    }

    private func verifyMessageIDs(_ ids: [Int64], at index: Int, chatID: Int64, completion: @escaping (Bool) -> Void) {
        guard index < ids.count else { completion(!ids.isEmpty); return }
        telegram.send(["@type": "getMessage", "chat_id": chatID, "message_id": ids[index]]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" { completion(false); return }
            self.verifyMessageIDs(ids, at: index + 1, chatID: chatID, completion: completion)
        }
    }

    private func processNextIfPossible() {
        guard isRunning, !isPaused, currentCandidate == nil, currentQueueItemID == nil else { return }
        guard !isExportingFromPhotos else { return }
        guard remoteIndexReady else {
            statusText = "Restoring the Telegram photo index…"
            return
        }
        guard !isScanningLibrary else {
            statusText = "Scanning Photos library in background…"
            return
        }
        if isNightMode { applyNightMode() }

        let folderID = ensureBackupFolder()
        if let failedPhoto = queue.items.first(where: {
            $0.state == .failed && $0.photoBackup != nil && recordsByKey[$0.photoBackup!.resourceKey] == nil
        }) {
            scheduleAutomaticRetry(failedPhoto)
            return
        }
        if queue.items.contains(where: { $0.folderID == folderID && ($0.state == .queued || $0.state == .uploading) }) {
            statusText = "Waiting for the Telegram upload queue…"
            return
        }

        reconcileRecordsWithCloudIndex()
        guard let next = nextPendingCandidate() else {
            if !deferredCandidateKeys.isEmpty {
                statusText = "Waiting to retry \(deferredCandidateKeys.count) deferred item(s)…"
                return
            }
            isRunning = false
            isPaused = false
            currentFileName = nil
            persistSession(enabled: true, paused: false, nightMode: false)
            leaveNightMode()
            statusText = "Photo backup is complete"
            syncIndexSoon(delay: 0.1)
            recalculateCounters()
            return
        }

        currentCandidate = next
        currentFileName = next.fileName
        exportToQueue(next, folderID: folderID)
    }

    private func continueCurrentWorkOrStartNext() {
        if let currentQueueItemID,
           let item = queue.items.first(where: { $0.id == currentQueueItemID && $0.state == .failed }) {
            scheduleAutomaticRetry(item)
            return
        }
        if let currentCandidate, currentQueueItemID == nil, !isExportingFromPhotos {
            exportToQueue(currentCandidate, folderID: ensureBackupFolder())
            return
        }
        processNextIfPossible()
    }

    private func exportToQueue(_ candidate: PhotoBackupCandidate, folderID: UUID) {
        let generation = backupRunGeneration
        if let existing = queue.items.first(where: {
            $0.photoBackup?.resourceKey == candidate.resourceKey
        }) {
            currentCandidate = candidate
            currentFileName = candidate.fileName
            currentQueueItemID = existing.id
            handleQueue(queue.items)
            return
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [candidate.assetLocalIdentifier],
            options: nil
        ).firstObject,
        let resource = resolveResource(for: candidate, asset: asset) else {
            currentCandidate = nil
            currentFileName = nil
            deferCandidateAfterFailure(
                candidate,
                stage: "Photos lookup",
                message: "The Photos item is temporarily unavailable.",
                attempt: 1,
                baseDelay: 300
            )
            return
        }

        isExportingFromPhotos = true
        iCloudProgress = 0
        statusText = "Preparing \(candidate.fileName) from Photos…"

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicherPhotoBackup", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            isExportingFromPhotos = false
            scheduleInfrastructureRetry(
                candidate,
                folderID: folderID,
                stage: "Temporary storage",
                message: error.localizedDescription
            )
            return
        }
        let destination = folder.appendingPathComponent(safeFileName(candidate.fileName))
        currentExportURL = destination

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] progress in
            DispatchQueue.main.async {
                guard let self, self.backupRunGeneration == generation else { return }
                self.iCloudProgress = progress
                self.statusText = progress < 1 ? "Downloading original from iCloud • \(Int(progress * 100))%" : "Preparing Telegram upload…"
            }
        }

        PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.backupRunGeneration == generation, self.isRunning, !self.isPaused else {
                    try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                    if self.currentExportURL == destination { self.currentExportURL = nil }
                    self.isExportingFromPhotos = false
                    self.iCloudProgress = 0
                    self.currentCandidate = nil
                    if self.isRunning && !self.isPaused { self.processNextIfPossible() }
                    return
                }
                self.isExportingFromPhotos = false
                if let error {
                    if let currentExportURL = self.currentExportURL {
                        try? FileManager.default.removeItem(at: currentExportURL.deletingLastPathComponent())
                        self.currentExportURL = nil
                    }
                    let attempt = (self.photoExportRetryCount[candidate.resourceKey] ?? 0) + 1
                    self.photoExportRetryCount[candidate.resourceKey] = attempt
                    if self.isRunning, !self.isPaused, attempt <= 5 {
                        let delay = min(60.0, pow(2.0, Double(attempt)))
                        self.statusText = "iCloud download interrupted • retrying in \(Int(delay))s"
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self.isRunning, !self.isPaused,
                                  self.currentCandidate?.resourceKey == candidate.resourceKey else { return }
                            self.exportToQueue(candidate, folderID: folderID)
                        }
                    } else {
                        self.currentCandidate = nil
                        self.currentFileName = nil
                        self.deferCandidateAfterFailure(
                            candidate,
                            stage: "iCloud download",
                            message: error.localizedDescription,
                            attempt: attempt,
                            baseDelay: 300
                        )
                    }
                    return
                }
                self.photoExportRetryCount[candidate.resourceKey] = nil
                guard let chatID = self.selectedDestinationID ?? self.telegram.savedMessagesChatID else {
                    self.scheduleInfrastructureRetry(
                        candidate, folderID: folderID, stage: "Backup destination",
                        message: "The selected Telegram channel is unavailable."
                    )
                    return
                }
                self.isExportingFromPhotos = true
                self.statusText = candidate.mediaKind == "photo"
                    ? "Optimizing photo for Telegram…"
                    : "Preparing streamable Telegram video…"
                self.libraryScanQueue.async { [weak self] in
                    guard let self else { return }
                    do {
                        let prepared = try Self.prepareNativeMediaBackground(destination, candidate: candidate)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.isExportingFromPhotos = false
                            self.currentExportURL = prepared.url
                            self.statusText = "Queued for Telegram upload"
                            var metadata = candidate.queueMetadata(destinationChatID: chatID)
                            metadata.nativeMedia?.width = prepared.width
                            metadata.nativeMedia?.height = prepared.height
                            self.queue.enqueuePreparedFile(
                                prepared.url,
                                folderID: folderID,
                                photoBackup: metadata
                            )
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.isExportingFromPhotos = false
                            self.scheduleInfrastructureRetry(
                                candidate, folderID: folderID, stage: "Media preparation",
                                message: error.localizedDescription
                            )
                        }
                    }
                }
            }
        }
    }

    private nonisolated static func prepareNativeMediaBackground(
        _ sourceURL: URL,
        candidate: PhotoBackupCandidate
    ) throws -> (url: URL, width: Int, height: Int) {
        guard candidate.mediaKind == "photo" else {
            return (sourceURL, candidate.pixelWidth, candidate.pixelHeight)
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw NSError(domain: "TGSpeicher.Photos", code: 20, userInfo: [NSLocalizedDescriptionKey: "The photo could not be decoded."])
        }
        let maxPixel = 4_096
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(domain: "TGSpeicher.Photos", code: 21, userInfo: [NSLocalizedDescriptionKey: "Telegram photo conversion failed."])
        }
        let output = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("TelegramPhoto-\(UUID().uuidString).jpg")
        for quality in [0.90, 0.82, 0.74, 0.66, 0.58] {
            try? FileManager.default.removeItem(at: output)
            guard let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            if output.fileByteSize <= 9_800_000 {
                try? FileManager.default.removeItem(at: sourceURL)
                return (output, image.width, image.height)
            }
        }
        throw NSError(domain: "TGSpeicher.Photos", code: 22, userInfo: [NSLocalizedDescriptionKey: "The optimized Telegram photo still exceeds 10 MB."])
    }

    private func handleQueue(_ items: [QueuedUpload]) {
        if let completed = items.first(where: { $0.state == .completed && $0.photoBackup != nil }) {
            if let key = completed.photoBackup?.resourceKey, recordsByKey[key] != nil {
                queue.remove(completed)
            } else {
                completeQueuedPhoto(completed)
            }
            return
        }

        guard let candidate = currentCandidate else {
            if isRunning && !isPaused { processNextIfPossible() }
            return
        }

        if currentQueueItemID == nil,
           let item = items.first(where: { $0.photoBackup?.resourceKey == candidate.resourceKey }) {
            currentQueueItemID = item.id
            if let currentExportURL {
                try? FileManager.default.removeItem(at: currentExportURL.deletingLastPathComponent())
                self.currentExportURL = nil
            }
        }

        guard let currentQueueItemID, let item = items.first(where: { $0.id == currentQueueItemID }) else { return }
        switch item.state {
        case .completed:
            completeQueuedPhoto(item)
        case .failed:
            scheduleAutomaticRetry(item)
        case .queued:
            statusText = "Waiting in Telegram upload queue"
        case .uploading:
            statusText = "Uploading \(candidate.fileName) to Telegram"
        }
    }

    private func completeQueuedPhoto(_ queueItem: QueuedUpload) {
        guard let metadata = queueItem.photoBackup else { return }
        let file = queueItem.cloudFileID.flatMap { id in cloud.index.files.first(where: { $0.id == id }) }
        guard let file else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self,
                      let current = self.queue.items.first(where: { $0.id == queueItem.id }),
                      current.state == .completed else { return }
                self.completeQueuedPhoto(current)
            }
            return
        }

        let wasNew = recordsByKey[metadata.resourceKey] == nil
        let record = PhotoBackupRecord(
            resourceKey: metadata.resourceKey,
            assetLocalIdentifier: metadata.assetLocalIdentifier,
            resourceTypeRawValue: metadata.resourceTypeRawValue,
            fileName: metadata.fileName,
            mediaKind: metadata.mediaKind,
            cloudFileID: file.id,
            creationDate: metadata.creationDate,
            uploadedAt: Date()
        )
        recordsByKey[metadata.resourceKey] = record
        deferredCandidateKeys.remove(metadata.resourceKey)
        deferredRetryCycles[metadata.resourceKey] = nil
        infrastructureRetryKeys.remove(metadata.resourceKey)
        latestCompletedRecord = record
        appendLocalJournal(record)
        checkpointRemoteIndexIfNeeded()
        if wasNew { updateCountersAfterCompleted(record) }
        if currentCandidate?.resourceKey == metadata.resourceKey {
            currentCandidate = nil
            currentQueueItemID = nil
            currentFileName = nil
        }
        iCloudProgress = 0
        queue.remove(queueItem)
        statusText = "Backed up \(backedUpAssets) / \(totalAssets) library items"
        DispatchQueue.main.async { [weak self] in self?.processNextIfPossible() }
    }

    private func nextPendingCandidate() -> PhotoBackupCandidate? {
        while pendingCandidateCursor < pendingCandidates.count {
            let candidate = pendingCandidates[pendingCandidateCursor]
            pendingCandidateCursor += 1
            if recordsByKey[candidate.resourceKey] == nil,
               !deferredCandidateKeys.contains(candidate.resourceKey) {
                return candidate
            }
        }
        return nil
    }

    private func scheduleAutomaticRetry(_ item: QueuedUpload) {
        guard isRunning, !isPaused else { return }
        let attempts = item.automaticRetryCount ?? 0
        let localCopyExists = FileManager.default.fileExists(atPath: item.localPath)
        guard attempts < 5, localCopyExists else {
            deferFailedQueueItem(item, attempts: max(1, attempts))
            return
        }
        guard scheduledRetryIDs.insert(item.id).inserted else { return }
        // Transient Telegram/iCloud failures stay visible in Transfers and are retried
        // quietly. Only a terminal failure after all retries interrupts the user.
        cloud.lastError = nil
        let delay = min(60.0, pow(2.0, Double(attempts + 1)))
        statusText = "Telegram upload interrupted • retrying in \(Int(delay))s"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduledRetryIDs.remove(item.id)
            guard self.isRunning, !self.isPaused,
                  let current = self.queue.items.first(where: { $0.id == item.id }),
                  current.state == .failed else { return }
            self.queue.retry(current, automatic: true)
        }
    }

    private func deferFailedQueueItem(_ item: QueuedUpload, attempts: Int) {
        guard let metadata = item.photoBackup else { return }
        scheduledRetryIDs.remove(item.id)
        let candidate = PhotoBackupCandidate(
            assetLocalIdentifier: metadata.assetLocalIdentifier,
            resourceTypeRawValue: metadata.resourceTypeRawValue,
            fileName: metadata.fileName,
            mediaKind: metadata.mediaKind,
            creationDate: metadata.creationDate,
            pixelWidth: metadata.nativeMedia?.width ?? 0,
            pixelHeight: metadata.nativeMedia?.height ?? 0,
            duration: metadata.nativeMedia?.duration ?? 0
        )
        let message = item.lastError ?? "Telegram upload failed repeatedly."
        let stage = FileManager.default.fileExists(atPath: item.localPath) ? "Telegram upload" : "Queue recovery"
        if currentQueueItemID == item.id {
            currentQueueItemID = nil
            currentCandidate = nil
            currentFileName = nil
        }
        queue.remove(item)
        deferCandidateAfterFailure(
            candidate,
            stage: stage,
            message: message,
            attempt: attempts,
            baseDelay: 120
        )
    }

    private func deferCandidateAfterFailure(
        _ candidate: PhotoBackupCandidate,
        stage: String,
        message: String,
        attempt: Int,
        baseDelay: TimeInterval
    ) {
        recordFailure(stage: stage, candidate: candidate, message: message, attempt: attempt)
        photoExportRetryCount[candidate.resourceKey] = nil
        let cycle = (deferredRetryCycles[candidate.resourceKey] ?? 0) + 1
        deferredRetryCycles[candidate.resourceKey] = cycle
        guard deferredCandidateKeys.insert(candidate.resourceKey).inserted else { return }

        let delay = min(3_600.0, baseDelay * pow(2.0, Double(min(cycle - 1, 4))))
        statusText = "Skipped \(candidate.fileName) for now • retrying later"
        DispatchQueue.main.async { [weak self] in self?.processNextIfPossible() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.deferredCandidateKeys.remove(candidate.resourceKey)
            guard self.isRunning, !self.isPaused,
                  self.recordsByKey[candidate.resourceKey] == nil else { return }
            self.pendingCandidates.append(candidate)
            self.statusText = "Retrying deferred item \(candidate.fileName)"
            self.processNextIfPossible()
        }
    }

    private func scheduleInfrastructureRetry(
        _ candidate: PhotoBackupCandidate,
        folderID: UUID,
        stage: String,
        message: String
    ) {
        let attempt = (photoExportRetryCount[candidate.resourceKey] ?? 0) + 1
        photoExportRetryCount[candidate.resourceKey] = attempt
        recordFailure(stage: stage, candidate: candidate, message: message, attempt: attempt)
        guard infrastructureRetryKeys.insert(candidate.resourceKey).inserted else { return }
        let delay = min(300.0, max(30.0, pow(2.0, Double(min(attempt, 7)))))
        statusText = "Storage temporarily unavailable • retrying in \(Int(delay))s"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.infrastructureRetryKeys.remove(candidate.resourceKey)
            guard self.isRunning, !self.isPaused,
                  self.currentCandidate?.resourceKey == candidate.resourceKey else { return }
            self.exportToQueue(candidate, folderID: folderID)
        }
    }

    private func resolveResource(for candidate: PhotoBackupCandidate, asset: PHAsset) -> PHAssetResource? {
        let preferred = Self.preferredResourcesBackground(for: asset)
        return preferred.first {
            $0.type.rawValue == candidate.resourceTypeRawValue &&
            ($0.originalFilename == candidate.fileName || $0.originalFilename.isEmpty)
        } ?? preferred.first { $0.type.rawValue == candidate.resourceTypeRawValue }
    }

    private nonisolated static func preferredResourcesBackground(for asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            if let full = all.first(where: { $0.type == .fullSizeVideo }) { return [full] }
            if let video = all.first(where: { $0.type == .video }) { return [video] }
            return all.first.map { [$0] } ?? []
        }

        var result: [PHAssetResource] = []
        if let full = all.first(where: { $0.type == .fullSizePhoto }) { result.append(full) }
        else if let photo = all.first(where: { $0.type == .photo }) { result.append(photo) }
        else if let first = all.first { result.append(first) }

        if asset.mediaSubtypes.contains(.photoLive) {
            if let paired = all.first(where: { $0.type == .fullSizePairedVideo }) ?? all.first(where: { $0.type == .pairedVideo }) {
                result.append(paired)
            }
        }
        return result
    }

    private nonisolated static func mediaKindBackground(asset: PHAsset, resource: PHAssetResource) -> String {
        if resource.type == .video || resource.type == .fullSizeVideo || resource.type == .pairedVideo || resource.type == .fullSizePairedVideo { return "video" }
        return asset.mediaType == .video ? "video" : "photo"
    }

    private nonisolated static func fallbackNameBackground(asset: PHAsset, resource: PHAssetResource) -> String {
        let ext: String
        switch resource.type {
        case .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo: ext = "mov"
        default: ext = "heic"
        }
        return "Photo-\(asset.localIdentifier.hashValue.magnitude).\(ext)"
    }

    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    private func ensureBackupFolder() -> UUID {
        if let folder = cloud.index.folders.first(where: { $0.parentID == nil && $0.name == "Photo Backup" }) { return folder.id }
        cloud.createFolder(name: "Photo Backup", parentID: nil)
        return cloud.index.folders.first(where: { $0.parentID == nil && $0.name == "Photo Backup" })!.id
    }

    private func reconcileRecordsWithCloudIndex() {
        let cloudIDs = Set(cloud.index.files.map(\.id))
        let stale = recordsByKey.values.filter { !cloudIDs.contains($0.cloudFileID) }.map(\.resourceKey)
        guard !stale.isEmpty, remoteIndexReady else { return }
        stale.forEach { recordsByKey.removeValue(forKey: $0) }
        persistLocalIndex()
        recalculateCounters()
    }

    private func recalculateCounters() {
        let cloudIDs = Set(cloud.index.files.map(\.id))
        var requiredCounts: [String: Int] = [:]
        var backedCounts: [String: Int] = [:]
        var newPending: [PhotoBackupCandidate] = []

        newPending.reserveCapacity(max(pendingResources, 1))
        for candidate in candidates {
            requiredCounts[candidate.assetLocalIdentifier, default: 0] += 1
            if let record = recordsByKey[candidate.resourceKey], cloudIDs.contains(record.cloudFileID) {
                backedCounts[candidate.assetLocalIdentifier, default: 0] += 1
            } else {
                newPending.append(candidate)
            }
        }

        let completeAssets = Set(requiredCounts.compactMap { assetID, required in
            backedCounts[assetID, default: 0] == required ? assetID : nil
        })
        requiredResourceCountByAssetID = requiredCounts
        backedResourceCountByAssetID = backedCounts
        fullyBackedUpAssetIDsCache = completeAssets
        pendingCandidates = newPending
        pendingCandidateCursor = 0
        totalResources = candidates.count
        pendingResources = newPending.count
        backedUpResources = max(0, totalResources - pendingResources)
        backedUpAssets = completeAssets.count
        deletableAssetCount = completeAssets.count
    }

    private func updateCountersAfterCompleted(_ record: PhotoBackupRecord) {
        guard let required = requiredResourceCountByAssetID[record.assetLocalIdentifier], required > 0 else { return }
        let previous = backedResourceCountByAssetID[record.assetLocalIdentifier, default: 0]
        guard previous < required else { return }

        let updated = previous + 1
        backedResourceCountByAssetID[record.assetLocalIdentifier] = updated
        backedUpResources = min(totalResources, backedUpResources + 1)
        pendingResources = max(0, pendingResources - 1)
        if updated == required, fullyBackedUpAssetIDsCache.insert(record.assetLocalIdentifier).inserted {
            backedUpAssets += 1
            deletableAssetCount = fullyBackedUpAssetIDsCache.count
        }
    }

    private var localIndexURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("TGSpeicher", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("photo-backup-index-v1.json")
    }

    private var localJournalURL: URL? {
        localIndexURL?.deletingLastPathComponent().appendingPathComponent("photo-backup-journal-v1.jsonl")
    }

    private var failureHistoryURL: URL? {
        localIndexURL?.deletingLastPathComponent().appendingPathComponent("photo-backup-errors-v1.json")
    }

    private func loadLocalIndex() {
        if let url = localIndexURL,
           let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(PhotoBackupSnapshot.self, from: data) {
            recordsByKey = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.resourceKey, $0) })
        }
        if let journalURL = localJournalURL, let data = try? Data(contentsOf: journalURL) {
            for line in data.split(separator: 0x0A) {
                guard let event = try? JSONDecoder().decode(PhotoBackupJournalEvent.self, from: Data(line)) else { continue }
                recordsByKey[event.record.resourceKey] = event.record
            }
        }
    }

    private func loadFailureHistory() {
        guard let url = failureHistoryURL,
              let data = try? Data(contentsOf: url),
              let failures = try? JSONDecoder().decode([PhotoBackupFailureRecord].self, from: data) else { return }
        recentFailures = Array(failures.prefix(500))
    }

    private func recordFailure(
        stage: String,
        candidate: PhotoBackupCandidate?,
        message: String,
        attempt: Int
    ) {
        if let newest = recentFailures.first,
           newest.stage == stage,
           newest.resourceKey == candidate?.resourceKey,
           newest.message == message,
           Date().timeIntervalSince(newest.occurredAt) < 3 {
            return
        }
        recentFailures.insert(
            PhotoBackupFailureRecord(
                stage: stage,
                fileName: candidate?.fileName ?? currentFileName,
                resourceKey: candidate?.resourceKey ?? currentCandidate?.resourceKey,
                message: message,
                attempt: max(1, attempt)
            ),
            at: 0
        )
        if recentFailures.count > 500 { recentFailures.removeLast(recentFailures.count - 500) }
        persistFailureHistory()
    }

    private func persistFailureHistory() {
        guard let url = failureHistoryURL,
              let data = try? JSONEncoder().encode(recentFailures) else { return }
        indexIOQueue.async { try? data.write(to: url, options: [.atomic]) }
    }

    private func captureOperationalError(_ message: String, stage: String) {
        guard isRunning, !isPaused else { return }
        recordFailure(stage: stage, candidate: currentCandidate, message: message, attempt: 1)
        if stage == "Upload queue" {
            queue.lastError = nil
            if let candidate = currentCandidate,
               currentQueueItemID == nil,
               !isExportingFromPhotos {
                scheduleInfrastructureRetry(
                    candidate,
                    folderID: ensureBackupFolder(),
                    stage: stage,
                    message: message
                )
            }
        } else if stage == "Telegram upload" {
            cloud.lastError = nil
        } else if stage == "Telegram" {
            telegram.clearError()
        }
    }

    private func persistLocalIndex() {
        guard let url = localIndexURL else { return }
        let journalURL = localJournalURL
        let snapshot = PhotoBackupSnapshot(
            revision: Int64(Date().timeIntervalSince1970),
            updatedAt: Date(),
            records: Array(recordsByKey.values)
        )
        recordsSinceLocalSnapshot = 0
        indexIOQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try data.write(to: url, options: [.atomic])
                if let journalURL { try? FileManager.default.removeItem(at: journalURL) }
            } catch { }
        }
    }

    private func appendLocalJournal(_ record: PhotoBackupRecord) {
        guard let url = localJournalURL,
              var data = try? JSONEncoder().encode(PhotoBackupJournalEvent(record: record)) else { return }
        data.append(0x0A)
        indexIOQueue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch { }
        }
        recordsSinceLocalSnapshot += 1
        if recordsSinceLocalSnapshot >= 100 { persistLocalIndex() }
    }

    private func checkpointRemoteIndexIfNeeded() {
        recordsSinceRemoteSnapshot += 1
        let age = Date().timeIntervalSince(lastRemoteSnapshotAt)
        // Checkpoints become less frequent as the library grows, keeping the number
        // of Telegram requests and large JSON encodes sublinear for huge libraries.
        let recordTarget = min(25_000, max(25, recordsByKey.count / 20))
        let ageTarget: TimeInterval = recordsByKey.count < 1_000 ? 300 : 1_800
        guard recordsSinceRemoteSnapshot >= recordTarget || age >= ageTarget else { return }
        recordsSinceRemoteSnapshot = 0
        lastRemoteSnapshotAt = Date()
        syncIndexSoon(delay: 2)
    }

    private func syncIndexSoon(delay: TimeInterval = 8) {
        syncWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.syncIndexNow() }
        syncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func syncIndexNow() {
        guard let chatID = selectedDestinationID ?? telegram.savedMessagesChatID else { return }
        guard cloud.upload == nil else { syncIndexSoon(delay: 4); return }

        let fileIDs = Set(recordsByKey.values.map(\.cloudFileID))
        let snapshot = PhotoBackupSnapshot(
            revision: Int64(Date().timeIntervalSince1970),
            updatedAt: Date(),
            records: Array(recordsByKey.values),
            files: cloud.index.files.filter { fileIDs.contains($0.id) }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicher-Photo-Backup-Index-\(UUID().uuidString).json")
        indexIOQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do { try data.write(to: url, options: [.atomic]) } catch { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.cloud.upload == nil else {
                    try? FileManager.default.removeItem(at: url)
                    self.syncIndexSoon(delay: 4)
                    return
                }
                let request: [String: Any] = [
                    "@type": "sendMessage",
                    "chat_id": chatID,
                    "topic_id": NSNull(),
                    "reply_to": NSNull(),
                    "options": NSNull(),
                    "reply_markup": NSNull(),
                    "input_message_content": [
                        "@type": "inputMessageDocument",
                        "document": ["@type": "inputFileLocal", "path": url.path],
                        "thumbnail": NSNull(),
                        "disable_content_type_detection": true,
                        "caption": ["@type": "formattedText", "text": Self.marker, "entities": []]
                    ]
                ]

                self.telegram.sendMessageAwaitingFinal(request) { [weak self] response in
                    try? FileManager.default.removeItem(at: url)
                    guard let self else { return }
                    guard response["@type"] as? String != "error", let newID = TelegramClient.int64(response["id"]) else { return }
                    let old = self.snapshotMessageID
                    self.snapshotMessageID = newID
                    self.defaults.set(newID, forKey: "photos.snapshotMessageID")
                    if let old, old != newID {
                        self.telegram.send(["@type": "deleteMessages", "chat_id": chatID, "message_ids": [old], "revoke": true])
                    }
                }
            }
        }
    }

    private func restoreRemoteIndex() {
        guard let chatID = selectedDestinationID ?? telegram.savedMessagesChatID else { return }
        telegram.send([
            "@type": "searchChatMessages",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "query": Self.marker,
            "sender_id": NSNull(),
            "from_message_id": 0,
            "offset": 0,
            "limit": 10,
            "filter": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            guard response["@type"] as? String != "error" else {
                self.remoteIndexReady = true
                self.refreshAfterRemoteIndexReady()
                return
            }
            let messages = response["messages"] as? [[String: Any]] ?? []
            guard let message = messages.first(where: { self.documentFileID(from: $0) != nil }),
                  let messageID = TelegramClient.int64(message["id"]),
                  let fileID = self.documentFileID(from: message) else {
                self.restoreNativeMediaGap(chatID: chatID, fromMessageID: 0, newerThan: .distantPast)
                return
            }
            self.snapshotMessageID = messageID
            self.defaults.set(messageID, forKey: "photos.snapshotMessageID")
            self.telegram.send([
                "@type": "downloadFile", "file_id": fileID, "priority": 32, "offset": 0, "limit": 0, "synchronous": true
            ]) { [weak self] file in
                guard let self else { return }
                if let local = file["local"] as? [String: Any], let path = local["path"] as? String,
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let snapshot = try? JSONDecoder().decode(PhotoBackupSnapshot.self, from: data) {
                    var restoredFiles = snapshot.files ?? []
                    for fileIndex in restoredFiles.indices {
                        for chunkIndex in restoredFiles[fileIndex].chunks.indices {
                            restoredFiles[fileIndex].chunks[chunkIndex].telegramFileID = nil
                        }
                    }
                    self.cloud.mergeRecoveredPhotoFiles(restoredFiles)
                    for record in snapshot.records {
                        if let existing = self.recordsByKey[record.resourceKey], existing.uploadedAt > record.uploadedAt { continue }
                        self.recordsByKey[record.resourceKey] = record
                    }
                    self.persistLocalIndex()
                    self.restoreNativeMediaGap(chatID: chatID, fromMessageID: 0, newerThan: snapshot.updatedAt)
                    return
                }
                self.restoreNativeMediaGap(chatID: chatID, fromMessageID: 0, newerThan: .distantPast)
            }
        }
    }

    private func restoreNativeMediaGap(chatID: Int64, fromMessageID: Int64, newerThan cutoff: Date) {
        telegram.send([
            "@type": "searchChatMessages", "chat_id": chatID, "topic_id": NSNull(),
            "query": TGManifest.markerV2, "sender_id": NSNull(),
            "from_message_id": fromMessageID, "offset": 0, "limit": 100, "filter": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            guard response["@type"] as? String != "error" else {
                self.remoteIndexReady = true
                self.refreshAfterRemoteIndexReady()
                return
            }
            let messages = response["messages"] as? [[String: Any]] ?? []
            var reachedSnapshot = false
            var recoveredFiles: [CloudFileEntry] = []
            for message in messages {
                let date = Date(timeIntervalSince1970: TimeInterval(TelegramClient.int64(message["date"]) ?? 0))
                if date <= cutoff { reachedSnapshot = true; continue }
                if let recovered = self.recoverNativeMediaMessage(message, chatID: chatID) {
                    recoveredFiles.append(recovered)
                }
            }
            self.cloud.mergeRecoveredPhotoFiles(recoveredFiles)
            let next = TelegramClient.int64(response["next_from_message_id"]) ?? 0
            if !reachedSnapshot, next != 0, !messages.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.restoreNativeMediaGap(chatID: chatID, fromMessageID: next, newerThan: cutoff)
                }
            } else {
                self.persistLocalIndex()
                self.remoteIndexReady = true
                self.refreshAfterRemoteIndexReady()
            }
        }
    }

    private func recoverNativeMediaMessage(_ message: [String: Any], chatID: Int64) -> CloudFileEntry? {
        guard let content = message["content"] as? [String: Any],
              let contentType = content["@type"] as? String,
              contentType == "messagePhoto" || contentType == "messageVideo",
              let caption = content["caption"] as? [String: Any],
              let text = caption["text"] as? String,
              let manifest = decodePhotoManifest(text),
              manifest.kind == "nativePhoto" || manifest.kind == "nativeVideo",
              let fileID = manifest.fileID,
              let sourceKey = manifest.sourceKey,
              let assetID = manifest.assetLocalIdentifier,
              let resourceType = manifest.resourceTypeRawValue,
              let messageID = TelegramClient.int64(message["id"]) else { return nil }

        let info = nativeFileInfo(content: content)
        let mediaKind = manifest.mediaKind ?? (contentType == "messageVideo" ? "video" : "photo")
        let entry = CloudFileEntry(
            id: fileID, name: manifest.name, folderID: manifest.folderID,
            totalSize: info.size, createdAt: manifest.mediaCreationDate ?? manifest.createdAt,
            modifiedAt: manifest.createdAt,
            chunks: [CloudChunk(index: 1, count: 1, telegramMessageID: messageID,
                telegramFileID: info.fileID, remoteUniqueID: info.uniqueID,
                size: info.size, storedName: manifest.name)],
            mimeType: mediaKind == "video" ? "video/mp4" : "image/jpeg",
            tagIDs: manifest.tagIDs ?? [], sha256: nil, sourceKey: sourceKey,
            telegramChatID: chatID,
            storageKind: mediaKind == "video" ? "nativeVideo" : "nativePhoto"
        )
        let record = PhotoBackupRecord(
            resourceKey: sourceKey, assetLocalIdentifier: assetID,
            resourceTypeRawValue: resourceType, fileName: manifest.name,
            mediaKind: mediaKind, cloudFileID: fileID,
            creationDate: manifest.mediaCreationDate, uploadedAt: manifest.createdAt
        )
        let existingDate = recordsByKey[sourceKey]?.uploadedAt ?? .distantPast
        if existingDate < record.uploadedAt {
            recordsByKey[sourceKey] = record
        }
        return entry
    }

    private func decodePhotoManifest(_ text: String) -> TGManifest? {
        guard let range = text.range(of: TGManifest.markerV2) else { return nil }
        let payload = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: payload) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TGManifest.self, from: data)
    }

    private func nativeFileInfo(content: [String: Any]) -> (fileID: Int?, uniqueID: String?, size: Int64) {
        let file: [String: Any]?
        if content["@type"] as? String == "messageVideo" {
            file = ((content["video"] as? [String: Any])?["video"] as? [String: Any])
        } else {
            let sizes = ((content["photo"] as? [String: Any])?["sizes"] as? [[String: Any]]) ?? []
            file = sizes.compactMap { $0["photo"] as? [String: Any] }.max {
                (TelegramClient.int64($0["size"]) ?? 0) < (TelegramClient.int64($1["size"]) ?? 0)
            }
        }
        guard let file else { return (nil, nil, 0) }
        return (TelegramClient.int(file["id"]), (file["remote"] as? [String: Any])?["unique_id"] as? String,
            TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0)
    }

    private func documentFileID(from message: [String: Any]) -> Int? {
        guard let content = message["content"] as? [String: Any],
              let document = content["document"] as? [String: Any],
              let file = document["document"] as? [String: Any] else { return nil }
        return TelegramClient.int(file["id"])
    }

    private func maybeAutoStart() {
        let requestedNightMode = defaults.bool(forKey: Self.nightModeKey)
        guard remoteIndexReady, hasLibraryAccess,
              defaults.bool(forKey: Self.backupEnabledKey),
              !defaults.bool(forKey: Self.pausedKey),
              (autoResumeOnLaunch || requestedNightMode),
              !isRunning, !isScanningLibrary, lastLibraryScanAt != nil else { return }

        let hasQueuedPhoto = queue.items.contains {
            $0.photoBackup != nil && ($0.state == .queued || $0.state == .uploading || $0.state == .failed)
        }
        guard pendingResources > 0 || hasQueuedPhoto else {
            persistSession(enabled: true, paused: false, nightMode: false)
            leaveNightMode()
            statusText = "Photos library is fully backed up"
            return
        }
        startBackup(nightMode: requestedNightMode)
    }

    private func refreshAfterRemoteIndexReady() {
        guard hasLibraryAccess else {
            maybeAutoStart()
            return
        }
        if isScanningLibrary {
            libraryScanGeneration = UUID()
            isScanningLibrary = false
        }
        refreshLibrary()
    }

    private func persistSession(enabled: Bool, paused: Bool, nightMode: Bool) {
        defaults.set(enabled, forKey: Self.backupEnabledKey)
        defaults.set(paused, forKey: Self.pausedKey)
        defaults.set(nightMode, forKey: Self.nightModeKey)
    }

    private func applyNightMode() {
        defaults.set(true, forKey: Self.nightModeKey)
        if previousBrightness == nil { previousBrightness = UIScreen.main.brightness }
        if previousIdleTimerDisabled == nil { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
        UIScreen.main.brightness = 0.02
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func leaveNightMode() {
        if let previousBrightness { UIScreen.main.brightness = previousBrightness }
        if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
        previousBrightness = nil
        previousIdleTimerDisabled = nil
        isNightMode = false
        defaults.set(false, forKey: Self.nightModeKey)
    }

    private func cleanupStalePhotoExports() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicherPhotoBackup", isDirectory: true)
        libraryScanQueue.async {
            let manager = FileManager.default
            guard let urls = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            for url in urls {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < cutoff { try? manager.removeItem(at: url) }
            }
        }
    }
}
