import Foundation

/// Use the server's part limits when available; never infer Premium from a name or badge.
struct UploadPolicy {
    static let standardBytes: Int64 = 2_000_000_000
    static let premiumBytes: Int64 = 4_000_000_000
    static let legacyChunkBytes: Int64 = 1_900_000_000
    var isPremium: Bool? = nil
    var standardParts: Int64? = nil
    var premiumParts: Int64? = nil

    mutating func applyConfiguration(_ response: [String: Any]) {
        guard response["@type"] as? String == "jsonValueObject",
              let entries = response["value"] as? [[String: Any]] else { return }
        for entry in entries {
            guard let key = entry["key"] as? String,
                  let value = entry["value"] as? [String: Any],
                  value["@type"] as? String == "jsonValueNumber",
                  let number = value["value"] as? Double, number.isFinite,
                  number >= 1, number <= 1_000_000, number.rounded(.down) == number else { continue }
            if key == "upload_max_fileparts_default" { standardParts = Int64(number) }
            if key == "upload_max_fileparts_premium" { premiumParts = Int64(number) }
        }
    }

    func bytes(usePremium: Bool = true) -> Int64 {
        let premium = isPremium == true && usePremium
        let fallback = premium ? Self.premiumBytes : Self.standardBytes
        return min(fallback, (premium ? premiumParts : standardParts).map { $0 * 524_288 } ?? fallback)
    }
}

struct UploadLayout: Codable, Equatable {
    var totalBytes: Int64
    var chunkBytes: Int64
    var nativeKind: String?
}

extension DurableOutbox {
    /// Pin the layout before the first send. Changing Premium must not reinterpret part 1.
    func uploadLayout(fileID: UUID, chatID: Int64, total: Int64, limit: Int64,
                      nativeKind: String?, partial: CloudFileEntry?) throws -> UploadLayout {
        let path = layoutURL(fileID: fileID, chatID: chatID)
        if FileManager.default.fileExists(atPath: path.path) {
            let layout = try JSONDecoder().decode(UploadLayout.self, from: Data(contentsOf: path))
            guard layout.totalBytes == total, layout.chunkBytes > 0,
                  layout.chunkBytes <= UploadPolicy.premiumBytes else {
                throw RecoveryError.invalid("Die Datei passt nicht mehr zu ihrem gespeicherten Upload-Plan.")
            }
            return layout
        }
        var layout = UploadLayout(totalBytes: total, chunkBytes: limit, nativeKind: nativeKind)
        if let partial, partial.chunks.contains(where: { $0.count > 1 }) {
            guard partial.totalSize == total,
                  let size = partial.chunks.first(where: { $0.index < $0.count })?.size,
                  size > 0, size <= UploadPolicy.premiumBytes else {
                throw RecoveryError.invalid("Die Teilgrenzen der begonnenen Datei sind nicht eindeutig. Bitte den Katalog vollständig abgleichen.")
            }
            layout.chunkBytes = size
            layout.nativeKind = nil
        } else if try load(Self.token(fileID: fileID, part: 1, kind: "document")) != nil {
            layout.chunkBytes = UploadPolicy.legacyChunkBytes
            layout.nativeKind = nil
        } else {
            for kind in ["photo", "video"] {
                if try load(Self.token(fileID: fileID, part: 1, kind: kind)) != nil {
                    layout.nativeKind = kind
                    break
                }
            }
        }
        try saveLayout(layout, fileID: fileID, chatID: chatID)
        return layout
    }

    func useDocumentLayout(fileID: UUID, chatID: Int64, total: Int64, limit: Int64) throws {
        // Called only after an explicit media-format rejection, before any document send.
        try saveLayout(UploadLayout(totalBytes: total, chunkBytes: limit, nativeKind: nil), fileID: fileID, chatID: chatID)
    }

    private func layoutURL(fileID: UUID, chatID: Int64) -> URL {
        root.appendingPathComponent("Layouts", isDirectory: true).appendingPathComponent("\(chatID)-\(fileID.uuidString).json")
    }

    private func saveLayout(_ layout: UploadLayout, fileID: UUID, chatID: Int64) throws {
        let path = layoutURL(fileID: fileID, chatID: chatID)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(layout).write(to: path, options: [.atomic])
    }
}
