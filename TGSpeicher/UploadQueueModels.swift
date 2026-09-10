import Foundation

struct PhotoBackupQueueMetadata: Codable, Hashable {
    let resourceKey: String
    let assetLocalIdentifier: String
    let resourceTypeRawValue: Int
    let fileName: String
    let mediaKind: String
    let creationDate: Date?
    var destinationChatID: Int64? = nil
    var nativeMedia: NativeMediaUploadDescriptor? = nil
}

struct QueuedUpload: Identifiable, Codable, Hashable {
    enum State: String, Codable {
        case queued
        case uploading
        case failed
        case completed
    }

    let id: UUID
    var localPath: String
    var displayName: String
    var folderID: UUID?
    var tagIDs: [UUID]
    var byteSize: Int64
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var state: State
    var lastError: String?
    var cloudFileID: UUID?
    var photoBackup: PhotoBackupQueueMetadata?
    var automaticRetryCount: Int?
    var accountID: Int64? = nil
    var musicDestinationChatID: Int64? = nil
    var musicDescriptor: NativeMediaUploadDescriptor? = nil

    init(
        id: UUID = UUID(),
        localPath: String,
        displayName: String,
        folderID: UUID?,
        tagIDs: [UUID],
        byteSize: Int64,
        createdAt: Date = Date(),
        state: State = .queued,
        cloudFileID: UUID? = nil,
        photoBackup: PhotoBackupQueueMetadata? = nil,
        automaticRetryCount: Int? = nil
    ) {
        self.id = id
        self.localPath = localPath
        self.displayName = displayName
        self.folderID = folderID
        self.tagIDs = tagIDs
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.state = state
        self.cloudFileID = cloudFileID
        self.photoBackup = photoBackup
        self.automaticRetryCount = automaticRetryCount
    }
}

