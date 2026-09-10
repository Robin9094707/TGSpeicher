import Foundation
import Photos

enum BackgroundRelayShared {
    static let appGroup = "group.eu.simplexsmp.tgspeicher.background"
    static let baseURLString = "https://backup.rjuhas.eu"

    private enum Key {
        static let enabled = "relay.background.enabled.v1"
        static let deviceID = "relay.background.deviceID.v1"
        static let deviceToken = "relay.background.deviceToken.v1"
        static let deviceName = "relay.background.deviceName.v1"
        static let allowCellular = "relay.background.allowCellular.v1"
        static let chargingOnly = "relay.background.chargingOnly.v1"
        static let lastServerContact = "relay.background.lastServerContact.v1"
        static let lastServerError = "relay.background.lastServerError.v1"
        static let lastExtensionRun = "relay.background.lastExtensionRun.v1"
        static let lastSuccessfulDelivery = "relay.background.lastSuccessfulDelivery.v1"
        static let extensionStatus = "relay.background.extensionStatus.v1"
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    static var enabled: Bool { get { defaults.bool(forKey: Key.enabled) } set { defaults.set(newValue, forKey: Key.enabled) } }
    static var deviceID: String? { get { defaults.string(forKey: Key.deviceID) } set { defaults.set(newValue, forKey: Key.deviceID) } }
    static var deviceToken: String? { get { defaults.string(forKey: Key.deviceToken) } set { defaults.set(newValue, forKey: Key.deviceToken) } }
    static var deviceName: String { get { defaults.string(forKey: Key.deviceName) ?? "iPhone" } set { defaults.set(newValue, forKey: Key.deviceName) } }
    static var allowCellular: Bool { get { defaults.object(forKey: Key.allowCellular) as? Bool ?? false } set { defaults.set(newValue, forKey: Key.allowCellular) } }
    static var chargingOnly: Bool { get { defaults.bool(forKey: Key.chargingOnly) } set { defaults.set(newValue, forKey: Key.chargingOnly) } }
    static var lastServerContact: Date? { get { defaults.object(forKey: Key.lastServerContact) as? Date } set { defaults.set(newValue, forKey: Key.lastServerContact) } }
    static var lastServerError: String? { get { defaults.string(forKey: Key.lastServerError) } set { defaults.set(newValue, forKey: Key.lastServerError) } }
    static var lastExtensionRun: Date? { get { defaults.object(forKey: Key.lastExtensionRun) as? Date } set { defaults.set(newValue, forKey: Key.lastExtensionRun) } }
    static var lastSuccessfulDelivery: Date? { get { defaults.object(forKey: Key.lastSuccessfulDelivery) as? Date } set { defaults.set(newValue, forKey: Key.lastSuccessfulDelivery) } }
    static var extensionStatus: String { get { defaults.string(forKey: Key.extensionStatus) ?? "Noch nicht ausgeführt" } set { defaults.set(newValue, forKey: Key.extensionStatus) } }

    static func clearPairing() { deviceID = nil; deviceToken = nil }

    static func resourceName(_ resource: PHAssetResource, asset: PHAsset? = nil) -> String {
        if #available(iOS 27.0, *), let name = resource.filename, !name.isEmpty { return name }
        if !resource.originalFilename.isEmpty { return resource.originalFilename }
        let ext: String
        switch resource.type {
        case .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo: ext = "mov"
        default: ext = "heic"
        }
        return "Photo-\((asset?.localIdentifier ?? resource.assetLocalIdentifier).hashValue.magnitude).\(ext)"
    }

    static func resourceKey(_ resource: PHAssetResource, asset: PHAsset? = nil) -> String {
        "\(resource.assetLocalIdentifier)|\(resource.type.rawValue)|\(resourceName(resource, asset: asset))"
    }

    static func mediaKind(asset: PHAsset, resource: PHAssetResource) -> String {
        switch resource.type {
        case .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo: return "video"
        default: return asset.mediaType == .video ? "video" : "photo"
        }
    }

    static func preferredResources(for asset: PHAsset) -> [PHAssetResource] {
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
        if asset.mediaSubtypes.contains(.photoLive), let paired = all.first(where: { $0.type == .fullSizePairedVideo }) ?? all.first(where: { $0.type == .pairedVideo }) { result.append(paired) }
        return result
    }
}

struct BackgroundRelayIndex: Codable {
    var schema = 1
    var completedKeys: Set<String> = []
    var scanCursor = 0
    var lastKnownAssetCount = 0
    var lastRun: Date?
    var lastSuccess: Date?
    var lastError: String?
    var lastQueuedCount = 0
    var lastSeenResources = 0
}

enum BackgroundRelayIndexStore {
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BackgroundRelayShared.appGroup)?.appendingPathComponent("BackgroundRelayIndex-v1.json")
    }
    static func load() -> BackgroundRelayIndex {
        guard let url, let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(BackgroundRelayIndex.self, from: data) else { return BackgroundRelayIndex() }
        return value
    }
    static func save(_ value: BackgroundRelayIndex) {
        guard let url, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
    static func seedCompleted(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        var state = load(); state.completedKeys.formUnion(keys); save(state)
    }
}
