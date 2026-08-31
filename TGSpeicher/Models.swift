import Foundation

enum AuthorizationStage: Equatable {
    case apiCredentials
    case connecting
    case phone
    case code(hint: String)
    case password(hint: String)
    case ready
    case closed
    case error(String)
}

struct CloudFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
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
}

struct CloudFileEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var folderID: UUID?
    var totalSize: Int64
    var createdAt: Date
    var chunks: [CloudChunk]
    var mimeType: String?

    init(
        id: UUID = UUID(),
        name: String,
        folderID: UUID? = nil,
        totalSize: Int64,
        createdAt: Date = Date(),
        chunks: [CloudChunk] = [],
        mimeType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.totalSize = totalSize
        self.createdAt = createdAt
        self.chunks = chunks
        self.mimeType = mimeType
    }
}

struct CloudIndex: Codable {
    var version: Int = 1
    var folders: [CloudFolder] = []
    var files: [CloudFileEntry] = []
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
