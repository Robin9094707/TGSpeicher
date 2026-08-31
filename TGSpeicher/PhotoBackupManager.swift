import Foundation
import Combine
import Photos
import UIKit

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

private struct PhotoBackupSnapshot: Codable {
    var schema = 1
    var revision: Int64
    var updatedAt: Date
    var records: [PhotoBackupRecord]
}

private struct PhotoBackupCandidate {
    let asset: PHAsset
    let resource: PHAssetResource
    let fileName: String
    let mediaKind: String

    var resourceKey: String {
        "\(asset.localIdentifier)|\(resource.type.rawValue)|\(fileName)"
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
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var isNightMode = false
    @Published private(set) var isExportingFromPhotos = false
    @Published private(set) var isVerifying = false
    @Published private(set) var currentFileName: String?
    @Published private(set) var iCloudProgress: Double = 0
    @Published private(set) var statusText = "Photo backup is ready"
    @Published var lastError: String?
    @Published var autoResumeOnLaunch: Bool {
        didSet { defaults.set(autoResumeOnLaunch, forKey: Self.autoResumeKey) }
    }

    private let cloud: CloudStore
    private let queue: UploadQueueManager
    private let telegram: TelegramClient
    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    private var candidates: [PhotoBackupCandidate] = []
    private var recordsByKey: [String: PhotoBackupRecord] = [:]
    private var currentCandidate: PhotoBackupCandidate?
    private var currentQueueItemID: UUID?
    private var enqueueStartedAt: Date?
    private var currentExportURL: URL?
    private var syncWorkItem: DispatchWorkItem?
    private var remoteIndexReady = false
    private var previousBrightness: CGFloat?
    private var previousIdleTimerDisabled: Bool?
    private var snapshotMessageID: Int64?

    private static let autoResumeKey = "photos.autoResumeOnLaunch.v1"
    private static let marker = "#TGSpeicherPhotoBackupIndexV1"

    init(cloud: CloudStore, queue: UploadQueueManager, telegram: TelegramClient) {
        self.cloud = cloud
        self.queue = queue
        self.telegram = telegram
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.autoResumeOnLaunch = defaults.object(forKey: Self.autoResumeKey) as? Bool ?? true
        self.snapshotMessageID = defaults.object(forKey: "photos.snapshotMessageID") as? Int64
        loadLocalIndex()

        queue.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.handleQueue(items) }
            .store(in: &cancellables)

        telegram.$savedMessagesChatID
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restoreRemoteIndex() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if self.hasLibraryAccess {
                    self.refreshLibrary()
                    self.maybeAutoStart()
                }
            }
            .store(in: &cancellables)

