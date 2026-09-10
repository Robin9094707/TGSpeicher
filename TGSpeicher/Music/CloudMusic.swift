import Foundation

extension CloudStore {
    var musicLibrary: MusicLibrary { index.recovery?.music ?? MusicLibrary() }

    @discardableResult
    func editMusic(_ change: (inout MusicLibrary) -> Void) -> Bool {
        guard recoveryReady, !isRefreshing, let account = telegram.savedMessagesChatID,
              index.recovery?.accountID == account else {
            lastError = "Bitte zuerst die Wiederherstellung abschließen."; return false
        }
        let previous = index
        var music = musicLibrary
        change(&music)
        do { try music.validate() } catch { lastError = error.localizedDescription; return false }
        guard music != musicLibrary else { return true }
        index.recovery?.music = music
        guard persist() else { index = previous; return false }
        catalogMutation += 1
        forceNextCatalog = true
        scheduleCatalogSync(delay: 3)
        return true
    }
}
