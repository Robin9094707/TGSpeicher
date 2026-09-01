import Foundation
import Combine
import UIKit
import UniformTypeIdentifiers

final class CloudStore: ObservableObject {
    @Published private(set) var index = CloudIndex()
    @Published private(set) var upload: UploadProgress?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isCatalogSyncing = false
    @Published private(set) var catalogStatus = "Local index"
    @Published private(set) var localInboxFiles: [URL] = []
    @Published var lastExportURL: URL?
    @Published private(set) var lastDownloadedFileID: UUID?
    @Published var lastError: String?

    let telegram: TelegramClient
    private let ioQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.io", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    private var catalogWorkItem: DispatchWorkItem?
    private var catalogNeedsAnotherSync = false
    private var lastCatalogSyncAt = Date.distantPast

    private let maxChunkBytes: Int64 = 1_900_000_000
    private let catalogMinimumInterval: TimeInterval = 45
    private let telegramFileReleaseDelay: TimeInterval = 8
    private let snapshotMarker = "#TGSpeicherCatalogSnapshotV2"

    init(telegram: TelegramClient) {
        self.telegram = telegram
        loadLocalIndex()
        lastCatalogSyncAt = index.lastSyncedAt ?? .distantPast
        prepareFilesIntegration()
        refreshLocalInbox()

        telegram.$savedMessagesChatID
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.bootstrapFromTelegram()
            }
            .store(in: &cancellables)
    }

    var totalTrackedBytes: Int64 { index.files.reduce(0) { $0 + $1.totalSize } }
    var totalChunks: Int { index.files.reduce(0) { $0 + $1.chunks.count } }
    var catalogPointerMessageID: Int64? { index.catalogPointerMessageID }

    var tags: [CloudTag] {
        index.tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func children(of folderID: UUID?) -> [CloudFolder] {
        index.folders
            .filter { $0.parentID == folderID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func files(in folderID: UUID?) -> [CloudFileEntry] {
        index.files
            .filter { $0.folderID == folderID }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func files(tagged tagID: UUID) -> [CloudFileEntry] {
        index.files.filter { $0.tagIDs.contains(tagID) }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func searchFiles(_ query: String) -> [CloudFileEntry] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return index.files.sorted { $0.modifiedAt > $1.modifiedAt } }
        let matchingTagIDs = Set(index.tags.filter { $0.name.localizedCaseInsensitiveContains(clean) }.map(\.id))
        return index.files.filter { file in
            file.name.localizedCaseInsensitiveContains(clean) || !matchingTagIDs.isDisjoint(with: file.tagIDs)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func folderPath(for folderID: UUID?) -> [CloudFolder] {
        var result: [CloudFolder] = []
        var current = folderID
        var guardCount = 0
        while let id = current, guardCount < 100, let folder = index.folders.first(where: { $0.id == id }) {
            result.insert(folder, at: 0)
            current = folder.parentID
            guardCount += 1
        }
        return result
    }

    // MARK: - Folder / tag metadata

    func createFolder(name: String, parentID: UUID?) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        index.folders.append(CloudFolder(name: clean, parentID: parentID))
        persistAndScheduleCatalog()
    }

    func renameFolder(_ folder: CloudFolder, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = index.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        index.folders[i].name = clean
        index.folders[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    func deleteFolder(_ folder: CloudFolder) {
        let hasChildren = index.folders.contains { $0.parentID == folder.id }
        let hasFiles = index.files.contains { $0.folderID == folder.id }
        guard !hasChildren, !hasFiles else {
            lastError = "This folder is not empty. Move or delete its contents first."
            return
        }
        index.folders.removeAll { $0.id == folder.id }
        persistAndScheduleCatalog()
    }

    func createTag(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard !index.tags.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        index.tags.append(CloudTag(name: clean))
        persistAndScheduleCatalog()
    }

    func deleteTag(_ tag: CloudTag) {
        index.tags.removeAll { $0.id == tag.id }
        for i in index.files.indices {
            index.files[i].tagIDs.removeAll { $0 == tag.id }
            index.files[i].modifiedAt = Date()
        }
        persistAndScheduleCatalog()
    }

    func setTags(_ tagIDs: [UUID], for file: CloudFileEntry) {
        guard let i = index.files.firstIndex(where: { $0.id == file.id }) else { return }
        index.files[i].tagIDs = Array(Set(tagIDs))
        index.files[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    func moveFile(_ file: CloudFileEntry, to folderID: UUID?) {
        guard let i = index.files.firstIndex(where: { $0.id == file.id }) else { return }
        index.files[i].folderID = folderID
        index.files[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    func renameFile(_ file: CloudFileEntry, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = index.files.firstIndex(where: { $0.id == file.id }) else { return }
        index.files[i].name = clean
        index.files[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    // MARK: - Upload

    @discardableResult
    func uploadFile(_ url: URL, folderID: UUID?, tagIDs: [UUID] = []) -> UUID? {
        guard upload == nil else {
            lastError = "Another upload is already running. TGSpeicher serializes uploads to protect the Telegram session."
            return nil
        }
        guard telegram.savedMessagesChatID != nil else {
            lastError = "Saved Messages is not ready yet."
            return nil
        }

        let fileID = UUID()
        let total = url.fileByteSize
        let createdAt = Date()
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        upload = UploadProgress(
            id: fileID,
            fileName: url.lastPathComponent,
            completedBytes: 0,
            totalBytes: total,
            currentPart: 0,
            partCount: 1,
            status: "Preparing and hashing…"
        )

        let accessed = url.startAccessingSecurityScopedResource()
        ioQueue.async { [weak self] in
            guard let self else { return }
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let prepared = try FileChunker.prepare(source: url, maxChunkBytes: self.maxChunkBytes) { completed, total in
                    DispatchQueue.main.async {
                        self.upload?.completedBytes = completed
                        self.upload?.totalBytes = total
                        self.upload?.status = "Splitting and verifying…"
                    }
                }

                DispatchQueue.main.async {
                    self.upload?.completedBytes = 0
                    self.upload?.partCount = prepared.chunks.count
                    self.upload?.status = "Uploading to Telegram…"
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.sendPreparedChunks(
                        prepared,
                        position: 0,
                        fileID: fileID,
                        originalName: url.lastPathComponent,
                        folderID: folderID,
                        tagIDs: tagIDs,
                        mimeType: mimeType,
                        createdAt: createdAt,
                        collected: []
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.upload = nil
                    self.lastError = error.localizedDescription
                }
            }
        }
        return fileID
    }

    private func sendPreparedChunks(
        _ prepared: PreparedFile,
        position: Int,
        fileID: UUID,
        originalName: String,
        folderID: UUID?,
        tagIDs: [UUID],
        mimeType: String?,
        createdAt: Date,
        collected: [CloudChunk]
    ) {
        guard position < prepared.chunks.count else {
            let entry = CloudFileEntry(
                id: fileID,
                name: originalName,
                folderID: folderID,
                totalSize: prepared.totalSize,
                createdAt: createdAt,
                modifiedAt: Date(),
                chunks: collected.sorted { $0.index < $1.index },
                mimeType: mimeType,
                tagIDs: tagIDs,
                sha256: prepared.sha256
            )
            index.files.removeAll { $0.id == fileID }
            index.files.append(entry)
            persist()
            cleanupPreparedFileAfterTelegramRelease(prepared)
            upload = nil
            UIApplication.shared.isIdleTimerDisabled = false
            // Batch a continuous photo run into occasional remote checkpoints. The
            // local index remains durable immediately, while Telegram API traffic
            // stays low and never competes with the next file upload.
            scheduleCatalogSync(delay: 15)
            return
        }

        guard let chatID = telegram.savedMessagesChatID else {
            failUpload("Saved Messages became unavailable.", prepared: prepared, uploadedChunks: collected)
            return
        }

        let chunk = prepared.chunks[position]
        upload?.currentPart = chunk.index
        upload?.status = chunk.count == 1 ? "Uploading file…" : "Uploading part \(chunk.index) of \(chunk.count)…"

        let manifest = TGManifest(
            format: 2,
            kind: "fileChunk",
            fileID: fileID,
            folderID: folderID,
            parentFolderID: nil,
            name: originalName,
            originalSize: prepared.totalSize,
            chunkIndex: chunk.index,
            chunkCount: chunk.count,
            createdAt: createdAt,
            tagIDs: tagIDs,
            sha256: chunk.sha256
        )

        let content: [String: Any] = [
            "@type": "inputMessageDocument",
            "document": ["@type": "inputFileLocal", "path": chunk.url.path],
            "thumbnail": NSNull(),
            "disable_content_type_detection": true,
            "caption": ["@type": "formattedText", "text": markerText(for: manifest), "entities": []]
        ]

        let request: [String: Any] = [
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "reply_to": NSNull(),
            "options": NSNull(),
            "reply_markup": NSNull(),
            "input_message_content": content
        ]

        telegram.sendMessageAwaitingFinal(request) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.failUpload(self.friendlyTelegramError(response), prepared: prepared, uploadedChunks: collected)
                return
            }

            guard let messageID = TelegramClient.int64(response["id"]) else {
                self.failUpload("Telegram confirmed the upload but returned no final message ID.", prepared: prepared, uploadedChunks: collected)
                return
            }

            let info = self.documentFileInfo(fromMessage: response)
            var next = collected
            next.append(
                CloudChunk(
                    index: chunk.index,
                    count: chunk.count,
                    telegramMessageID: messageID,
                    telegramFileID: info.fileID,
                    remoteUniqueID: info.uniqueID,
                    size: chunk.size,
                    storedName: chunk.url.lastPathComponent,
                    sha256: chunk.sha256
                )
            )

            self.upload?.completedBytes = min(prepared.totalSize, next.reduce(Int64(0)) { $0 + $1.size })
            self.sendPreparedChunks(
                prepared,
                position: position + 1,
                fileID: fileID,
                originalName: originalName,
                folderID: folderID,
                tagIDs: tagIDs,
                mimeType: mimeType,
                createdAt: createdAt,
                collected: next
            )
        }
    }

    private func failUpload(
        _ message: String,
        prepared: PreparedFile? = nil,
        uploadedChunks: [CloudChunk] = []
    ) {
        if let prepared { FileChunker.cleanup(prepared) }
        let messageIDs = uploadedChunks.compactMap(\.telegramMessageID)
        if let chatID = telegram.savedMessagesChatID, !messageIDs.isEmpty {
            telegram.send([
                "@type": "deleteMessages",
                "chat_id": chatID,
                "message_ids": messageIDs,
                "revoke": true
            ])
        }
        upload = nil
        UIApplication.shared.isIdleTimerDisabled = false
        lastError = message
    }

    // MARK: - Catalog v2

    func syncCatalogNow() {
        beginCatalogSync(force: true)
    }

    private func beginCatalogSync(force: Bool) {
        guard let chatID = telegram.savedMessagesChatID else { return }
        guard upload == nil else {
            catalogNeedsAnotherSync = true
            scheduleCatalogSync(delay: 8)
            return
        }
        if isCatalogSyncing {
            catalogNeedsAnotherSync = true
            return
        }
        if !force {
            let elapsed = Date().timeIntervalSince(lastCatalogSyncAt)
            if elapsed < catalogMinimumInterval {
                scheduleCatalogSync(delay: max(2, catalogMinimumInterval - elapsed))
                return
            }
        }

        catalogWorkItem?.cancel()
        isCatalogSyncing = true
        catalogNeedsAnotherSync = false
        catalogStatus = "Saving catalog…"
        let revision = max(index.revision + 1, Int64(Date().timeIntervalSince1970))
        let snapshot = CatalogSnapshot(
            revision: revision,
            createdAt: Date(),
            folders: index.folders,
            files: index.files,
            tags: index.tags
        )

        let marker = snapshotMarker
        let backupURL = catalogBackupFolderURL?.appendingPathComponent("TGSpeicher-Catalog-latest.json")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicher-Catalog-v2-r\(revision)-\(UUID().uuidString).json")

        // Encoding a catalog with many thousands of entries must never block SwiftUI.
        ioQueue.async { [weak self] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                if let backupURL {
                    try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: backupURL, options: [.atomic])
                }
                try data.write(to: url, options: [.atomic])

                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.upload == nil else {
                        try? FileManager.default.removeItem(at: url)
                        self.isCatalogSyncing = false
                        self.catalogNeedsAnotherSync = true
                        self.scheduleCatalogSync(delay: 8)
                        return
                    }
                    let content: [String: Any] = [
                        "@type": "inputMessageDocument",
                        "document": ["@type": "inputFileLocal", "path": url.path],
                        "thumbnail": NSNull(),
                        "disable_content_type_detection": true,
                        "caption": [
                            "@type": "formattedText",
                            "text": "\(marker) revision=\(revision)",
                            "entities": []
                        ]
                    ]
                    let request: [String: Any] = [
                        "@type": "sendMessage",
                        "chat_id": chatID,
                        "topic_id": NSNull(),
                        "reply_to": NSNull(),
                        "options": NSNull(),
                        "reply_markup": NSNull(),
                        "input_message_content": content
                    ]

                    self.telegram.sendMessageAwaitingFinal(request) { [weak self] response in
                        self?.removeTemporaryFileAfterTelegramRelease(url)
                        guard let self else { return }
                        if response["@type"] as? String == "error" {
                            self.finishCatalogFailure(response)
                            return
                        }
                        guard let snapshotID = TelegramClient.int64(response["id"]) else {
                            self.finishCatalogFailure(["@type": "error", "message": "Catalog snapshot has no final message ID."])
                            return
                        }
                        self.updateCatalogPointer(chatID: chatID, revision: revision, snapshotMessageID: snapshotID)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isCatalogSyncing = false
                    self.catalogStatus = "Catalog error"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func scheduleCatalogSync(delay: TimeInterval = 1.5) {
        catalogWorkItem?.cancel()
        catalogStatus = "Catalog update pending"
        if isCatalogSyncing {
            catalogNeedsAnotherSync = true
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.beginCatalogSync(force: false) }
        catalogWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func updateCatalogPointer(chatID: Int64, revision: Int64, snapshotMessageID: Int64) {
        let payload = CatalogPointerPayload(revision: revision, snapshotMessageID: snapshotMessageID, updatedAt: Date())
        let text = pointerText(payload)

        if let pointerID = index.catalogPointerMessageID {
            telegram.send([
                "@type": "editMessageText",
                "chat_id": chatID,
                "message_id": pointerID,
                "reply_markup": NSNull(),
                "input_message_content": inputText(text)
            ]) { [weak self] response in
                guard let self else { return }
                if response["@type"] as? String == "error" {
                    self.createCatalogPointer(chatID: chatID, text: text, revision: revision, snapshotMessageID: snapshotMessageID)
                } else {
                    self.finishCatalogSuccess(pointerID: pointerID, snapshotID: snapshotMessageID, revision: revision)
                }
            }
        } else {
            createCatalogPointer(chatID: chatID, text: text, revision: revision, snapshotMessageID: snapshotMessageID)
        }
    }

    private func createCatalogPointer(chatID: Int64, text: String, revision: Int64, snapshotMessageID: Int64) {
        let request: [String: Any] = [
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "reply_to": NSNull(),
            "options": NSNull(),
            "reply_markup": NSNull(),
            "input_message_content": inputText(text)
        ]
        telegram.sendMessageAwaitingFinal(request) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.finishCatalogFailure(response)
                return
            }
            guard let pointerID = TelegramClient.int64(response["id"]) else {
                self.finishCatalogFailure(["@type": "error", "message": "Catalog pointer has no final message ID."])
                return
            }
            self.finishCatalogSuccess(pointerID: pointerID, snapshotID: snapshotMessageID, revision: revision)
        }
    }

    private func finishCatalogSuccess(pointerID: Int64, snapshotID: Int64, revision: Int64) {
        index.version = 2
        index.revision = revision
        index.catalogPointerMessageID = pointerID
        index.catalogSnapshotMessageID = snapshotID
        index.lastSyncedAt = Date()
        lastCatalogSyncAt = index.lastSyncedAt ?? Date()
        persist()
        isCatalogSyncing = false
        catalogStatus = "Catalog synced • r\(revision)"

        if catalogNeedsAnotherSync {
            catalogNeedsAnotherSync = false
            scheduleCatalogSync(delay: catalogMinimumInterval)
        }
    }

    private func finishCatalogFailure(_ response: [String: Any]) {
        isCatalogSyncing = false
        let rawMessage = response["message"] as? String ?? ""
        if rawMessage.localizedCaseInsensitiveContains("real file path") {
            catalogStatus = "Catalog retry pending"
            catalogNeedsAnotherSync = true
            scheduleCatalogSync(delay: 8)
            return
        }
        if let wait = TelegramClient.retryAfterSeconds(response) {
            catalogStatus = "Rate limited • retry in \(wait)s"
            catalogNeedsAnotherSync = true
            scheduleCatalogSync(delay: TimeInterval(wait + 1))
        } else {
            catalogStatus = "Catalog sync failed"
            lastError = friendlyTelegramError(response)
        }
    }

    private func pointerText(_ payload: CatalogPointerPayload) -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return CatalogPointerPayload.marker }
        return "\(CatalogPointerPayload.marker) \(data.base64EncodedString())"
    }

    private func decodePointer(_ text: String) -> CatalogPointerPayload? {
        guard let range = text.range(of: CatalogPointerPayload.marker) else { return nil }
        let encoded = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CatalogPointerPayload.self, from: data)
    }

    // MARK: - Fast recovery

    func bootstrapFromTelegram() {
        guard telegram.savedMessagesChatID != nil, !isRefreshing else { return }
        isRefreshing = true
        catalogStatus = "Checking Telegram catalog…"
        if let pointerID = index.catalogPointerMessageID {
            loadCatalogPointer(messageID: pointerID, searchFallback: true)
        } else {
            searchCatalogPointer()
        }
    }

    func restoreFromCatalogPointer(_ rawMessageID: String) {
        let clean = rawMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = Int64(clean), id != 0 else {
            lastError = "Enter a valid Telegram catalog pointer message ID."
            return
        }
        guard telegram.savedMessagesChatID != nil else {
            lastError = "Telegram must be connected first."
            return
        }
        isRefreshing = true
        catalogStatus = "Restoring from message \(id)…"
        loadCatalogPointer(messageID: id, searchFallback: false)
    }

    func fullRebuildFromTelegram() {
        guard telegram.savedMessagesChatID != nil, !isRefreshing else { return }
        isRefreshing = true
        catalogStatus = "Searching catalog snapshots…"
        searchLatestSnapshot()
    }

    private func loadCatalogPointer(messageID: Int64, searchFallback: Bool) {
        guard let chatID = telegram.savedMessagesChatID else { return }
        telegram.send(["@type": "getMessage", "chat_id": chatID, "message_id": messageID]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                if searchFallback { self.searchCatalogPointer() }
                else { self.isRefreshing = false; self.lastError = self.friendlyTelegramError(response) }
                return
            }
            guard let text = self.messageText(response), let pointer = self.decodePointer(text) else {
                if searchFallback { self.searchCatalogPointer() }
                else { self.isRefreshing = false; self.lastError = "That message is not a TGSpeicher v2 catalog pointer." }
                return
            }
            self.index.catalogPointerMessageID = messageID
            if self.index.revision >= pointer.revision,
               self.index.catalogSnapshotMessageID == pointer.snapshotMessageID,
               !self.index.files.isEmpty || !self.index.folders.isEmpty {
                self.isRefreshing = false
                self.catalogStatus = "Catalog already current • r\(pointer.revision)"
                self.persist()
                return
            }
            self.loadCatalogSnapshot(messageID: pointer.snapshotMessageID, pointerID: messageID)
        }
    }

    private func searchCatalogPointer() {
        guard let chatID = telegram.savedMessagesChatID else { return }
        telegram.send([
            "@type": "searchChatMessages",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "query": CatalogPointerPayload.marker,
            "sender_id": NSNull(),
            "from_message_id": 0,
            "offset": 0,
            "limit": 20,
            "filter": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.isRefreshing = false
                self.lastError = self.friendlyTelegramError(response)
                return
            }
            if let messages = response["messages"] as? [[String: Any]] {
                for message in messages {
                    if let text = self.messageText(message), self.decodePointer(text) != nil,
                       let id = TelegramClient.int64(message["id"]) {
                        self.loadCatalogPointer(messageID: id, searchFallback: false)
                        return
                    }
                }
            }
            self.searchLatestSnapshot()
        }
    }

    private func searchLatestSnapshot() {
        guard let chatID = telegram.savedMessagesChatID else { return }
        telegram.send([
            "@type": "searchChatMessages",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "query": snapshotMarker,
            "sender_id": NSNull(),
            "from_message_id": 0,
            "offset": 0,
            "limit": 20,
            "filter": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.isRefreshing = false
                self.lastError = self.friendlyTelegramError(response)
                return
            }
            if let messages = response["messages"] as? [[String: Any]],
               let message = messages.first(where: { self.documentFileInfo(fromMessage: $0).fileID != nil }),
               let id = TelegramClient.int64(message["id"]) {
                self.loadCatalogSnapshot(messageID: id, pointerID: self.index.catalogPointerMessageID)
                return
            }

            if !self.index.files.isEmpty || !self.index.folders.isEmpty {
                self.isRefreshing = false
                self.catalogStatus = "Migrating local index to v2 catalog"
                self.scheduleCatalogSync(delay: 0.2)
            } else {
                self.catalogStatus = "No catalog found • scanning legacy markers"
                self.fetchLegacyMarkerPage(chatID: chatID, fromMessageID: 0, accumulated: [])
            }
        }
    }

    private func loadCatalogSnapshot(messageID: Int64, pointerID: Int64?) {
        guard let chatID = telegram.savedMessagesChatID else { return }
        catalogStatus = "Downloading catalog snapshot…"
        telegram.send(["@type": "getMessage", "chat_id": chatID, "message_id": messageID]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.isRefreshing = false
                self.lastError = self.friendlyTelegramError(response)
                return
            }
            guard let fileID = self.documentFileInfo(fromMessage: response).fileID else {
                self.isRefreshing = false
                self.lastError = "The catalog snapshot message no longer contains its JSON document."
                return
            }
            self.telegram.send([
                "@type": "downloadFile",
                "file_id": fileID,
                "priority": 32,
                "offset": 0,
                "limit": 0,
                "synchronous": true
            ]) { [weak self] file in
                guard let self else { return }
                if file["@type"] as? String == "error" {
                    self.isRefreshing = false
                    self.lastError = self.friendlyTelegramError(file)
                    return
                }
                guard let local = file["local"] as? [String: Any],
                      let path = local["path"] as? String, !path.isEmpty else {
                    self.isRefreshing = false
                    self.lastError = "Telegram did not return a local catalog file."
                    return
                }
                self.applyCatalogSnapshot(at: URL(fileURLWithPath: path), snapshotMessageID: messageID, pointerMessageID: pointerID)
            }
        }
    }

    private func applyCatalogSnapshot(at url: URL, snapshotMessageID: Int64, pointerMessageID: Int64?) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
            guard snapshot.schema == CatalogSnapshot.schema else { throw CocoaError(.fileReadCorruptFile) }

            var restoredFiles = snapshot.files
            // TDLib file IDs are local-session identifiers. Message IDs are the durable recovery key.
            for fileIndex in restoredFiles.indices {
                for chunkIndex in restoredFiles[fileIndex].chunks.indices {
                    restoredFiles[fileIndex].chunks[chunkIndex].telegramFileID = nil
                }
            }

            index = CloudIndex(
                version: 2,
                revision: snapshot.revision,
                folders: snapshot.folders,
                files: restoredFiles,
                tags: snapshot.tags,
                catalogPointerMessageID: pointerMessageID ?? index.catalogPointerMessageID,
                catalogSnapshotMessageID: snapshotMessageID,
                lastSyncedAt: Date()
            )
            persist()
            writeLocalCatalogBackup(data)
            isRefreshing = false
            catalogStatus = "Restored instantly • r\(snapshot.revision)"
        } catch {
            isRefreshing = false
            catalogStatus = "Catalog restore failed"
            lastError = "The TGSpeicher catalog could not be decoded: \(error.localizedDescription)"
        }
    }

    // MARK: - Legacy recovery

    private func fetchLegacyMarkerPage(chatID: Int64, fromMessageID: Int64, accumulated: [[String: Any]]) {
        telegram.send([
            "@type": "searchChatMessages",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "query": TGManifest.marker,
            "sender_id": NSNull(),
            "from_message_id": fromMessageID,
            "offset": 0,
            "limit": 100,
            "filter": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.isRefreshing = false
                self.lastError = self.friendlyTelegramError(response)
                return
            }
            var next = accumulated
            if let page = response["messages"] as? [[String: Any]] { next.append(contentsOf: page) }
            let nextID = TelegramClient.int64(response["next_from_message_id"]) ?? 0
            if nextID != 0, next.count < 20_000 {
                self.fetchLegacyMarkerPage(chatID: chatID, fromMessageID: nextID, accumulated: next)
            } else {
                self.rebuildLegacyIndex(from: next)
                self.isRefreshing = false
                self.catalogStatus = "Legacy index rebuilt • creating v2 catalog"
                self.scheduleCatalogSync(delay: 0.3)
            }
        }
    }

    private func rebuildLegacyIndex(from messages: [[String: Any]]) {
        var foldersByID: [UUID: CloudFolder] = [:]
        struct TempFile {
            var name: String
            var folderID: UUID?
            var totalSize: Int64
            var createdAt: Date
            var chunks: [CloudChunk]
            var mimeType: String?
            var tagIDs: [UUID]
        }
        var filesByID: [UUID: TempFile] = [:]

        for message in messages {
            guard let content = message["content"] as? [String: Any] else { continue }
            var marker: String?
            if content["@type"] as? String == "messageText", let text = content["text"] as? [String: Any] {
                marker = text["text"] as? String
            } else if content["@type"] as? String == "messageDocument", let caption = content["caption"] as? [String: Any] {
                marker = caption["text"] as? String
            }
            guard let marker, let manifest = decodeManifest(from: marker) else { continue }

            if manifest.kind == "folder", let folderID = manifest.folderID {
                foldersByID[folderID] = CloudFolder(id: folderID, name: manifest.name, parentID: manifest.parentFolderID, createdAt: manifest.createdAt, modifiedAt: manifest.createdAt)
                continue
            }
            guard manifest.kind == "fileChunk", let fileID = manifest.fileID else { continue }

            let info = documentFileInfo(fromMessage: message)
            let contentDocument = content["document"] as? [String: Any]
            let storedName = contentDocument?["file_name"] as? String ?? manifest.name
            let mime = contentDocument?["mime_type"] as? String
            let part = manifest.chunkIndex ?? 1
            let count = manifest.chunkCount ?? 1
            let chunk = CloudChunk(
                index: part,
                count: count,
                telegramMessageID: TelegramClient.int64(message["id"]),
                telegramFileID: info.fileID,
                remoteUniqueID: info.uniqueID,
                size: info.size,
                storedName: storedName,
                sha256: manifest.sha256
            )

            var temp = filesByID[fileID] ?? TempFile(
                name: manifest.name,
                folderID: manifest.folderID,
                totalSize: manifest.originalSize ?? 0,
                createdAt: manifest.createdAt,
                chunks: [],
                mimeType: mime,
                tagIDs: manifest.tagIDs ?? []
            )
            temp.chunks.removeAll { $0.index == part }
            temp.chunks.append(chunk)
            filesByID[fileID] = temp
        }

        index.folders = Array(foldersByID.values)
        index.files = filesByID.map { id, temp in
            CloudFileEntry(
                id: id,
                name: temp.name,
                folderID: temp.folderID,
                totalSize: temp.totalSize > 0 ? temp.totalSize : temp.chunks.reduce(0) { $0 + $1.size },
                createdAt: temp.createdAt,
                modifiedAt: temp.createdAt,
                chunks: temp.chunks.sorted { $0.index < $1.index },
                mimeType: temp.mimeType,
                tagIDs: temp.tagIDs
            )
        }
        index.version = 2
        persist()
    }

    // MARK: - Download / deletion

    func downloadAndReassemble(_ file: CloudFileEntry) {
        guard !isDownloading else { return }
        guard !file.chunks.isEmpty else {
            lastError = "This file has no Telegram chunks."
            return
        }
        isDownloading = true
        resolveFreshChunkFiles(file: file, position: 0, resolved: [])
    }

    private func resolveFreshChunkFiles(file: CloudFileEntry, position: Int, resolved: [CloudChunk]) {
        let ordered = file.chunks.sorted { $0.index < $1.index }
        guard position < ordered.count else {
            if let i = index.files.firstIndex(where: { $0.id == file.id }) {
                index.files[i].chunks = resolved
                persist()
            }
            downloadResolvedChunks(resolved, position: 0, localURLs: [], file: file)
            return
        }
        guard let chatID = telegram.savedMessagesChatID else { isDownloading = false; return }
        var chunk = ordered[position]

        guard let messageID = chunk.telegramMessageID else {
            if chunk.telegramFileID != nil {
                var next = resolved; next.append(chunk)
                resolveFreshChunkFiles(file: file, position: position + 1, resolved: next)
            } else {
                isDownloading = false
                lastError = "Chunk \(chunk.index) has no Telegram message ID. Restore the catalog or rebuild the index."
            }
            return
        }

        telegram.send(["@type": "getMessage", "chat_id": chatID, "message_id": messageID]) { [weak self] message in
            guard let self else { return }
            if message["@type"] as? String == "error" {
                self.isDownloading = false
                self.lastError = self.friendlyTelegramError(message)
                return
            }
            let info = self.documentFileInfo(fromMessage: message)
            guard let fileID = info.fileID else {
                self.isDownloading = false
                self.lastError = "Telegram message \(messageID) no longer contains chunk \(chunk.index)."
                return
            }
            chunk.telegramFileID = fileID
            chunk.remoteUniqueID = info.uniqueID
            if info.size > 0 { chunk.size = info.size }
            var next = resolved; next.append(chunk)
            self.resolveFreshChunkFiles(file: file, position: position + 1, resolved: next)
        }
    }

    private func downloadResolvedChunks(_ chunks: [CloudChunk], position: Int, localURLs: [URL], file: CloudFileEntry) {
        guard position < chunks.count else {
            assembleDownloadedChunks(localURLs, file: file)
            return
        }
        guard let fileID = chunks[position].telegramFileID else {
            isDownloading = false
            lastError = "Telegram file identifier is missing for part \(chunks[position].index)."
            return
        }
        telegram.send([
            "@type": "downloadFile",
            "file_id": fileID,
            "priority": 32,
            "offset": 0,
            "limit": 0,
            "synchronous": true
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.isDownloading = false
                self.lastError = self.friendlyTelegramError(response)
                return
            }
            guard let local = response["local"] as? [String: Any],
                  local["is_downloading_completed"] as? Bool == true,
                  let path = local["path"] as? String, !path.isEmpty else {
                self.isDownloading = false
                self.lastError = "Telegram did not provide a completed local chunk."
                return
            }
            var next = localURLs; next.append(URL(fileURLWithPath: path))
            self.downloadResolvedChunks(chunks, position: position + 1, localURLs: next, file: file)
        }
    }

    private func assembleDownloadedChunks(_ chunks: [URL], file: CloudFileEntry) {
        guard let downloads = downloadsFolderURL else {
            isDownloading = false
            lastError = "TGSpeicher could not open its Downloads folder."
            return
        }
        let destination = uniqueDestination(in: downloads, preferredName: file.name)
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try FileChunker.join(chunks: chunks, destination: destination) { _ in }
                if let expected = file.sha256 {
                    let actual = try FileChunker.sha256(of: destination)
                    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                        try? FileManager.default.removeItem(at: destination)
                        throw NSError(domain: "TGSpeicher", code: 1002, userInfo: [NSLocalizedDescriptionKey: "SHA-256 verification failed after download. The rebuilt file was removed."])
                    }
                }
                DispatchQueue.main.async {
                    self.lastExportURL = destination
                    self.lastDownloadedFileID = file.id
                    self.isDownloading = false
                    self.refreshLocalInbox()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteFileFromTelegram(_ file: CloudFileEntry) {
        guard let chatID = telegram.savedMessagesChatID else { return }
        let ids = file.chunks.compactMap(\.telegramMessageID)
        guard !ids.isEmpty else {
            index.files.removeAll { $0.id == file.id }
            persistAndScheduleCatalog()
            return
        }
        telegram.send(["@type": "deleteMessages", "chat_id": chatID, "message_ids": ids, "revoke": true]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.lastError = self.friendlyTelegramError(response)
                return
            }
            self.index.files.removeAll { $0.id == file.id }
            self.persistAndScheduleCatalog()
        }
    }

    func deleteLocalIndexEntry(_ file: CloudFileEntry) {
        index.files.removeAll { $0.id == file.id }
        persist()
    }

    // MARK: - Apple Files integration

    var downloadsFolderURL: URL? { documentsFolderURL?.appendingPathComponent("Downloads", isDirectory: true) }
    var inboxFolderURL: URL? { documentsFolderURL?.appendingPathComponent("Upload Inbox", isDirectory: true) }
    var catalogBackupFolderURL: URL? { documentsFolderURL?.appendingPathComponent("Catalog Backups", isDirectory: true) }

    func refreshLocalInbox() {
        guard let inbox = inboxFolderURL else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        localInboxFiles = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var documentsFolderURL: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private func prepareFilesIntegration() {
        for url in [downloadsFolderURL, inboxFolderURL, catalogBackupFolderURL].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func uniqueDestination(in folder: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (preferredName as NSString).pathExtension
        let base = (preferredName as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    private func writeLocalCatalogBackup(_ data: Data) {
        guard let folder = catalogBackupFolderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("TGSpeicher-Catalog-latest.json"), options: [.atomic])
    }

    // MARK: - Helpers

    private func persistAndScheduleCatalog() {
        persist()
        scheduleCatalogSync()
    }

    private func cleanupPreparedFileAfterTelegramRelease(_ prepared: PreparedFile) {
        guard prepared.temporaryDirectory != nil else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + telegramFileReleaseDelay) {
            FileChunker.cleanup(prepared)
        }
    }

    private func removeTemporaryFileAfterTelegramRelease(_ url: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + telegramFileReleaseDelay) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func inputText(_ text: String) -> [String: Any] {
        [
            "@type": "inputMessageText",
            "text": ["@type": "formattedText", "text": text, "entities": []],
            "link_preview_options": NSNull(),
            "clear_draft": false
        ]
    }

    private func markerText(for manifest: TGManifest) -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return TGManifest.markerV2 }
        return "\(manifest.format >= 2 ? TGManifest.markerV2 : TGManifest.marker) \(data.base64EncodedString())"
    }

    private func decodeManifest(from text: String) -> TGManifest? {
        let marker: String
        if text.contains(TGManifest.markerV2) { marker = TGManifest.markerV2 }
        else if text.contains(TGManifest.marker) { marker = TGManifest.marker }
        else { return nil }
        guard let range = text.range(of: marker) else { return nil }
        let payload = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: payload) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TGManifest.self, from: data)
    }

    private func messageText(_ message: [String: Any]) -> String? {
        guard let content = message["content"] as? [String: Any], content["@type"] as? String == "messageText",
              let text = content["text"] as? [String: Any] else { return nil }
        return text["text"] as? String
    }

    private func documentFileInfo(fromMessage message: [String: Any]) -> (fileID: Int?, uniqueID: String?, size: Int64) {
        guard let content = message["content"] as? [String: Any],
              let document = content["document"] as? [String: Any],
              let file = document["document"] as? [String: Any] else { return (nil, nil, 0) }
        let fileID = TelegramClient.int(file["id"])
        let size = TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
        let uniqueID = (file["remote"] as? [String: Any])?["unique_id"] as? String
        return (fileID, uniqueID, size)
    }

    private func friendlyTelegramError(_ response: [String: Any]) -> String {
        if let wait = TelegramClient.retryAfterSeconds(response) {
            return "Telegram rate limit: wait about \(wait) seconds and try again."
        }
        return (response["message"] as? String ?? "Telegram returned an error.")
            .replacingOccurrences(of: "_", with: " ")
    }

    private var localIndexURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("TGSpeicher", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cloud-index.json")
    }

    private func loadLocalIndex() {
        guard let url = localIndexURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(CloudIndex.self, from: data) else { return }
        index = value
    }

    private func persist() {
        guard let url = localIndexURL, let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: [.atomic])
        objectWillChange.send()
    }
}
