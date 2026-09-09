import Foundation
import CryptoKit
import Compression

struct RecoveryMetadata: Codable {
    var accountID: Int64
    var destinationChatID: Int64?
    var scannedThrough: [String: Int64] = [:]
    var deletedFiles: [UUID: Date] = [:]
    var deletedFolders: [UUID: Date] = [:]
    var deletedTags: [UUID: Date] = [:]
    var partialFiles: [CloudFileEntry] = []
}

struct RecoveryAnchor: Codable {
    var accountID: Int64
    var pointerID: Int64?
    var snapshotID: Int64?
    var destinationChatID: Int64?
    var updatedAt: Date
}

enum RecoveryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum CatalogCodec {
    static let maxBytes = 128 * 1024 * 1024
    private struct Archive: Codable {
        var format = "TGSpeicherCatalog"
        var version = 3
        var codec = "lzfse"
        var bytes: Int
        var sha256: String
        var payload: Data
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func stableMediaID(hash: String, chatID: Int64) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("TGSpeicher.media.v3|\(chatID)|\(hash)".utf8)))
        var b = Array(bytes.prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }

    static func encode(_ snapshot: CatalogSnapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let raw = try encoder.encode(snapshot)
        guard raw.count <= maxBytes else { throw RecoveryError.invalid("Der Katalog überschreitet 128 MB. Die vorhandenen Sicherungen bleiben erhalten.") }
        let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        return try encoder.encode(Archive(bytes: raw.count, sha256: digest(raw), payload: compressed))
    }

    static func decode(_ data: Data, accountID: Int64?) throws -> CatalogSnapshot {
        guard data.count <= maxBytes else { throw RecoveryError.invalid("Diese Katalogdatei ist zu groß.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: CatalogSnapshot
        if let header = try JSONSerialization.jsonObject(with: data) as? [String: Any], header["format"] != nil {
            let archive = try decoder.decode(Archive.self, from: data)
            guard archive.format == "TGSpeicherCatalog", archive.version == 3,
                  archive.codec == "lzfse", !archive.payload.isEmpty, archive.bytes > 0, archive.bytes <= maxBytes else {
                throw RecoveryError.invalid("Unbekanntes oder beschädigtes Katalogformat.")
            }
            var raw = Data(count: archive.bytes)
            let count = raw.withUnsafeMutableBytes { output in
                archive.payload.withUnsafeBytes { input in
                    compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, archive.bytes,
                                              input.bindMemory(to: UInt8.self).baseAddress!, archive.payload.count,
                                              nil, COMPRESSION_LZFSE)
                }
            }
            guard count == archive.bytes, digest(raw) == archive.sha256 else {
                throw RecoveryError.invalid("Die Prüfsumme stimmt nicht. Die Sicherung wurde nicht übernommen.")
            }
            snapshot = try decoder.decode(CatalogSnapshot.self, from: raw)
        } else if let legacy = try? decoder.decode(CatalogSnapshot.self, from: data) {
            snapshot = legacy
        } else {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["version"] != nil, object["files"] is [Any], object["folders"] is [Any] else {
                throw RecoveryError.invalid("Die Datei ist kein TGSpeicher-Katalog.")
            }
            let legacy = try JSONDecoder().decode(CloudIndex.self, from: data)
            snapshot = CatalogSnapshot(revision: legacy.revision, createdAt: legacy.lastSyncedAt ?? Date(),
                                       folders: legacy.folders, files: legacy.files, tags: legacy.tags, recovery: legacy.recovery)
        }
        if let owner = snapshot.recovery?.accountID, let accountID, owner != accountID {
            throw RecoveryError.invalid("Diese Sicherung gehört zu einem anderen Telegram-Konto.")
        }
        try validate(snapshot)
        return snapshot
    }

    static func validate(_ snapshot: CatalogSnapshot) throws {
        guard snapshot.schema == 2,
              Set(snapshot.files.map(\.id)).count == snapshot.files.count,
              Set(snapshot.folders.map(\.id)).count == snapshot.folders.count,
              Set(snapshot.tags.map(\.id)).count == snapshot.tags.count else {
            throw RecoveryError.invalid("Der Katalog enthält doppelte Kennungen oder eine unbekannte Version.")
        }
        let folders = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        for folder in snapshot.folders {
            var seen = Set<UUID>()
            var current: UUID? = folder.id
            while let id = current {
                guard seen.insert(id).inserted else { throw RecoveryError.invalid("Die Ordnerstruktur enthält einen Kreis.") }
                current = folders[id]?.parentID
            }
        }
        guard snapshot.files.allSatisfy({ $0.isComplete && $0.totalSize >= 0 }) else {
            throw RecoveryError.invalid("Der Katalog enthält unvollständige Dateien. Bitte eine andere Sicherung wählen oder Telegram erneut durchsuchen.")
        }
    }

    static func merge(_ snapshot: CatalogSnapshot, into local: CloudIndex, accountID: Int64) -> CloudIndex {
        var result = local
        var metadata = local.recovery ?? RecoveryMetadata(accountID: accountID)
        if let remote = snapshot.recovery {
            metadata.destinationChatID = metadata.destinationChatID ?? remote.destinationChatID
            metadata.deletedFiles.merge(remote.deletedFiles) { max($0, $1) }
            metadata.deletedFolders.merge(remote.deletedFolders) { max($0, $1) }
            metadata.deletedTags.merge(remote.deletedTags) { max($0, $1) }
            // A cursor is valid only for the matching snapshot, so keep the earlier boundary.
            metadata.scannedThrough.merge(remote.scannedThrough) { min($0, $1) }
            for partial in remote.partialFiles where !metadata.partialFiles.contains(where: { $0.id == partial.id }) {
                metadata.partialFiles.append(partial)
            }
        }
        var files = Dictionary(local.files.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
        for file in snapshot.files {
            if let old = files[file.id], old.modifiedAt > file.modifiedAt { continue }
            files[file.id] = file
        }
        result.files = files.values.filter { metadata.deletedFiles[$0.id] == nil }.map { file in
            var fresh = file
            for i in fresh.chunks.indices { fresh.chunks[i].telegramFileID = nil }
            return fresh
        }
        var folders = Dictionary(local.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
        for folder in snapshot.folders {
            if let old = folders[folder.id], old.modifiedAt > folder.modifiedAt { continue }
            folders[folder.id] = folder
        }
        result.folders = folders.values.filter { metadata.deletedFolders[$0.id] == nil }
        var tags = Dictionary(local.tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for tag in snapshot.tags where tags[tag.id] == nil { tags[tag.id] = tag }
        result.tags = tags.values.filter { metadata.deletedTags[$0.id] == nil }
        // Repair the result of concurrent edits before publishing it to SwiftUI.
        let folderPositions = Dictionary(uniqueKeysWithValues: result.folders.enumerated().map { ($0.element.id, $0.offset) })
        for i in result.folders.indices {
            var seen: Set<UUID> = [result.folders[i].id]
            var parent = result.folders[i].parentID
            while let id = parent, let position = folderPositions[id] {
                if !seen.insert(id).inserted { result.folders[i].parentID = nil; break }
                parent = result.folders[position].parentID
            }
        }
        result.revision = max(local.revision, snapshot.revision)
        result.recovery = metadata
        repairReferences(&result)
        return result
    }

    static func repairReferences(_ index: inout CloudIndex) {
        var folderIDs = Set(index.folders.map(\.id))
        let required = Set(index.files.compactMap(\.folderID) + index.folders.compactMap(\.parentID))
        for id in required where !folderIDs.contains(id) {
            index.folders.append(CloudFolder(id: id, name: "Wiederhergestellter Ordner"))
            folderIDs.insert(id)
        }
        let tagIDs = Set(index.tags.map(\.id))
        for i in index.files.indices { index.files[i].tagIDs.removeAll { !tagIDs.contains($0) } }
    }
}

extension CloudFileEntry {
    var isComplete: Bool {
        guard let first = chunks.first, first.count > 0, first.count == chunks.count else { return false }
        return Set(chunks.map(\.index)) == Set(1...first.count)
            && chunks.allSatisfy { $0.count == first.count && ($0.telegramMessageID ?? 0) > 0 }
    }
}
