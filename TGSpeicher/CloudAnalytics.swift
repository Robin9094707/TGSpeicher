import Foundation
import Combine

struct TGCloudBreakdownItem: Identifiable, Hashable {
    let id: String
    let label: String
    let bytes: Int64
    let count: Int
}

extension CloudStore {
    var trackedTelegramPayloadBytes: Int64 {
        index.files.reduce(Int64(0)) { total, file in
            let chunkBytes = file.chunks.reduce(Int64(0)) { $0 + max(0, $1.size) }
            return total + (chunkBytes > 0 ? chunkBytes : max(0, file.totalSize))
        }
    }

    var averageTrackedFileBytes: Int64 {
        guard !index.files.isEmpty else { return 0 }
        return totalTrackedBytes / Int64(index.files.count)
    }

    var largestTrackedFile: CloudFileEntry? {
        index.files.max { $0.totalSize < $1.totalSize }
    }

    var photoFileCount: Int {
        index.files.filter { $0.isTGImage }.count
    }

    var videoFileCount: Int {
        index.files.filter { $0.isTGVideo }.count
    }

    var photoBytes: Int64 {
        index.files.filter { $0.isTGImage }.reduce(0) { $0 + $1.totalSize }
    }

    var videoBytes: Int64 {
        index.files.filter { $0.isTGVideo }.reduce(0) { $0 + $1.totalSize }
    }

    var otherBytes: Int64 {
        max(0, totalTrackedBytes - photoBytes - videoBytes)
    }

    func recursiveFolderIDs(startingAt folderID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [folderID]
        var frontier: [UUID] = [folderID]
        var safety = 0
        while let current = frontier.first, safety < 100_000 {
            frontier.removeFirst()
            for child in index.folders where child.parentID == current && !result.contains(child.id) {
                result.insert(child.id)
                frontier.append(child.id)
            }
            safety += 1
        }
        return result
    }

    func recursiveFolderBytes(_ folderID: UUID?) -> Int64 {
        guard let folderID else { return totalTrackedBytes }
        let ids = recursiveFolderIDs(startingAt: folderID)
        return index.files.filter { file in
            guard let id = file.folderID else { return false }
            return ids.contains(id)
        }.reduce(0) { $0 + $1.totalSize }
    }

    func recursiveFolderFileCount(_ folderID: UUID?) -> Int {
        guard let folderID else { return index.files.count }
        let ids = recursiveFolderIDs(startingAt: folderID)
        return index.files.filter { file in
            guard let id = file.folderID else { return false }
            return ids.contains(id)
        }.count
    }

    var topLevelFolderUsage: [TGCloudBreakdownItem] {
        index.folders
            .filter { $0.parentID == nil }
            .map { folder in
                TGCloudBreakdownItem(
                    id: folder.id.uuidString,
                    label: folder.name,
                    bytes: recursiveFolderBytes(folder.id),
                    count: recursiveFolderFileCount(folder.id)
                )
            }
            .sorted { $0.bytes > $1.bytes }
    }

    var fileTypeUsage: [TGCloudBreakdownItem] {
        var buckets: [String: (Int64, Int)] = [:]
        for file in index.files {
            let key: String
            if file.isTGImage { key = "Photos" }
            else if file.isTGVideo { key = "Videos" }
            else if file.mimeType?.hasPrefix("audio/") == true { key = "Audio" }
            else if ["zip", "rar", "7z", "tar", "gz"].contains(file.fileExtension.lowercased()) { key = "Archives" }
            else { key = "Other" }
            let old = buckets[key] ?? (0, 0)
            buckets[key] = (old.0 + file.totalSize, old.1 + 1)
        }
        return buckets.map { TGCloudBreakdownItem(id: $0.key, label: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.bytes > $1.bytes }
    }
}

extension CloudFileEntry {
    var fileExtension: String {
        (name as NSString).pathExtension
    }

    var isTGImage: Bool {
        if mimeType?.hasPrefix("image/") == true { return true }
        return ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "dng"].contains(fileExtension.lowercased())
    }

    var isTGVideo: Bool {
        if mimeType?.hasPrefix("video/") == true { return true }
        return ["mov", "mp4", "m4v", "hevc", "avi", "mkv", "webm"].contains(fileExtension.lowercased())
    }
}

@MainActor
final class TelegramUsageScanner: ObservableObject {
    @Published private(set) var verifiedBytes: Int64?
    @Published private(set) var verifiedMessages = 0
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var isScanning = false
    @Published private(set) var status = "Not verified yet"

