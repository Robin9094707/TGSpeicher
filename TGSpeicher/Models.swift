import Foundation

enum AuthorizationStage: Equatable {
    case apiCredentials
    case connecting
    case phone
    case code(hint: String)
    case password(hint: String)
    case qr(link: String)
    case emailAddress(pattern: String)
    case emailCode(pattern: String)
    case ready
    case closed
    case error(String)
}

struct LoginCodeInfo: Equatable {
    var deliveryType: String
    var deliveryDescription: String
    var nextDeliveryType: String?
    var nextDeliveryDescription: String?
    var timeout: Int
    var resendAvailableAt: Date?

    var canResend: Bool {
        guard nextDeliveryType != nil else { return false }
        guard let resendAvailableAt else { return true }
        return Date() >= resendAvailableAt
    }

    var remainingSeconds: Int {
        guard let resendAvailableAt else { return 0 }
        return max(0, Int(ceil(resendAvailableAt.timeIntervalSinceNow)))
    }
}

struct CloudTag: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct CloudFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, parentID, createdAt, modifiedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }
}

struct CloudChunk: Codable, Hashable {
    var index: Int
    var count: Int
    var telegramMessageID: Int64?
    var telegramFileID: Int?
    var remoteUniqueID: String?
    var size: Int64
    var storedName: String
    var sha256: String?

    init(
        index: Int,
        count: Int,
        telegramMessageID: Int64?,
        telegramFileID: Int?,
        remoteUniqueID: String?,
        size: Int64,
        storedName: String,
        sha256: String? = nil
    ) {
        self.index = index
        self.count = count
        self.telegramMessageID = telegramMessageID
        self.telegramFileID = telegramFileID
        self.remoteUniqueID = remoteUniqueID
        self.size = size
        self.storedName = storedName
        self.sha256 = sha256
    }
}

struct CloudFileEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var folderID: UUID?
    var totalSize: Int64
    var createdAt: Date
    var modifiedAt: Date
    var chunks: [CloudChunk]
    var mimeType: String?
    var tagIDs: [UUID]
    var sha256: String?
    var sourceKey: String?
    /// Chat containing the actual media messages. Nil keeps older Saved Messages backups compatible.
    var telegramChatID: Int64?
    /// documentChunks, nativePhoto, or nativeVideo. Nil means the legacy document format.
    var storageKind: String?

    init(
        id: UUID = UUID(),
        name: String,
        folderID: UUID? = nil,
        totalSize: Int64,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        chunks: [CloudChunk] = [],
        mimeType: String? = nil,
        tagIDs: [UUID] = [],
        sha256: String? = nil,
        sourceKey: String? = nil,
        telegramChatID: Int64? = nil,
        storageKind: String? = nil
    ) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.totalSize = totalSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.chunks = chunks
        self.mimeType = mimeType
        self.tagIDs = tagIDs
        self.sha256 = sha256
        self.sourceKey = sourceKey
        self.telegramChatID = telegramChatID
        self.storageKind = storageKind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderID, totalSize, createdAt, modifiedAt, chunks, mimeType, tagIDs, sha256, sourceKey, telegramChatID, storageKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        totalSize = try c.decodeIfPresent(Int64.self, forKey: .totalSize) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        chunks = try c.decodeIfPresent([CloudChunk].self, forKey: .chunks) ?? []
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        tagIDs = try c.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        telegramChatID = try c.decodeIfPresent(Int64.self, forKey: .telegramChatID)
        storageKind = try c.decodeIfPresent(String.self, forKey: .storageKind)
    }
}

struct CloudIndex: Codable {
    var version: Int
    var revision: Int64
    var folders: [CloudFolder]
    var files: [CloudFileEntry]
    var tags: [CloudTag]
    var catalogPointerMessageID: Int64?
    var catalogSnapshotMessageID: Int64?
    var lastSyncedAt: Date?

    init(
        version: Int = 2,
        revision: Int64 = 0,
        folders: [CloudFolder] = [],
        files: [CloudFileEntry] = [],
        tags: [CloudTag] = [],
        catalogPointerMessageID: Int64? = nil,
        catalogSnapshotMessageID: Int64? = nil,
        lastSyncedAt: Date? = nil
    ) {
        self.version = version
        self.revision = revision
        self.folders = folders
        self.files = files
        self.tags = tags
        self.catalogPointerMessageID = catalogPointerMessageID
        self.catalogSnapshotMessageID = catalogSnapshotMessageID
        self.lastSyncedAt = lastSyncedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, revision, folders, files, tags, catalogPointerMessageID, catalogSnapshotMessageID, lastSyncedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        revision = try c.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        folders = try c.decodeIfPresent([CloudFolder].self, forKey: .folders) ?? []
        files = try c.decodeIfPresent([CloudFileEntry].self, forKey: .files) ?? []
        tags = try c.decodeIfPresent([CloudTag].self, forKey: .tags) ?? []
        catalogPointerMessageID = try c.decodeIfPresent(Int64.self, forKey: .catalogPointerMessageID)
        catalogSnapshotMessageID = try c.decodeIfPresent(Int64.self, forKey: .catalogSnapshotMessageID)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }
}

struct CatalogSnapshot: Codable {
    static let schema = 2

    var schema: Int = CatalogSnapshot.schema
    var revision: Int64
    var createdAt: Date
    var folders: [CloudFolder]
    var files: [CloudFileEntry]
    var tags: [CloudTag]
}

struct CatalogPointerPayload: Codable {
    static let marker = "#TGSpeicherCatalogV2"

    var schema: Int = 2
    var revision: Int64
    var snapshotMessageID: Int64
    var updatedAt: Date
}

struct UploadProgress: Identifiable, Equatable {
    let id: UUID
    var fileName: String
    var completedBytes: Int64
    var totalBytes: Int64
    var currentPart: Int
    var partCount: Int
    var status: String

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

struct TGManifest: Codable {
    static let marker = "#TGSpeicher"
    static let markerV2 = "#TGSpeicherV2"

    var format: Int
    var kind: String
    var fileID: UUID?
    var folderID: UUID?
    var parentFolderID: UUID?
    var name: String
    var originalSize: Int64?
    var chunkIndex: Int?
    var chunkCount: Int?
    var createdAt: Date
    var tagIDs: [UUID]?
    var sha256: String?
    var sourceKey: String?
    var mediaKind: String? = nil
    var assetLocalIdentifier: String? = nil
    var resourceTypeRawValue: Int? = nil
    var mediaCreationDate: Date? = nil
}

struct TelegramBackupDestination: Identifiable, Codable, Hashable {
    let id: Int64
    var title: String
    var isSavedMessages: Bool
}

struct NativeMediaUploadDescriptor: Codable, Hashable {
    var kind: String
    var width: Int
    var height: Int
    var duration: Int
}

extension Int64 {
    var byteCountString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension URL {
    var fileByteSize: Int64 {
        let values = try? resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
