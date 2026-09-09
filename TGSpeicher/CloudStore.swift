import Foundation
import Combine
import UIKit
import UniformTypeIdentifiers

final class CloudStore: ObservableObject {
    @Published var index = CloudIndex()
    @Published var upload: UploadProgress?
    @Published var isRefreshing = false
    @Published var isDownloading = false
    @Published var isCatalogSyncing = false
    @Published var catalogStatus = "Lokaler Katalog"
    @Published var localInboxFiles: [URL] = []
    @Published var lastExportURL: URL?
    @Published var lastDownloadedFileID: UUID?
    @Published var lastError: String?
    @Published var deletingFileIDs = Set<UUID>()
    @Published var isDeleting = false
    @Published var deletionStatus = ""
    @Published var deletionError: String?
    lazy var deletionQueue = DurableDeletionQueue(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TGSpeicher/Deletions-v1"),
        request: { [weak self] request, done in self?.telegram.send(request, completion: done) },
        commit: { [weak self] file, account in self?.commitDeletedFile(file, account: account) ?? false },
        changed: { [weak self] ids, running, status, error in
            self?.deletingFileIDs = ids; self?.isDeleting = running
            self?.deletionStatus = status; self?.deletionError = error
        }
    )
    var lastUploadFailure: String?

    let telegram: TelegramClient
    private let ioQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.io", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    private var catalogWorkItem: DispatchWorkItem?
    private var catalogNeedsAnotherSync = false
    private var lastCatalogSyncAt = Date.distantPast

    private let catalogMinimumInterval: TimeInterval = 45
    private let telegramFileReleaseDelay: TimeInterval = 8
    let snapshotMarker = "#TGSpeicherCatalogSnapshotV3"
    @Published var recoveryReady = false
    @Published var recoveryProgress = "Wiederherstellung steht aus"
    @Published var keychainStatus = "Noch nicht gespeichert"
    @Published var lastCatalogBytes: Int = 0
    var recoveryRun = UUID()
    var recoveryCandidates: [Int64] = []
    var recoveryNextCursor: Int64 = 0
    var recoverySearchMarker = "#TGSpeicherCatalogSnapshotV3"
    var scannedRecoveryFiles: [UUID: CloudFileEntry] = [:]
    var knownRecoveryFileIDs = Set<UUID>()
    var recoveryPageFiles: [CloudFileEntry] = []
    var scanHighWater: Int64 = 0
    var pendingDestinationID: Int64?
    var catalogMutation: Int64 = 0
    var syncingMutation: Int64 = 0
    var forceNextCatalog = false
    var nextCheckpointAttempt = Date.distantPast
    var lastSuccessfulMutation: Int64 = -1

    func checkpointBeforeNextUpload() -> Bool {
        guard recoveryReady, upload == nil, !isRefreshing, !isCatalogSyncing,
              catalogMutation != lastSuccessfulMutation,
              Date() >= nextCheckpointAttempt || forceNextCatalog else { return false }
        nextCheckpointAttempt = Date().addingTimeInterval(45)
        beginCatalogSync(force: true)
        return isCatalogSyncing
    }

    init(telegram: TelegramClient) {
        self.telegram = telegram
        loadLocalIndex()
        lastCatalogSyncAt = index.lastSyncedAt ?? .distantPast
        prepareFilesIntegration()
        refreshLocalInbox()

        telegram.$savedMessagesChatID
            .removeDuplicates()
            .sink { [weak self] account in
                guard let self else { return }
                self.deletionQueue.pause()
                if account != nil { self.bootstrapFromTelegram() }
                else { self.recoveryReady = false }
            }
            .store(in: &cancellables)
    }

    var totalTrackedBytes: Int64 { index.files.reduce(0) { $0 + $1.totalSize } }
    var totalChunks: Int { index.files.reduce(0) { $0 + $1.chunks.count } }
    var catalogPointerMessageID: Int64? { index.catalogPointerMessageID }

