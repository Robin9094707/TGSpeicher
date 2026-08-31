import Foundation
import Combine
import UIKit

final class CloudStore: ObservableObject {
    @Published private(set) var index = CloudIndex()
    @Published private(set) var upload: UploadProgress?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDownloading = false
    @Published var lastExportURL: URL?
    @Published var lastError: String?

    let telegram: TelegramClient
    private let ioQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.io", qos: .userInitiated)

    init(telegram: TelegramClient) {
        self.telegram = telegram
        loadLocalIndex()
    }

    var totalTrackedBytes: Int64 {
        index.files.reduce(0) { $0 + $1.totalSize }
    }

    var totalChunks: Int {
        index.files.reduce(0) { $0 + $1.chunks.count }
    }

    func children(of folderID: UUID?) -> [CloudFolder] {
        index.folders
            .filter { $0.parentID == folderID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func files(in folderID: UUID?) -> [CloudFileEntry] {
        index.files
            .filter { $0.folderID == folderID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func createFolder(name: String, parentID: UUID?) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let folder = CloudFolder(name: clean, parentID: parentID)
        index.folders.append(folder)
        persist()

        sendMarkerMessage(
            TGManifest(
                format: 1,
                kind: "folder",
                fileID: nil,
                folderID: folder.id,
                parentFolderID: folder.parentID,
                name: folder.name,
                originalSize: nil,
                chunkIndex: nil,
                chunkCount: nil,
                createdAt: folder.createdAt
            )
        )
    }

    func uploadFile(_ url: URL, folderID: UUID?) {
        guard upload == nil else {
            lastError = "Another upload is already being prepared."
            return
        }
        guard telegram.savedMessagesChatID != nil else {
            lastError = "Saved Messages is not ready yet."
            return
        }

        let fileID = UUID()
        let total = url.fileByteSize
        upload = UploadProgress(
            id: fileID,
            fileName: url.lastPathComponent,
            completedBytes: 0,
            totalBytes: total,
            currentPart: 0,
            partCount: 1,
            status: "Preparing…"
        )

        let accessed = url.startAccessingSecurityScopedResource()
        ioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            do {
                // Keep every part below Telegram's standard 2 GB per-file ceiling.
                let maxChunkBytes: Int64 = 1_900_000_000
                let chunks = try FileChunker.prepare(
                    source: url,
                    maxChunkBytes: maxChunkBytes
                ) { completed, total in
                    DispatchQueue.main.async {
                        self.upload?.completedBytes = completed
                        self.upload?.totalBytes = total
                        self.upload?.status = "Splitting securely…"
                    }
                }

                DispatchQueue.main.async {
                    self.upload?.completedBytes = 0
                    self.upload?.partCount = chunks.count
                    self.upload?.status = "Uploading to Telegram…"
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.sendPreparedChunks(
                        chunks,
                        position: 0,
                        fileID: fileID,
                        originalName: url.lastPathComponent,
                        originalSize: total,
                        folderID: folderID,
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
    }

    func refreshFromTelegram() {
        guard let chatID = telegram.savedMessagesChatID else {
            lastError = "Saved Messages is not ready yet."
            return
        }
        guard !isRefreshing else { return }

        isRefreshing = true
        fetchMarkerPage(chatID: chatID, fromMessageID: 0, accumulated: [])
    }

    func downloadAndReassemble(_ file: CloudFileEntry) {
        guard !isDownloading else { return }
        let ordered = file.chunks.sorted { $0.index < $1.index }
        guard !ordered.isEmpty, ordered.allSatisfy({ $0.telegramFileID != nil }) else {
            lastError = "This file needs a Telegram index refresh before it can be downloaded."
            return
        }

        isDownloading = true
        downloadChunk(ordered, position: 0, localURLs: [], file: file)
    }

    func deleteLocalIndexEntry(_ file: CloudFileEntry) {
        index.files.removeAll { $0.id == file.id }
        persist()
    }

    private func sendPreparedChunks(
        _ chunks: [PreparedChunk],
        position: Int,
        fileID: UUID,
        originalName: String,
        originalSize: Int64,
        folderID: UUID?,
        collected: [CloudChunk]
    ) {
        guard position < chunks.count else {
            let entry = CloudFileEntry(
                id: fileID,
                name: originalName,
                folderID: folderID,
                totalSize: originalSize,
                chunks: collected.sorted { $0.index < $1.index }
            )
            index.files.removeAll { $0.id == fileID }
            index.files.append(entry)
            persist()
            upload = nil
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        guard let chatID = telegram.savedMessagesChatID else {
            failUpload("Saved Messages became unavailable.")
            return
        }

        let chunk = chunks[position]
        upload?.currentPart = chunk.index
        upload?.status = chunks.count == 1
            ? "Uploading file…"
            : "Uploading part \(chunk.index) of \(chunk.count)…"

        let manifest = TGManifest(
            format: 1,
            kind: "fileChunk",
            fileID: fileID,
            folderID: folderID,
            parentFolderID: nil,
            name: originalName,
            originalSize: originalSize,
            chunkIndex: chunk.index,
            chunkCount: chunk.count,
            createdAt: Date()
        )

        let content: [String: Any] = [
            "@type": "inputMessageDocument",
            "document": ["@type": "inputFileLocal", "path": chunk.url.path],
            "thumbnail": NSNull(),
            "disable_content_type_detection": true,
            "caption": [
                "@type": "formattedText",
                "text": markerText(for: manifest),
                "entities": []
            ]
        ]

        telegram.send([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "reply_to": NSNull(),
            "options": NSNull(),
            "reply_markup": NSNull(),
            "input_message_content": content
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.failUpload(response["message"] as? String ?? "Telegram rejected the upload.")
                return
            }

            let messageID = TelegramClient.int64(response["id"])
            var telegramFileID: Int?
            var remoteUniqueID: String?

            if let messageContent = response["content"] as? [String: Any],
               let document = messageContent["document"] as? [String: Any],
               let telegramFile = document["document"] as? [String: Any] {
                telegramFileID = TelegramClient.int(telegramFile["id"])
                if let remote = telegramFile["remote"] as? [String: Any] {
                    remoteUniqueID = remote["unique_id"] as? String
                }
            }

            var nextCollected = collected
            nextCollected.append(
                CloudChunk(
                    index: chunk.index,
                    count: chunk.count,
                    telegramMessageID: messageID,
                    telegramFileID: telegramFileID,
                    remoteUniqueID: remoteUniqueID,
                    size: chunk.size,
                    storedName: chunk.url.lastPathComponent
                )
            )

            self.upload?.completedBytes = min(
                originalSize,
                nextCollected.reduce(Int64(0)) { $0 + $1.size }
            )

            self.sendPreparedChunks(
                chunks,
                position: position + 1,
                fileID: fileID,
                originalName: originalName,
                originalSize: originalSize,
                folderID: folderID,
                collected: nextCollected
            )
        }
    }

    private func failUpload(_ message: String) {
        upload = nil
        UIApplication.shared.isIdleTimerDisabled = false
        lastError = message.replacingOccurrences(of: "_", with: " ")
    }

    private func sendMarkerMessage(_ manifest: TGManifest) {
        guard let chatID = telegram.savedMessagesChatID else { return }
        let content: [String: Any] = [
            "@type": "inputMessageText",
            "text": [
                "@type": "formattedText",
                "text": markerText(for: manifest),
                "entities": []
            ],
            "link_preview_options": NSNull(),
            "clear_draft": false
        ]

        telegram.send([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "reply_to": NSNull(),
            "options": NSNull(),
            "reply_markup": NSNull(),
            "input_message_content": content
        ]) { [weak self] response in
            self?.surfaceTelegramError(response)
        }
    }

    private func markerText(for manifest: TGManifest) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else {
            return TGManifest.marker
        }
        return "\(TGManifest.marker) \(data.base64EncodedString())"
    }

    private func decodeManifest(from text: String) -> TGManifest? {
        guard let range = text.range(of: TGManifest.marker) else { return nil }
        let payload = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: payload) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TGManifest.self, from: data)
    }

    private func fetchMarkerPage(
        chatID: Int64,
        fromMessageID: Int64,
        accumulated: [[String: Any]]
    ) {
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
                self.surfaceTelegramError(response)
                return
            }

            var nextAccumulated = accumulated
            if let page = response["messages"] as? [[String: Any]] {
                nextAccumulated.append(contentsOf: page)
            }

            let nextMessageID = TelegramClient.int64(response["next_from_message_id"]) ?? 0
            if nextMessageID != 0, nextAccumulated.count < 20_000 {
                self.fetchMarkerPage(
                    chatID: chatID,
                    fromMessageID: nextMessageID,
                    accumulated: nextAccumulated
                )
            } else {
                self.rebuildIndex(from: nextAccumulated)
                self.isRefreshing = false
            }
        }
    }

    private func rebuildIndex(from messages: [[String: Any]]) {
        var foldersByID: [UUID: CloudFolder] = [:]

        struct TempFile {
            var name: String
            var folderID: UUID?
            var totalSize: Int64
            var createdAt: Date
            var chunks: [CloudChunk]
            var mimeType: String?
        }

        var filesByID: [UUID: TempFile] = [:]

        for message in messages {
            guard let content = message["content"] as? [String: Any] else { continue }

            var marker: String?
            if content["@type"] as? String == "messageText",
               let text = content["text"] as? [String: Any] {
                marker = text["text"] as? String
            } else if content["@type"] as? String == "messageDocument",
                      let caption = content["caption"] as? [String: Any] {
                marker = caption["text"] as? String
            }

            guard let marker, let manifest = decodeManifest(from: marker) else { continue }

            if manifest.kind == "folder", let folderID = manifest.folderID {
                foldersByID[folderID] = CloudFolder(
                    id: folderID,
                    name: manifest.name,
                    parentID: manifest.parentFolderID,
                    createdAt: manifest.createdAt
                )
                continue
            }

            guard manifest.kind == "fileChunk", let fileID = manifest.fileID else { continue }

            let messageID = TelegramClient.int64(message["id"])
            var telegramFileID: Int?
            var uniqueID: String?
            var size: Int64 = 0
            var storedName = manifest.name
            var mimeType: String?

            if let document = content["document"] as? [String: Any] {
                storedName = document["file_name"] as? String ?? storedName
                mimeType = document["mime_type"] as? String
                if let telegramFile = document["document"] as? [String: Any] {
                    telegramFileID = TelegramClient.int(telegramFile["id"])
                    size = TelegramClient.int64(telegramFile["size"])
                        ?? TelegramClient.int64(telegramFile["expected_size"])
                        ?? 0
                    if let remote = telegramFile["remote"] as? [String: Any] {
                        uniqueID = remote["unique_id"] as? String
                    }
                }
            }

            let part = manifest.chunkIndex ?? 1
            let count = manifest.chunkCount ?? 1
            let cloudChunk = CloudChunk(
                index: part,
                count: count,
                telegramMessageID: messageID,
                telegramFileID: telegramFileID,
                remoteUniqueID: uniqueID,
                size: size,
                storedName: storedName
            )

            var temp = filesByID[fileID] ?? TempFile(
                name: manifest.name,
                folderID: manifest.folderID,
                totalSize: manifest.originalSize ?? 0,
                createdAt: manifest.createdAt,
                chunks: [],
                mimeType: mimeType
            )
            temp.chunks.removeAll { $0.index == part }
            temp.chunks.append(cloudChunk)
            if temp.mimeType == nil { temp.mimeType = mimeType }
            filesByID[fileID] = temp
        }

        index.folders = Array(foldersByID.values)
        index.files = filesByID.map { id, temp in
            CloudFileEntry(
                id: id,
                name: temp.name,
                folderID: temp.folderID,
                totalSize: temp.totalSize > 0
                    ? temp.totalSize
                    : temp.chunks.reduce(Int64(0)) { $0 + $1.size },
                createdAt: temp.createdAt,
                chunks: temp.chunks.sorted { $0.index < $1.index },
                mimeType: temp.mimeType
            )
        }
        persist()
    }

    private func downloadChunk(
        _ chunks: [CloudChunk],
        position: Int,
        localURLs: [URL],
        file: CloudFileEntry
    ) {
        guard position < chunks.count else {
            assembleDownloadedChunks(localURLs, file: file)
            return
        }
        guard let fileID = chunks[position].telegramFileID else {
            isDownloading = false
            lastError = "A Telegram file identifier is missing. Refresh the cloud index and try again."
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
                self.surfaceTelegramError(response)
                return
            }

            guard let local = response["local"] as? [String: Any],
                  local["is_downloading_completed"] as? Bool == true,
                  let path = local["path"] as? String,
                  !path.isEmpty else {
                self.isDownloading = false
                self.lastError = "Telegram did not provide a completed local file."
                return
            }

            var nextURLs = localURLs
            nextURLs.append(URL(fileURLWithPath: path))
            self.downloadChunk(
                chunks,
                position: position + 1,
                localURLs: nextURLs,
                file: file
            )
        }
    }

    private func assembleDownloadedChunks(_ chunks: [URL], file: CloudFileEntry) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicherExports", isDirectory: true)
            .appendingPathComponent(file.name)

        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileChunker.join(chunks: chunks, destination: destination) { _ in }
                DispatchQueue.main.async {
                    self.lastExportURL = destination
                    self.isDownloading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func surfaceTelegramError(_ response: [String: Any]) {
        guard response["@type"] as? String == "error" else { return }
        lastError = (response["message"] as? String ?? "Telegram returned an error.")
            .replacingOccurrences(of: "_", with: " ")
    }

    private var localIndexURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let folder = support.appendingPathComponent("TGSpeicher", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cloud-index.json")
    }

    private func loadLocalIndex() {
        guard let url = localIndexURL,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(CloudIndex.self, from: data) else {
            return
        }
        index = value
    }

    private func persist() {
        guard let url = localIndexURL,
              let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: [.atomic])
        objectWillChange.send()
    }
}