        if hasLibraryAccess { refreshLibrary() }
    }

    var hasLibraryAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var records: [PhotoBackupRecord] {
        recordsByKey.values.sorted { $0.uploadedAt > $1.uploadedAt }
    }

    var cloudGalleryFiles: [CloudFileEntry] {
        let ids = Set(recordsByKey.values.map(\.cloudFileID))
        return cloud.index.files.filter { ids.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }

    var deletableAssetCount: Int {
        fullyBackedUpAssetIDs().count
    }

    func requestFullAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationStatus = status
                if self.hasLibraryAccess {
                    self.refreshLibrary()
                    self.statusText = status == .limited ? "Limited Photos access granted" : "Full Photos access granted"
                } else {
                    self.lastError = "TGSpeicher needs Photos access to back up your library."
                }
            }
        }
    }

    func refreshLibrary() {
        guard hasLibraryAccess else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: options)
        var newCandidates: [PhotoBackupCandidate] = []
        newCandidates.reserveCapacity(fetch.count)

        fetch.enumerateObjects { asset, _, _ in
            for resource in self.preferredResources(for: asset) {
                let name = resource.originalFilename.isEmpty ? self.fallbackName(asset: asset, resource: resource) : resource.originalFilename
                let mediaKind = self.mediaKind(asset: asset, resource: resource)
                newCandidates.append(PhotoBackupCandidate(asset: asset, resource: resource, fileName: name, mediaKind: mediaKind))
            }
        }

        candidates = newCandidates
        totalAssets = fetch.count
        reconcileRecordsWithCloudIndex()
        recalculateCounters()
    }

    func startBackup(nightMode: Bool = false) {
        guard hasLibraryAccess else {
            requestFullAccess()
            return
        }
        defaults.set(true, forKey: "photos.backupEnabled")
        isRunning = true
        isPaused = false
        isNightMode = nightMode
        statusText = nightMode ? "Night backup running" : "Photo backup running"
        if nightMode { applyNightMode() }
        refreshLibrary()
        processNextIfPossible()
    }

    func pauseBackup() {
        isPaused = true
        statusText = currentQueueItemID == nil ? "Backup paused" : "Pausing after the current upload"
        leaveNightMode()
        syncIndexSoon(delay: 0.1)
    }

    func resumeBackup(nightMode: Bool = false) {
        guard hasLibraryAccess else { requestFullAccess(); return }
        isRunning = true
        isPaused = false
        isNightMode = nightMode
        if nightMode { applyNightMode() }
        statusText = nightMode ? "Night backup resumed" : "Photo backup resumed"
        processNextIfPossible()
    }

    func stopBackup() {
        isRunning = false
        isPaused = false
        currentFileName = nil
        leaveNightMode()
        statusText = "Backup stopped"
        syncIndexSoon(delay: 0.1)
    }

    func cloudFile(for record: PhotoBackupRecord) -> CloudFileEntry? {
        cloud.index.files.first { $0.id == record.cloudFileID }
    }

    func localAsset(for record: PhotoBackupRecord) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [record.assetLocalIdentifier], options: nil).firstObject
    }

    func deleteFullyBackedUpAssetsFromPhotos() {
        let ids = Array(fullyBackedUpAssetIDs())
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
              let chatID = telegram.savedMessagesChatID else {
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
        if isNightMode { applyNightMode() }

        let folderID = ensureBackupFolder()
        if queue.items.contains(where: { $0.folderID == folderID && ($0.state == .queued || $0.state == .uploading) }) {
            statusText = "Waiting for the Telegram upload queue…"
            return
        }

        reconcileRecordsWithCloudIndex()
        guard let next = candidates.first(where: { recordsByKey[$0.resourceKey] == nil }) else {
            isRunning = false
            isPaused = false
            currentFileName = nil
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

    private func exportToQueue(_ candidate: PhotoBackupCandidate, folderID: UUID) {
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
            lastError = error.localizedDescription
            pauseBackup()
            return
        }
        let destination = folder.appendingPathComponent(safeFileName(candidate.fileName))
        currentExportURL = destination

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] progress in
            DispatchQueue.main.async {
                self?.iCloudProgress = progress
                self?.statusText = progress < 1 ? "Downloading original from iCloud • \(Int(progress * 100))%" : "Preparing Telegram upload…"
            }
        }

        PHAssetResourceManager.default().writeData(for: candidate.resource, toFile: destination, options: options) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExportingFromPhotos = false
                if let error {
                    self.lastError = error.localizedDescription
                    self.statusText = "Photos export failed"
                    self.pauseBackup()
                    return
                }
                self.enqueueStartedAt = Date()
                self.statusText = "Queued for Telegram upload"
                self.queue.enqueuePreparedFile(destination, folderID: folderID)
            }
        }
    }

    private func handleQueue(_ items: [QueuedUpload]) {
        guard let candidate = currentCandidate else {
            if isRunning && !isPaused { processNextIfPossible() }
            return
        }
        let folderID = ensureBackupFolder()

        if currentQueueItemID == nil, let started = enqueueStartedAt {
            if let item = items
                .filter({ $0.folderID == folderID && $0.displayName == safeFileName(candidate.fileName) && $0.createdAt >= started.addingTimeInterval(-2) })
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first {
                currentQueueItemID = item.id
                if let currentExportURL {
                    try? FileManager.default.removeItem(at: currentExportURL.deletingLastPathComponent())
                    self.currentExportURL = nil
                }
            }
        }

        guard let currentQueueItemID, let item = items.first(where: { $0.id == currentQueueItemID }) else { return }
        switch item.state {
        case .completed:
            completeCandidate(candidate, queueItem: item, folderID: folderID)
        case .failed:
            lastError = item.lastError ?? "Telegram upload failed."
            statusText = "Backup paused after an upload error"
            isPaused = true
            leaveNightMode()
        case .queued:
            statusText = "Waiting in Telegram upload queue"
        case .uploading:
            statusText = "Uploading \(candidate.fileName) to Telegram"
        }
    }

    private func completeCandidate(_ candidate: PhotoBackupCandidate, queueItem: QueuedUpload, folderID: UUID) {
        let started = queueItem.startedAt ?? queueItem.createdAt
        guard let file = cloud.index.files
            .filter({ $0.folderID == folderID && $0.name == queueItem.displayName && $0.modifiedAt >= started.addingTimeInterval(-3) })
            .max(by: { $0.modifiedAt < $1.modifiedAt }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let candidate = self.currentCandidate else { return }
                self.completeCandidate(candidate, queueItem: queueItem, folderID: folderID)
            }
            return
        }

        recordsByKey[candidate.resourceKey] = PhotoBackupRecord(
            resourceKey: candidate.resourceKey,
            assetLocalIdentifier: candidate.asset.localIdentifier,
            resourceTypeRawValue: candidate.resource.type.rawValue,
            fileName: candidate.fileName,
            mediaKind: candidate.mediaKind,
            cloudFileID: file.id,
            creationDate: candidate.asset.creationDate,
            uploadedAt: Date()
        )
        persistLocalIndex()
        syncIndexSoon()
        currentCandidate = nil
        currentQueueItemID = nil
        enqueueStartedAt = nil
        currentFileName = nil
        iCloudProgress = 0
        recalculateCounters()
        statusText = "Backed up \(backedUpAssets) / \(totalAssets) library items"
        DispatchQueue.main.async { [weak self] in self?.processNextIfPossible() }
    }

    private func preferredResources(for asset: PHAsset) -> [PHAssetResource] {
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

    private func mediaKind(asset: PHAsset, resource: PHAssetResource) -> String {
        if resource.type == .video || resource.type == .fullSizeVideo || resource.type == .pairedVideo || resource.type == .fullSizePairedVideo { return "video" }
        return asset.mediaType == .video ? "video" : "photo"
    }

    private func fallbackName(asset: PHAsset, resource: PHAssetResource) -> String {
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
    }

    private func recalculateCounters() {
        totalResources = candidates.count
        let candidateKeys = Set(candidates.map(\.resourceKey))
        backedUpResources = candidateKeys.filter { recordsByKey[$0] != nil }.count
        pendingResources = max(0, totalResources - backedUpResources)

        let grouped = Dictionary(grouping: candidates, by: { $0.asset.localIdentifier })
        backedUpAssets = grouped.values.filter { group in group.allSatisfy { recordsByKey[$0.resourceKey] != nil } }.count
    }

    private func fullyBackedUpAssetIDs() -> Set<String> {
        let grouped = Dictionary(grouping: candidates, by: { $0.asset.localIdentifier })
        let cloudIDs = Set(cloud.index.files.map(\.id))
        return Set(grouped.compactMap { assetID, group in
            let complete = group.allSatisfy { candidate in
                guard let record = recordsByKey[candidate.resourceKey] else { return false }
                return cloudIDs.contains(record.cloudFileID)
            }
            return complete ? assetID : nil
        })
    }

    private var localIndexURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("TGSpeicher", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("photo-backup-index-v1.json")
    }

    private func loadLocalIndex() {
        guard let url = localIndexURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PhotoBackupSnapshot.self, from: data) else { return }
        recordsByKey = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.resourceKey, $0) })
    }

    private func persistLocalIndex() {
        guard let url = localIndexURL else { return }
        let snapshot = PhotoBackupSnapshot(revision: Int64(Date().timeIntervalSince1970), updatedAt: Date(), records: records)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: [.atomic]) }
    }

    private func syncIndexSoon(delay: TimeInterval = 8) {
        syncWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.syncIndexNow() }
        syncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func syncIndexNow() {
        guard let chatID = telegram.savedMessagesChatID else { return }
        guard cloud.upload == nil else { syncIndexSoon(delay: 4); return }

        let snapshot = PhotoBackupSnapshot(revision: Int64(Date().timeIntervalSince1970), updatedAt: Date(), records: records)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TGSpeicher-Photo-Backup-Index.json")
        do { try data.write(to: url, options: [.atomic]) } catch { return }

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

        telegram.sendMessageAwaitingFinal(request) { [weak self] response in
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

    private func restoreRemoteIndex() {
        guard let chatID = telegram.savedMessagesChatID else { return }
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
                self.maybeAutoStart()
                return
            }
            let messages = response["messages"] as? [[String: Any]] ?? []
            guard let message = messages.first(where: { self.documentFileID(from: $0) != nil }),
                  let messageID = TelegramClient.int64(message["id"]),
                  let fileID = self.documentFileID(from: message) else {
                self.remoteIndexReady = true
                self.maybeAutoStart()
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
                    for record in snapshot.records {
                        if let existing = self.recordsByKey[record.resourceKey], existing.uploadedAt > record.uploadedAt { continue }
                        self.recordsByKey[record.resourceKey] = record
                    }
                    self.persistLocalIndex()
                }
                self.remoteIndexReady = true
                self.refreshLibrary()
                self.maybeAutoStart()
            }
        }
    }

    private func documentFileID(from message: [String: Any]) -> Int? {
        guard let content = message["content"] as? [String: Any],
              let document = content["document"] as? [String: Any],
              let file = document["document"] as? [String: Any] else { return nil }
        return TelegramClient.int(file["id"])
    }

    private func maybeAutoStart() {
        guard remoteIndexReady, hasLibraryAccess, autoResumeOnLaunch,
              defaults.bool(forKey: "photos.backupEnabled"), !isRunning, pendingResources > 0 else { return }
        startBackup(nightMode: false)
    }

    private func applyNightMode() {
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
    }
}