    private let telegram: TelegramClient
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    private let markers = ["#TGSpeicherV2", "#TGSpeicherCatalogSnapshotV2", "#TGSpeicherPhotoBackupIndexV1"]

    init(telegram: TelegramClient) {
        self.telegram = telegram
        if defaults.object(forKey: "stats.verifiedBytes") != nil {
            verifiedBytes = Int64(defaults.integer(forKey: "stats.verifiedBytes"))
            verifiedMessages = defaults.integer(forKey: "stats.verifiedMessages")
            lastScanAt = defaults.object(forKey: "stats.lastScanAt") as? Date
            if let lastScanAt {
                status = "Last verified \(lastScanAt.formatted(date: .abbreviated, time: .shortened))"
            }
        }

        telegram.$savedMessagesChatID
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let stale = self.lastScanAt.map { Date().timeIntervalSince($0) > 21_600 } ?? true
                if stale {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.refresh() }
                }
            }
            .store(in: &cancellables)
    }

    func refresh() {
        guard !isScanning, telegram.savedMessagesChatID != nil else { return }
        isScanning = true
        status = "Scanning TGSpeicher messages…"
        scanMarker(at: 0, totalBytes: 0, totalMessages: 0, seen: Set<Int64>())
    }

    private func scanMarker(at markerIndex: Int, totalBytes: Int64, totalMessages: Int, seen: Set<Int64>) {
        guard markerIndex < markers.count else {
            verifiedBytes = totalBytes
            verifiedMessages = totalMessages
            lastScanAt = Date()
            isScanning = false
            status = "Verified from Telegram"
            defaults.set(Int(totalBytes), forKey: "stats.verifiedBytes")
            defaults.set(totalMessages, forKey: "stats.verifiedMessages")
            defaults.set(lastScanAt, forKey: "stats.lastScanAt")
            return
        }
        scanPage(
            query: markers[markerIndex],
            fromMessageID: 0,
            markerIndex: markerIndex,
            totalBytes: totalBytes,
            totalMessages: totalMessages,
            seen: seen,
            pageCount: 0
        )
    }

    private func scanPage(
        query: String,
        fromMessageID: Int64,
        markerIndex: Int,
        totalBytes: Int64,
        totalMessages: Int,
        seen: Set<Int64>,
        pageCount: Int
    ) {
        guard let chatID = telegram.savedMessagesChatID else {
            isScanning = false
            status = "Telegram disconnected"
            return
        }

        telegram.send([
            "@type": "searchChatMessages",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "query": query,
            "sender_id": NSNull(),
            "from_message_id": fromMessageID,
            "offset": 0,
            "limit": 100,
            "filter": NSNull()
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.isScanning = false
                if let wait = TelegramClient.retryAfterSeconds(response) {
                    self.status = "Telegram rate limit • retry in ~\(wait)s"
                } else {
                    self.status = response["message"] as? String ?? "Usage scan failed"
                }
                return
            }

            var bytes = totalBytes
            var messagesCount = totalMessages
            var known = seen
            let messages = response["messages"] as? [[String: Any]] ?? []
            for message in messages {
                guard let id = TelegramClient.int64(message["id"]), !known.contains(id) else { continue }
                known.insert(id)
                if let size = self.documentSize(from: message) {
                    bytes += size
                    messagesCount += 1
                }
            }

            let nextID = TelegramClient.int64(response["next_from_message_id"]) ?? 0
            self.status = "Scanning • \(messagesCount) Telegram objects"
            if nextID != 0, !messages.isEmpty, pageCount < 500 {
                self.scanPage(
                    query: query,
                    fromMessageID: nextID,
                    markerIndex: markerIndex,
                    totalBytes: bytes,
                    totalMessages: messagesCount,
                    seen: known,
                    pageCount: pageCount + 1
                )
            } else {
                self.scanMarker(at: markerIndex + 1, totalBytes: bytes, totalMessages: messagesCount, seen: known)
            }
        }
    }

    private func documentSize(from message: [String: Any]) -> Int64? {
        guard let content = message["content"] as? [String: Any],
              content["@type"] as? String == "messageDocument",
              let document = content["document"] as? [String: Any],
              let file = document["document"] as? [String: Any] else { return nil }
        let size = TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
        return max(0, size)
    }
}
