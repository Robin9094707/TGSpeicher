import Foundation

/// Automatic tag/cover discovery can complete many tracks in quick succession.
/// Persisting the entire cloud index after every single track blocks the main thread,
/// causes repeated catalog encodes and can make iOS terminate the app during a
/// foreground/background transition. Structural user edits still persist immediately;
/// metadata-only changes are safely coalesced into one write.
private final class MusicMetadataPersistenceCoordinator {
    static let shared = MusicMetadataPersistenceCoordinator()

    private struct PendingWrite {
        let token: UUID
        let work: DispatchWorkItem
    }
    private var pending: [ObjectIdentifier: PendingWrite] = [:]

    func schedule(store: CloudStore, accountID: Int64) {
        let key = ObjectIdentifier(store)
        guard pending[key] == nil else { return }

        let token = UUID()
        let work = DispatchWorkItem { [weak self, weak store] in
            guard let self, self.pending[key]?.token == token else { return }
            self.pending[key] = nil
            guard let store,
                  store.telegram.savedMessagesChatID == accountID,
                  store.index.recovery?.accountID == accountID,
                  store.recoveryReady, !store.isRefreshing else { return }

            guard store.persist() else { return }
            store.catalogMutation += 1
            store.forceNextCatalog = true
            store.scheduleCatalogSync(delay: 3)
        }
        pending[key] = PendingWrite(token: token, work: work)

        // Long enough to combine several sequential metadata reads, short enough that
        // discovered tags normally survive even if the user leaves the music screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func cancelPending(for store: CloudStore) {
        let key = ObjectIdentifier(store)
        pending.removeValue(forKey: key)?.work.cancel()
    }
}

extension CloudStore {
    var musicLibrary: MusicLibrary { index.recovery?.music ?? MusicLibrary() }
    var musicFiles: [CloudFileEntry] {
        let owned = index.files.filter(\.isMusic)
        let ownedIDs = Set(owned.map(\.id))
        return owned + (musicLibrary.channelFiles ?? []).filter { !ownedIDs.contains($0.id) }
    }

    func musicFile(id: UUID) -> CloudFileEntry? {
        index.files.first { $0.id == id } ?? musicLibrary.channelFiles?.first { $0.id == id }
    }

    func removeChannelMusic(_ ids: Set<UUID>) {
        editMusic { $0.removeChannelFiles(ids) }
    }

    @discardableResult
    func editMusic(_ change: (inout MusicLibrary) -> Void) -> Bool {
        guard recoveryReady, !isRefreshing, let account = telegram.savedMessagesChatID,
              index.recovery?.accountID == account else {
            lastError = "Bitte zuerst die Wiederherstellung abschließen."; return false
        }

        let previous = index
        let previousMusic = musicLibrary
        var music = previousMusic
        change(&music)
        do { try music.validate() } catch { lastError = error.localizedDescription; return false }
        guard music != previousMusic else { return true }

        // Track metadata is regenerable. Keep it immediately visible in memory, but do
        // not synchronously JSON-encode/write the complete CloudIndex for every title.
        let metadataOnly = music.channel == previousMusic.channel
            && music.version == previousMusic.version
            && music.playlists == previousMusic.playlists
            && music.deletedPlaylists == previousMusic.deletedPlaylists
            && music.channelFiles == previousMusic.channelFiles
            && music.removedChannelFiles == previousMusic.removedChannelFiles

        index.recovery?.music = music

        if metadataOnly {
            MusicMetadataPersistenceCoordinator.shared.schedule(store: self, accountID: account)
            return true
        }

        // A user-visible edit (playlist/channel/etc.) must be durable immediately. Any
        // pending metadata is already in `index`, so this one write also flushes it.
        MusicMetadataPersistenceCoordinator.shared.cancelPending(for: self)
        guard persist() else { index = previous; return false }
        catalogMutation += 1
        forceNextCatalog = true
        scheduleCatalogSync(delay: 3)
        return true
    }
}