    func mergeRecoveredPhotoFiles(_ files: [CloudFileEntry]) {
        guard !files.isEmpty else { return }
        var changed = false
        for file in files {
            if let existing = index.files.firstIndex(where: { $0.id == file.id }) {
                if index.files[existing].modifiedAt < file.modifiedAt {
                    index.files[existing] = file
                    changed = true
                }
            } else {
                index.files.append(file)
                changed = true
            }
        }
        if changed { persistAndScheduleCatalog() }
    }

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
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        index.folders.append(CloudFolder(name: clean, parentID: parentID))
        persistAndScheduleCatalog()
    }

    func renameFolder(_ folder: CloudFolder, to name: String) {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = index.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        index.folders[i].name = clean
        index.folders[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    func deleteFolder(_ folder: CloudFolder) {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        let hasChildren = index.folders.contains { $0.parentID == folder.id }
        let hasFiles = index.files.contains { $0.folderID == folder.id }
        guard !hasChildren, !hasFiles else {
            lastError = "Dieser Ordner ist nicht leer. Verschiebe oder lösche zuerst seinen Inhalt."
            return
        }
        index.recovery?.deletedFolders[folder.id] = Date()
        index.folders.removeAll { $0.id == folder.id }
        persistAndScheduleCatalog()
    }

    func createTag(name: String) {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard !index.tags.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        index.tags.append(CloudTag(name: clean))
        persistAndScheduleCatalog()
    }

    func deleteTag(_ tag: CloudTag) {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        index.recovery?.deletedTags[tag.id] = Date()
        index.tags.removeAll { $0.id == tag.id }
        for i in index.files.indices {
            index.files[i].tagIDs.removeAll { $0 == tag.id }
            index.files[i].modifiedAt = Date()
        }
        persistAndScheduleCatalog()
    }

    func setTags(_ tagIDs: [UUID], for file: CloudFileEntry) {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        guard let i = index.files.firstIndex(where: { $0.id == file.id }) else { return }
        index.files[i].tagIDs = Array(Set(tagIDs))
        index.files[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    func moveFile(_ file: CloudFileEntry, to folderID: UUID?) {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        guard let i = index.files.firstIndex(where: { $0.id == file.id }) else { return }
        index.files[i].folderID = folderID
        index.files[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    func renameFile(_ file: CloudFileEntry, to name: String) {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst die Wiederherstellung abschließen."; return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = index.files.firstIndex(where: { $0.id == file.id }) else { return }
        index.files[i].name = clean
        index.files[i].modifiedAt = Date()
        persistAndScheduleCatalog()
    }

    // MARK: - Upload

    @discardableResult
    func uploadFile(
        _ url: URL,
        folderID: UUID?,
        tagIDs: [UUID] = [],
        stableFileID: UUID? = nil,
        sourceKey: String? = nil,
        destinationChatID: Int64? = nil,
        nativeMedia: NativeMediaUploadDescriptor? = nil,
        photoBackup: PhotoBackupQueueMetadata? = nil
    ) -> UUID? {
        guard recoveryReady, !isRefreshing else { lastError = "Bitte zuerst den Telegram-Katalog wiederherstellen."; return nil }
        guard upload == nil else {
            lastError = "Ein anderer Upload läuft bereits. Die Dateien werden nacheinander übertragen."
            return nil
        }
        guard let chatID = destinationChatID ?? telegram.savedMessagesChatID else {
            lastError = "Das Telegram-Sicherungsziel ist noch nicht bereit."
            return nil
        }

        // Queue retries reuse the same ID. If the app is reopened after Telegram
        // accepted a file, the persisted cloud entry can be recognized instead of
        // creating a second logical upload with a fresh ID.
        lastUploadFailure = nil
        let fileID = stableFileID ?? UUID()
        let total = url.fileByteSize
        guard index.recovery?.deletedFiles[fileID] == nil else {
            lastUploadFailure = "Diese Datei wurde bewusst aus Telegram gelöscht und wird nicht automatisch erneut gesichert."
            lastError = lastUploadFailure
            return nil
        }
        let layout: UploadLayout
        do {
            let eligibleKind = (nativeMedia?.kind != "photo" || total <= 10_000_000) && total <= telegram.maxUploadBytes ? nativeMedia?.kind : nil
            layout = try telegram.resolveUploadLayout(fileID: fileID, chatID: chatID, total: total, nativeKind: eligibleKind,
                partial: index.recovery?.partialFiles.first { $0.id == fileID && $0.telegramChatID == chatID })
        } catch {
            lastUploadFailure = error.localizedDescription; lastError = lastUploadFailure; return nil
        }
        let createdAt = Date()
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        upload = UploadProgress(
            id: fileID,
            fileName: url.lastPathComponent,
            completedBytes: 0,
            totalBytes: total,
            currentPart: 0,
            partCount: 1,
            status: "Datei und Prüfsumme werden vorbereitet …"
        )

        if let nativeMedia, layout.nativeKind == nativeMedia.kind {
            sendNativeMedia(
                url: url,
                chatID: chatID,
                fileID: fileID,
                folderID: folderID,
                tagIDs: tagIDs,
                sourceKey: sourceKey,
                descriptor: nativeMedia,
                photoBackup: photoBackup,
                createdAt: createdAt,
                mimeType: mimeType
            )
        } else {
            prepareDocumentUpload(
                url: url,
                chatID: chatID,
                fileID: fileID,
                folderID: folderID,
                tagIDs: tagIDs,
                sourceKey: sourceKey,
                createdAt: createdAt,
                mimeType: mimeType
            )
        }
        return fileID
    }

    private func prepareDocumentUpload(
        url: URL,
        chatID: Int64,
        fileID: UUID,
        folderID: UUID?,
        tagIDs: [UUID],
        sourceKey: String?,
        createdAt: Date,
        mimeType: String?
    ) {
        let chunkBytes: Int64
        do {
            let layout = try telegram.resolveUploadLayout(fileID: fileID, chatID: chatID, total: url.fileByteSize,
                nativeKind: nil, partial: index.recovery?.partialFiles.first { $0.id == fileID && $0.telegramChatID == chatID })
            guard layout.nativeKind == nil else { throw RecoveryError.invalid("Dieser Upload wurde als Medium begonnen. Bitte den ursprünglichen Eintrag erneut prüfen.") }
            chunkBytes = layout.chunkBytes
        } catch { failUpload(error.localizedDescription); return }
        let accessed = url.startAccessingSecurityScopedResource()
        ioQueue.async { [weak self] in
            guard let self else { return }
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let prepared = try FileChunker.prepare(source: url, maxChunkBytes: chunkBytes) { completed, total in
                    DispatchQueue.main.async {
                        self.upload?.completedBytes = completed
                        self.upload?.totalBytes = total
                        self.upload?.status = "Datei wird aufgeteilt und geprüft …"
                    }
                }

                DispatchQueue.main.async {
                    self.upload?.completedBytes = 0
                    self.upload?.partCount = prepared.chunks.count
                    self.upload?.status = "Wird zu Telegram hochgeladen …"
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.sendPreparedChunks(
                        prepared,
                        position: 0,
                        fileID: fileID,
                        originalName: url.lastPathComponent,
                        folderID: folderID,
                        tagIDs: tagIDs,
                        sourceKey: sourceKey,
                        mimeType: mimeType,
                        createdAt: createdAt,
                        collected: [],
                        chatID: chatID
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.upload = nil
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func sendNativeMedia(
        url: URL,
        chatID: Int64,
        fileID: UUID,
        folderID: UUID?,
        tagIDs: [UUID],
        sourceKey: String?,
        descriptor: NativeMediaUploadDescriptor,
        photoBackup: PhotoBackupQueueMetadata?,
        createdAt: Date,
        mimeType: String?
    ) {
        upload?.status = descriptor.kind == "video" ? "Video wird gesendet …" : "Foto wird gesendet …"
        UIApplication.shared.isIdleTimerDisabled = true
        let manifest = TGManifest(
            format: 3,
            kind: descriptor.kind == "video" ? "nativeVideo" : "nativePhoto",
            fileID: fileID,
            folderID: folderID,
            parentFolderID: nil,
            name: photoBackup?.fileName ?? url.lastPathComponent,
            originalSize: url.fileByteSize,
            chunkIndex: 1,
            chunkCount: 1,
            createdAt: createdAt,
            tagIDs: tagIDs,
            sha256: nil,
            sourceKey: sourceKey,
            mediaKind: photoBackup?.mediaKind,
            assetLocalIdentifier: nil,
            resourceTypeRawValue: nil,
            mediaCreationDate: photoBackup?.creationDate
        )
        let operation = DurableOutbox.token(fileID: fileID, part: 1, kind: descriptor.kind)
        let readableCaption = "\(operation)\n\(markerText(for: manifest))"
        let caption: [String: Any] = ["@type": "formattedText", "text": readableCaption, "entities": []]
        let generatedVideoThumbnail = descriptor.kind == "video"
            ? TelegramVideoThumbnailGenerator.generate(for: url)
            : nil
        let videoThumbnail: Any
        if let generatedVideoThumbnail {
            videoThumbnail = generatedVideoThumbnail.input
        } else {
            videoThumbnail = NSNull()
        }
        let content: [String: Any]
        if descriptor.kind == "video" {
            content = [
                "@type": "inputMessageVideo",
                "video": ["@type": "inputFileLocal", "path": url.path],
                "thumbnail": videoThumbnail, "cover": NSNull(), "start_timestamp": 0,
                "added_sticker_file_ids": [], "duration": descriptor.duration,
                "width": descriptor.width, "height": descriptor.height,
                "supports_streaming": true, "caption": caption,
                "show_caption_above_media": false, "self_destruct_type": NSNull(), "has_spoiler": false
            ]
        } else {
            content = [
                "@type": "inputMessagePhoto",
                "photo": ["@type": "inputFileLocal", "path": url.path],
                "thumbnail": NSNull(), "added_sticker_file_ids": [],
                "width": descriptor.width, "height": descriptor.height,
                "caption": caption, "show_caption_above_media": false,
                "self_destruct_type": NSNull(), "has_spoiler": false
            ]
        }
        let request: [String: Any] = [
            "@type": "sendMessage", "chat_id": chatID, "topic_id": NSNull(),
            "reply_to": NSNull(), "options": NSNull(), "reply_markup": NSNull(),
            "input_message_content": content
        ]
        telegram.sendDurably(request, operation: operation) { [weak self] response in
            if let thumbnailURL = generatedVideoThumbnail?.url {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                    try? FileManager.default.removeItem(at: thumbnailURL)
                }
            }
            guard let self else { return }
            if response["@type"] as? String == "error" {
                let reason = response["message"] as? String ?? ""
                let rejectedMedia = ["PHOTO_INVALID", "PHOTO_EXT_INVALID", "IMAGE_PROCESS_FAILED", "VIDEO_CONTENT_TYPE_INVALID", "MEDIA_EMPTY", "PHOTO_INVALID_DIMENSIONS", "MEDIA_CAPTION_TOO_LONG"]
                    .contains { reason.hasPrefix($0) }
                if !rejectedMedia || TelegramClient.int(response["code"]) != 400 {
                    self.failUpload(self.friendlyTelegramError(response), chatID: chatID)
                    return
                }
                // Unsupported codecs and Telegram-side media validation fall back to the
                // durable chunked document format without losing the queue item.
                do { try self.telegram.switchToDocumentLayout(fileID: fileID, chatID: chatID, total: url.fileByteSize) }
                catch { self.failUpload(error.localizedDescription); return }
                self.upload?.status = "Medienformat nicht unterstützt • wird als Datei gesichert …"
                self.prepareDocumentUpload(
                    url: url, chatID: chatID, fileID: fileID, folderID: folderID,
                    tagIDs: tagIDs, sourceKey: sourceKey, createdAt: createdAt, mimeType: mimeType
                )
                return
            }
            guard let messageID = TelegramClient.int64(response["id"]) else {
                self.upload = nil
                self.lastError = "Telegram hat das Medium bestätigt, aber keine endgültige Nachrichten-ID zurückgegeben."
                UIApplication.shared.isIdleTimerDisabled = false
                return
            }
            let info = self.mediaFileInfo(fromMessage: response)
            let entry = CloudFileEntry(
                id: fileID, name: photoBackup?.fileName ?? url.lastPathComponent,
                folderID: folderID, totalSize: info.size > 0 ? info.size : url.fileByteSize,
                createdAt: photoBackup?.creationDate ?? createdAt, modifiedAt: Date(),
                chunks: [CloudChunk(index: 1, count: 1, telegramMessageID: messageID,
                    telegramFileID: info.fileID, remoteUniqueID: info.uniqueID,
                    size: info.size > 0 ? info.size : url.fileByteSize,
                    storedName: url.lastPathComponent)],
                mimeType: mimeType, tagIDs: tagIDs, sha256: nil, sourceKey: sourceKey,
                telegramChatID: chatID,
                storageKind: descriptor.kind == "video" ? "nativeVideo" : "nativePhoto"
            )
            self.index.files.removeAll { $0.id == fileID }
            self.index.files.append(entry)
            self.persist()
            self.upload?.completedBytes = self.upload?.totalBytes ?? url.fileByteSize
            self.upload = nil
            UIApplication.shared.isIdleTimerDisabled = false
            self.catalogMutation += 1
            self.scheduleCatalogSync(delay: 2)
        }
    }

    private func sendPreparedChunks(
        _ prepared: PreparedFile,
        position: Int,
        fileID: UUID,
        originalName: String,
        folderID: UUID?,
        tagIDs: [UUID],
        sourceKey: String?,
        mimeType: String?,
        createdAt: Date,
        collected: [CloudChunk],
        chatID: Int64
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
                sha256: prepared.sha256,
                sourceKey: sourceKey,
                telegramChatID: chatID,
                storageKind: "documentChunks"
            )
            index.files.removeAll { $0.id == fileID }
            index.files.append(entry)
            index.recovery?.partialFiles.removeAll { $0.id == fileID }
            persist()
            cleanupPreparedFileAfterTelegramRelease(prepared)
            upload = nil
            UIApplication.shared.isIdleTimerDisabled = false
            // Batch a continuous photo run into occasional remote checkpoints. The
            // local index remains durable immediately, while Telegram API traffic
            // stays low and never competes with the next file upload.
            catalogMutation += 1
            scheduleCatalogSync(delay: 2)
            return
        }

        let chunk = prepared.chunks[position]
        upload?.currentPart = chunk.index
        upload?.status = chunk.count == 1 ? "Datei wird hochgeladen …" : "Teil \(chunk.index) von \(chunk.count) wird hochgeladen …"

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
            sha256: chunk.sha256,
            sourceKey: sourceKey
        )

        if let recovered = index.recovery?.partialFiles.first(where: { $0.id == fileID && $0.telegramChatID == chatID })?
            .chunks.first(where: { $0.index == chunk.index && $0.count == chunk.count && $0.sha256 == chunk.sha256 }),
           let messageID = recovered.telegramMessageID {
            telegram.send(["@type": "getMessage", "chat_id": chatID, "message_id": messageID]) { [weak self] response in
                guard let self else { return }
                guard DurableOutbox.isFinal(response) else {
                    self.failUpload("Ein bereits gesicherter Dateiteil ist momentan nicht erreichbar. Es wird keine zweite Kopie gesendet.", prepared: prepared)
                    return
                }
                var next = collected
                next.append(recovered)
                self.sendPreparedChunks(prepared, position: position + 1, fileID: fileID, originalName: originalName,
                    folderID: folderID, tagIDs: tagIDs, sourceKey: sourceKey, mimeType: mimeType, createdAt: createdAt,
                    collected: next, chatID: chatID)
            }
            return
        }

        let operation = DurableOutbox.token(fileID: fileID, part: chunk.index, kind: "document")

        let content: [String: Any] = [
            "@type": "inputMessageDocument",
            "document": ["@type": "inputFileLocal", "path": chunk.url.path],
            "thumbnail": NSNull(),
            "disable_content_type_detection": true,
            "caption": ["@type": "formattedText", "text": "\(operation)\n\(markerText(for: manifest))", "entities": []]
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

        telegram.sendDurably(request, operation: operation) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.failUpload(self.friendlyTelegramError(response), prepared: prepared, uploadedChunks: collected, chatID: chatID)
                return
            }

            guard let messageID = TelegramClient.int64(response["id"]) else {
                self.failUpload("Telegram hat den Upload bestätigt, aber keine endgültige Nachrichten-ID zurückgegeben.", prepared: prepared, uploadedChunks: collected, chatID: chatID)
                return
            }

            guard let returned = self.decodeManifest(from: DurableOutbox.caption(response)),
                  returned.fileID == fileID, returned.chunkIndex == chunk.index,
                  returned.chunkCount == chunk.count, returned.sha256 == chunk.sha256 else {
                self.failUpload("Der vorhandene Telegram-Dateiteil gehört zu einem anderen Upload-Plan. Es wird keine weitere Kopie gesendet.", prepared: prepared)
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
                sourceKey: sourceKey,
                mimeType: mimeType,
                createdAt: createdAt,
                collected: next,
                chatID: chatID
            )
        }
    }

    private func failUpload(
        _ message: String,
        prepared: PreparedFile? = nil,
        uploadedChunks: [CloudChunk] = [],
        chatID: Int64? = nil
    ) {
        if let prepared { FileChunker.cleanup(prepared) }
        lastUploadFailure = message
        lastError = message
        upload = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Catalog v2

    func syncCatalogNow() {
        forceNextCatalog = true
        beginCatalogSync(force: true)
    }

    private func beginCatalogSync(force: Bool) {
        guard let chatID = telegram.savedMessagesChatID, recoveryReady, !isRefreshing else { return }
        guard upload == nil else {
            catalogNeedsAnotherSync = true
            scheduleCatalogSync(delay: 8)
            return
        }
        if isCatalogSyncing {
            catalogNeedsAnotherSync = true
            return
        }
        if !force && !forceNextCatalog {
            let elapsed = Date().timeIntervalSince(lastCatalogSyncAt)
            if elapsed < catalogMinimumInterval {
                scheduleCatalogSync(delay: max(2, catalogMinimumInterval - elapsed))
                return
            }
        }

        catalogWorkItem?.cancel()
        catalogWorkItem = nil
        forceNextCatalog = false
        syncingMutation = catalogMutation
        isCatalogSyncing = true
        catalogNeedsAnotherSync = false
        catalogStatus = "Katalog wird gesichert …"
        let revision = max(index.revision + 1, Int64(Date().timeIntervalSince1970))
        let snapshot = CatalogSnapshot(
            revision: revision,
            createdAt: Date(),
            folders: index.folders,
            files: index.files,
            tags: index.tags,
            recovery: index.recovery
        )

        let marker = snapshotMarker
        let backupURL = catalogBackupFolderURL?.appendingPathComponent("TGSpeicher-Catalog-latest.json")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicher-Catalog-v3-r\(revision)-\(UUID().uuidString).tgscatalog")

        // Encoding a catalog with many thousands of entries must never block SwiftUI.
        ioQueue.async { [weak self] in
            do {
                let data = try CatalogCodec.encode(snapshot)
                if let backupURL {
                    try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: backupURL, options: [.atomic])
                }
                try data.write(to: url, options: [.atomic])

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastCatalogBytes = data.count
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
                            self.finishCatalogFailure(["@type": "error", "message": "Die Katalogsicherung hat keine endgültige Nachrichten-ID."])
                            return
                        }
                        self.updateCatalogPointer(chatID: chatID, revision: revision, snapshotMessageID: snapshotID)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isCatalogSyncing = false
                    self.catalogStatus = "Katalogfehler"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func scheduleCatalogSync(delay: TimeInterval = 1.5) {
        guard recoveryReady else { return }
        if catalogWorkItem != nil { return }
        catalogStatus = "Katalogsicherung ausstehend"
        if isCatalogSyncing {
            catalogNeedsAnotherSync = true
            return
        }
        let item = DispatchWorkItem { [weak self] in
            self?.catalogWorkItem = nil
            self?.beginCatalogSync(force: false)
        }
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
                self.finishCatalogFailure(["@type": "error", "message": "Der Katalogverweis hat keine endgültige Nachrichten-ID."])
                return
            }
            self.finishCatalogSuccess(pointerID: pointerID, snapshotID: snapshotMessageID, revision: revision)
        }
    }

    private func finishCatalogSuccess(pointerID: Int64, snapshotID: Int64, revision: Int64) {
        lastSuccessfulMutation = syncingMutation
        nextCheckpointAttempt = Date().addingTimeInterval(45)
        index.version = 3
        index.revision = revision
        index.catalogPointerMessageID = pointerID
        index.catalogSnapshotMessageID = snapshotID
        index.lastSyncedAt = Date()
        lastCatalogSyncAt = index.lastSyncedAt ?? Date()
        persist()
        refreshRecoveryAnchor()
        isCatalogSyncing = false
        catalogStatus = "Katalog gesichert • Version \(revision)"

        if catalogNeedsAnotherSync || catalogMutation != syncingMutation {
            catalogNeedsAnotherSync = false
            scheduleCatalogSync(delay: catalogMinimumInterval)
        }
    }

    private func finishCatalogFailure(_ response: [String: Any]) {
        isCatalogSyncing = false
        let rawMessage = response["message"] as? String ?? ""
        if rawMessage.localizedCaseInsensitiveContains("real file path") {
            catalogStatus = "Katalogsicherung wird erneut versucht"
            catalogNeedsAnotherSync = true
            scheduleCatalogSync(delay: 8)
            return
        }
        if let wait = TelegramClient.retryAfterSeconds(response) {
            catalogStatus = "Telegram-Pause • erneuter Versuch in \(wait) s"
            catalogNeedsAnotherSync = true
            scheduleCatalogSync(delay: TimeInterval(wait + 1))
        } else {
            catalogStatus = "Katalogsicherung fehlgeschlagen – erneuter Versuch folgt"
            lastError = friendlyTelegramError(response)
            scheduleCatalogSync(delay: 60)
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

    // MARK: - Download / deletion

    func downloadAndReassemble(_ file: CloudFileEntry) {
        guard !isDownloading else { return }
        guard !file.chunks.isEmpty else {
            lastError = "Für diese Datei sind keine Telegram-Dateiteile gespeichert."
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
        guard let chatID = file.telegramChatID ?? telegram.savedMessagesChatID else { isDownloading = false; return }
        var chunk = ordered[position]

        guard let messageID = chunk.telegramMessageID else {
            if chunk.telegramFileID != nil {
                var next = resolved; next.append(chunk)
                resolveFreshChunkFiles(file: file, position: position + 1, resolved: next)
            } else {
                isDownloading = false
                lastError = "Dateiteil \(chunk.index) hat keine Telegram-Nachrichten-ID. Bitte den Katalog wiederherstellen."
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
            let info = self.mediaFileInfo(fromMessage: message)
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
            lastError = "Für Teil \(chunks[position].index) fehlt die Telegram-Dateikennung."
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
                self.lastError = "Telegram hat keinen vollständig geladenen Dateiteil bereitgestellt."
                return
            }
            var next = localURLs; next.append(URL(fileURLWithPath: path))
            self.downloadResolvedChunks(chunks, position: position + 1, localURLs: next, file: file)
        }
    }

    private func assembleDownloadedChunks(_ chunks: [URL], file: CloudFileEntry) {
        guard let downloads = downloadsFolderURL else {
            isDownloading = false
            lastError = "Der Download-Ordner konnte nicht geöffnet werden."
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
                        throw NSError(domain: "TGSpeicher", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Die SHA-256-Prüfung ist fehlgeschlagen. Die unvollständige Download-Datei wurde entfernt."])
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

    func deleteFileFromTelegram(_ file: CloudFileEntry) { deleteFilesFromTelegram([file]) }

    func deleteFilesFromTelegram(_ files: [CloudFileEntry]) {
        guard recoveryReady, !isRefreshing, let account = telegram.savedMessagesChatID else {
            deletionError = "Bitte zuerst die Wiederherstellung abschließen."; return
        }
        let liveIDs = Set(index.files.map(\.id))
        deletionQueue.resume(account: account, adding: files.filter { liveIDs.contains($0.id) })
    }

    func retryDeletions() {
        guard recoveryReady, !isRefreshing, let account = telegram.savedMessagesChatID else { return }
        deletionQueue.resume(account: account)
    }

    private func commitDeletedFile(_ file: CloudFileEntry, account: Int64) -> Bool {
        guard telegram.savedMessagesChatID == account, index.recovery?.accountID == account else { return false }
        let previous = index
        index.recovery?.deletedFiles[file.id] = Date()
        if let source = file.sourceKey {
            var excluded = index.recovery?.excludedPhotoResources ?? [:]
            excluded[CatalogCodec.resourceIdentity(sourceKey: source, accountID: account, destination: file.telegramChatID ?? account)] = Date()
            index.recovery?.excludedPhotoResources = excluded
        }
        index.files.removeAll { $0.id == file.id }
        index.recovery?.partialFiles.removeAll { $0.id == file.id }
        guard persist() else { index = previous; return false }
        catalogMutation += 1; forceNextCatalog = true
        scheduleCatalogSync(delay: 1)
        return true
    }

    func isPhotoExcluded(_ source: String, chatID: Int64?) -> Bool {
        guard let account = telegram.savedMessagesChatID else { return false }
        let key = CatalogCodec.resourceIdentity(sourceKey: source, accountID: account, destination: chatID ?? account)
        return index.recovery?.excludedPhotoResources?[key] != nil
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
        let baseName = (preferredName as NSString).lastPathComponent
        let preferredName = baseName.isEmpty || baseName == "." || baseName == ".." ? "Datei" : baseName
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

    func writeLocalCatalogBackup(_ data: Data) {
        guard let folder = catalogBackupFolderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("TGSpeicher-Catalog-latest.json"), options: [.atomic])
    }

    // MARK: - Helpers

    private func persistAndScheduleCatalog() {
        catalogMutation += 1
        forceNextCatalog = true
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

    func decodeManifest(from text: String) -> TGManifest? {
        let marker: String
        if text.contains(TGManifest.markerV2) { marker = TGManifest.markerV2 }
        else if text.contains(TGManifest.marker) { marker = TGManifest.marker }
        else { return nil }
        guard let range = text.range(of: marker) else { return nil }
        let payload = String(text[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first ?? "")
        guard let data = Data(base64Encoded: payload) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TGManifest.self, from: data)
    }

    private func messageText(_ message: [String: Any]) -> String? {
        guard let content = message["content"] as? [String: Any], content["@type"] as? String == "messageText",
              let text = content["text"] as? [String: Any] else { return nil }
        return text["text"] as? String
    }

    func documentFileInfo(fromMessage message: [String: Any]) -> (fileID: Int?, uniqueID: String?, size: Int64) {
        guard let content = message["content"] as? [String: Any],
              let document = content["document"] as? [String: Any],
              let file = document["document"] as? [String: Any] else { return (nil, nil, 0) }
        let fileID = TelegramClient.int(file["id"])
        let size = TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
        let uniqueID = (file["remote"] as? [String: Any])?["unique_id"] as? String
        return (fileID, uniqueID, size)
    }

    func mediaFileInfo(fromMessage message: [String: Any]) -> (fileID: Int?, uniqueID: String?, size: Int64) {
        guard let content = message["content"] as? [String: Any] else { return (nil, nil, 0) }
        let file: [String: Any]?
        switch content["@type"] as? String {
        case "messageVideo":
            file = ((content["video"] as? [String: Any])?["video"] as? [String: Any])
        case "messagePhoto":
            let sizes = ((content["photo"] as? [String: Any])?["sizes"] as? [[String: Any]]) ?? []
            file = sizes.compactMap { $0["photo"] as? [String: Any] }.max {
                (TelegramClient.int64($0["size"]) ?? 0) < (TelegramClient.int64($1["size"]) ?? 0)
            }
        default:
            return documentFileInfo(fromMessage: message)
        }
        guard let file else { return (nil, nil, 0) }
        return (
            TelegramClient.int(file["id"]),
            (file["remote"] as? [String: Any])?["unique_id"] as? String,
            TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
        )
    }

    func friendlyTelegramError(_ response: [String: Any]) -> String {
        if let wait = TelegramClient.retryAfterSeconds(response) {
            return "Telegram begrenzt die Anfragen. Bitte etwa \(wait) Sekunden warten."
        }
        return (response["message"] as? String ?? "Telegram hat einen Fehler gemeldet.")
            .replacingOccurrences(of: "_", with: " ")
    }

    var localIndexURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("TGSpeicher", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cloud-index.json")
    }

    private func loadLocalIndex() {
        guard let url = localIndexURL else { return }
        for candidate in [url, url.appendingPathExtension("previous")] {
            if let data = try? Data(contentsOf: candidate), let value = try? JSONDecoder().decode(CloudIndex.self, from: data) {
                var candidateIndex = value
                let partial = value.files.filter { !$0.isComplete }
                candidateIndex.files.removeAll { !$0.isComplete }
                if !partial.isEmpty {
                    if candidateIndex.recovery == nil { candidateIndex.recovery = RecoveryMetadata(accountID: 0) }
                    candidateIndex.recovery?.partialFiles.append(contentsOf: partial)
                }
                let snapshot = CatalogSnapshot(revision: value.revision, createdAt: Date(), folders: candidateIndex.folders,
                    files: candidateIndex.files, tags: candidateIndex.tags, recovery: candidateIndex.recovery)
                guard (try? CatalogCodec.validate(snapshot)) != nil else { continue }
                index = candidateIndex
                return
            }
        }
    }

    @discardableResult
    func persist() -> Bool {
        guard let url = localIndexURL else { recoveryReady = false; return false }
        do {
            let data = try JSONEncoder().encode(index)
            if FileManager.default.fileExists(atPath: url.path) {
                let previous = url.appendingPathExtension("previous")
                if let old = try? Data(contentsOf: url), (try? JSONDecoder().decode(CloudIndex.self, from: old)) != nil {
                    try old.write(to: previous, options: [.atomic])
                }
            }
            try data.write(to: url, options: [.atomic])
        } catch {
            recoveryReady = false
            lastError = "Der lokale Katalog konnte nicht gespeichert werden: \(error.localizedDescription)"
            return false
        }
        objectWillChange.send()
        return true
    }
}

