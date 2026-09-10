import Foundation

struct MusicPlaylist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var updatedAt = Date().timeIntervalSince1970
    var editID = UUID().uuidString

    mutating func edit(name: String? = nil, tracks: [UUID]? = nil) {
        if let name { self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        if let tracks { var seen = Set<UUID>(); trackIDs = tracks.filter { seen.insert($0).inserted } }
        updatedAt = max(Date().timeIntervalSince1970, updatedAt.nextUp)
        editID = UUID().uuidString
    }
}

struct MusicTrackInfo: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var details: [String: String] = [:]
    var updatedAt = Date().timeIntervalSince1970
}

/// Small, portable references only. Audio and regenerable artwork never inflate the catalog.
struct MusicLibrary: Codable, Equatable {
    var version = 1
    var playlists: [MusicPlaylist] = []
    var deletedPlaylists: [UUID: Double] = [:]
    var tracks: [UUID: MusicTrackInfo] = [:]

    func merging(_ other: MusicLibrary?) -> MusicLibrary {
        guard let other else { return self }
        var result = self
        result.deletedPlaylists.merge(other.deletedPlaylists, uniquingKeysWith: max)
        var lists = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: Self.newer)
        for item in other.playlists { lists[item.id] = lists[item.id].map { Self.newer($0, item) } ?? item }
        // A removed list has a permanent tombstone; creating another list uses a new UUID.
        result.playlists = lists.values.filter { result.deletedPlaylists[$0.id] == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        result.tracks.merge(other.tracks) { $0.updatedAt >= $1.updatedAt ? $0 : $1 }
        return result
    }

    private static func newer(_ a: MusicPlaylist, _ b: MusicPlaylist) -> MusicPlaylist {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        return a.editID >= b.editID ? a : b
    }

    func validate() throws {
        guard version == 1, playlists.count <= 10_000, tracks.count <= 200_000,
              Set(playlists.map(\.id)).count == playlists.count,
              playlists.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 200 && $0.updatedAt.isFinite
                  && $0.trackIDs.count <= 100_000 && Set($0.trackIDs).count == $0.trackIDs.count }),
              deletedPlaylists.values.allSatisfy(\.isFinite),
              tracks.values.allSatisfy({ $0.updatedAt.isFinite && ($0.duration == nil || ($0.duration!.isFinite && $0.duration! >= 0))
                  && $0.details.count <= 128 && $0.details.allSatisfy { $0.key.count <= 256 && $0.value.count <= 32_768 } }) else {
            throw RecoveryError.invalid("Die Musikbibliothek ist beschädigt oder verwendet eine neuere Version.")
        }
    }
}

extension CloudFileEntry {
    var isMusic: Bool {
        mimeType?.lowercased().hasPrefix("audio/") == true ||
        ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff", "alac", "caf", "ogg", "opus", "wma"].contains((name as NSString).pathExtension.lowercased())
    }
}

/// Maps a virtual audio file onto bounded reads, including multipart Telegram documents.
struct MusicRangeMap {
    struct Slice: Equatable { let chunk: Int; let offset: Int64; let count: Int }
    static let blockSize = 512 * 1024
    let sizes: [Int64]
    let total: Int64

    init(sizes: [Int64], total: Int64) throws {
        var sum: Int64 = 0
        for size in sizes {
            let next = sum.addingReportingOverflow(size)
            guard size > 0, !next.overflow else { throw RecoveryError.invalid("Ungültige Musik-Dateiteile.") }
            sum = next.partialValue
        }
        guard !sizes.isEmpty, sum == total else { throw RecoveryError.invalid("Die Musikdatei ist noch nicht vollständig im Katalog.") }
        self.sizes = sizes; self.total = total
    }

    func slice(offset: Int64, remaining: Int64) throws -> Slice? {
        guard offset >= 0, offset <= total, remaining >= 0 else { throw RecoveryError.invalid("Ungültiger Wiedergabebereich.") }
        guard remaining > 0, offset < total else { return nil }
        var start: Int64 = 0
        for (index, size) in sizes.enumerated() {
            if offset < start + size {
                return Slice(chunk: index, offset: offset - start, count: Int(min(Int64(Self.blockSize), remaining, start + size - offset)))
            }
            start += size
        }
        return nil
    }

    static func verifiedRead(path: String, offset: Int64, count: Int, downloadedPrefix: Int64) throws -> Data {
        guard offset >= 0, count > 0, count <= blockSize, downloadedPrefix >= Int64(count), !path.isEmpty else {
            throw RecoveryError.invalid("Der Audiobereich ist noch nicht vollständig geladen.")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw RecoveryError.invalid("Unvollständige Audiodaten. Bitte erneut versuchen.") }
        return data
    }
}

enum MusicRepeat: String, Codable, CaseIterable {
    case off, all, one
    var label: String { switch self { case .off: return "Aus"; case .all: return "Alle Titel"; case .one: return "Ein Titel" } }
}

struct MusicQueue: Codable {
    var ids: [UUID] = []
    var position = 0
    var repeatMode: MusicRepeat = .off
    var current: UUID? { ids.indices.contains(position) ? ids[position] : nil }
    mutating func advance(manual: Bool = false) -> UUID? {
        guard current != nil else { return nil }
        if repeatMode == .one && !manual { return current }
        if position + 1 < ids.count { position += 1; return current }
        if repeatMode == .all { position = 0; return current }
        return nil
    }
}
