import Foundation
import UIKit

extension CloudStore {
    func bootstrapFromTelegram() {
        guard let account = telegram.savedMessagesChatID, !isRefreshing, upload == nil, !isCatalogSyncing else { return }
        recoveryRun = UUID()
        recoveryReady = false
        isRefreshing = true
        lastError = nil
        catalogStatus = "Katalog wird in Telegram gesucht …"
        if let owner = index.recovery?.accountID, owner != 0, owner != account {
            if let url = localIndexURL, let data = try? JSONEncoder().encode(index) {
                try? data.write(to: url.deletingLastPathComponent().appendingPathComponent("catalog-account-\(owner).json"), options: [.atomic])
                let other = url.deletingLastPathComponent().appendingPathComponent("catalog-account-\(account).json")
                index = (try? Data(contentsOf: other)).flatMap { try? JSONDecoder().decode(CloudIndex.self, from: $0) } ?? CloudIndex()
            } else { index = CloudIndex() }
        }
        if index.recovery == nil { index.recovery = RecoveryMetadata(accountID: account) }
        index.recovery?.accountID = account
        if let anchor = KeychainStore.recoveryAnchor(accountID: account) {
            index.recovery?.destinationChatID = index.recovery?.destinationChatID ?? anchor.destinationChatID
        }
        if index.recovery?.destinationChatID == nil {
            index.recovery?.destinationChatID = UserDefaults.standard.string(forKey: "photos.backupDestinationChatID.v1").flatMap(Int64.init)
        }
        searchRecoverySnapshots(marker: snapshotMarker, cursor: 0)
    }

    func fullRebuildFromTelegram() {
        guard !isRefreshing, upload == nil, !isCatalogSyncing else { return }
        index.recovery?.scannedThrough = [:]
        bootstrapFromTelegram()
    }

    func setRecoveryDestination(_ chatID: Int64) {
        guard let account = telegram.savedMessagesChatID, !isRefreshing, upload == nil, !isCatalogSyncing else { return }
        if index.recovery == nil { index.recovery = RecoveryMetadata(accountID: account) }
        index.recovery?.accountID = account
        index.recovery?.destinationChatID = chatID
        catalogMutation += 1
        persist()
        refreshRecoveryAnchor()
        bootstrapFromTelegram()
    }

    func refreshRecoveryAnchor() {
        guard let account = telegram.savedMessagesChatID else { return }
        let anchor = RecoveryAnchor(accountID: account, pointerID: index.catalogPointerMessageID,
                                    snapshotID: index.catalogSnapshotMessageID,
                                    destinationChatID: index.recovery?.destinationChatID, updatedAt: Date())
        keychainStatus = KeychainStore.saveRecoveryAnchor(anchor)
            ? "Verweise im synchronisierbaren Schlüsselbund gespeichert"
            : "Schlüsselbund nicht verfügbar; Telegram-Katalog bleibt nutzbar"
    }

    func exportRecoveryCatalog() {
        guard !isRefreshing, recoveryReady else { lastError = "Bitte zuerst den Katalog wiederherstellen."; return }
        let snapshot = CatalogSnapshot(revision: index.revision, createdAt: Date(), folders: index.folders,
                                       files: index.files, tags: index.tags, recovery: index.recovery)
        do {
            let data = try CatalogCodec.encode(snapshot)
            let folder = catalogBackupFolderURL ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("TGSpeicher-Katalog-\(Int(Date().timeIntervalSince1970)).tgscatalog")
            try data.write(to: url, options: [.atomic])
            lastExportURL = url
            lastCatalogBytes = data.count
        } catch { lastError = error.localizedDescription }
    }

    func importRecoveryCatalog(from url: URL) {
        guard let account = telegram.savedMessagesChatID, upload == nil, !isRefreshing, !isCatalogSyncing else {
            lastError = "Bitte Telegram verbinden und laufende Übertragungen abwarten."; return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.fileByteSize <= Int64(CatalogCodec.maxBytes) else { throw RecoveryError.invalid("Die Katalogdatei ist zu groß.") }
            let snapshot = try CatalogCodec.decode(Data(contentsOf: url), accountID: account)
            // Validate completely before touching the live catalog. Preserve a rollback copy.
            if let folder = catalogBackupFolderURL {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(index).write(to: folder.appendingPathComponent("Katalog-vor-Import-\(Int(Date().timeIntervalSince1970)).json"), options: [.atomic])
            }
            let merged = CatalogCodec.merge(snapshot, into: index, accountID: account)
            try CatalogCodec.validate(CatalogSnapshot(revision: merged.revision, createdAt: Date(), folders: merged.folders,
                files: merged.files, tags: merged.tags, recovery: merged.recovery))
            index = merged
            index.recovery?.scannedThrough = [:]
            persist()
            refreshRecoveryAnchor()
            recoveryRun = UUID()
            isRefreshing = true
            recoveryReady = false
            startRecoveryScan()
        } catch { lastError = "Katalog nicht übernommen: \(error.localizedDescription)" }
    }

    func restoreFromCatalogPointer(_ rawMessageID: String) {
        guard let id = Int64(rawMessageID.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0,
              let chat = telegram.savedMessagesChatID, upload == nil, !isRefreshing, !isCatalogSyncing else {
            lastError = "Bitte eine gültige Nachrichten-ID eingeben und laufende Übertragungen abwarten."; return
        }
        recoveryRun = UUID()
        isRefreshing = true
        recoveryReady = false
        recoveryRequest(["@type": "getMessage", "chat_id": chat, "message_id": id]) { message in
            let text = DurableOutbox.caption(message)
            if let range = text.range(of: CatalogPointerPayload.marker),
               let data = Data(base64Encoded: text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if let pointer = try? decoder.decode(CatalogPointerPayload.self, from: data) {
                    self.index.catalogPointerMessageID = id
                    self.downloadRecoverySnapshot(pointer.snapshotMessageID) { success in
                        if success { self.startRecoveryScan() } else { self.searchRecoverySnapshots(marker: self.snapshotMarker, cursor: 0) }
                    }
                    return
                }
            }
            self.downloadRecoverySnapshot(id) { success in
                if success { self.startRecoveryScan() }
                else { self.recoveryFailed("Diese Nachricht enthält keinen lesbaren Katalog.") }
            }
        }
    }

    private func recoveryRequest(_ request: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let run = recoveryRun
        let account = telegram.savedMessagesChatID
        telegram.send(request) { [weak self] response in
            guard let self, self.recoveryRun == run, self.telegram.savedMessagesChatID == account else { return }
            if let wait = TelegramClient.retryAfterSeconds(response) {
                self.recoveryProgress = "Telegram-Pause: noch \(wait) Sekunden"
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(wait + 1)) { [weak self] in
                    guard let self, self.recoveryRun == run, self.telegram.savedMessagesChatID == account else { return }
                    self.recoveryRequest(request, completion: completion)
                }
            } else { completion(response) }
        }
    }

    private func searchRecoverySnapshots(marker: String, cursor: Int64) {
        guard let chat = telegram.savedMessagesChatID else { return }
        recoverySearchMarker = marker
        recoveryRequest(["@type": "searchChatMessages", "chat_id": chat, "topic_id": NSNull(),
                         "query": marker, "sender_id": NSNull(), "from_message_id": cursor,
                         "offset": 0, "limit": 20, "filter": NSNull()]) { response in
            guard response["@type"] as? String != "error", let messages = response["messages"] as? [[String: Any]] else {
                self.recoveryFailed("Telegram-Katalog konnte nicht abgefragt werden. Bitte erneut aktualisieren."); return
            }
            self.recoveryCandidates = messages.filter { self.documentFileInfo(fromMessage: $0).fileID != nil }
                .compactMap { TelegramClient.int64($0["id"]) }
            let next = TelegramClient.int64(response["next_from_message_id"]) ?? 0
            guard next == 0 || next != cursor else { self.recoveryFailed("Telegram hat dieselbe Katalogseite erneut geliefert."); return }
            self.recoveryNextCursor = next
            self.tryNextRecoverySnapshot()
        }
    }

    private func tryNextRecoverySnapshot() {
        if !recoveryCandidates.isEmpty {
            let id = recoveryCandidates.removeFirst()
            downloadRecoverySnapshot(id) { success in
                if success { self.startRecoveryScan() } else { self.tryNextRecoverySnapshot() }
            }
        } else if recoveryNextCursor != 0 {
            searchRecoverySnapshots(marker: recoverySearchMarker, cursor: recoveryNextCursor)
        } else if recoverySearchMarker == snapshotMarker {
            searchRecoverySnapshots(marker: "#TGSpeicherCatalogSnapshotV2", cursor: 0)
        } else { startRecoveryScan() }
    }

    private func downloadRecoverySnapshot(_ messageID: Int64, completion: @escaping (Bool) -> Void) {
        guard let chat = telegram.savedMessagesChatID else { return }
        recoveryProgress = "Katalog laden und Prüfsumme kontrollieren …"
        recoveryRequest(["@type": "getMessage", "chat_id": chat, "message_id": messageID]) { message in
            guard let fileID = self.documentFileInfo(fromMessage: message).fileID else { completion(false); return }
            guard self.documentFileInfo(fromMessage: message).size <= Int64(CatalogCodec.maxBytes) else { completion(false); return }
            self.recoveryRequest(["@type": "downloadFile", "file_id": fileID, "priority": 32,
                                  "offset": 0, "limit": 0, "synchronous": true]) { file in
                guard let local = file["local"] as? [String: Any], local["is_downloading_completed"] as? Bool == true,
                      let path = local["path"] as? String, !path.isEmpty else { completion(false); return }
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let snapshot = try CatalogCodec.decode(data, accountID: chat)
                    self.index = CatalogCodec.merge(snapshot, into: self.index, accountID: chat)
                    self.index.catalogSnapshotMessageID = messageID
                    self.lastCatalogBytes = data.count
                    self.persist()
                    completion(true)
                } catch {
                    self.recoveryProgress = "Sicherung unlesbar – ältere Version wird geprüft …"
                    completion(false)
                }
            }
        }
    }

    private func startRecoveryScan() {
        guard let account = telegram.savedMessagesChatID else { return }
        if index.recovery == nil { index.recovery = RecoveryMetadata(accountID: account) }
        index.recovery?.accountID = account
        if index.recovery?.destinationChatID == nil {
            let channels = Set(index.files.filter { $0.sourceKey != nil }.compactMap(\.telegramChatID)).subtracting([account])
            if channels.count == 1 { index.recovery?.destinationChatID = channels.first }
        }
        let chats = Set([account] + [index.recovery?.destinationChatID].compactMap { $0 }
            + index.files.compactMap(\.telegramChatID) + (index.recovery?.partialFiles.compactMap(\.telegramChatID) ?? []))
        scanRecoveryChat(chats.sorted(), at: 0)
    }

    private func scanRecoveryChat(_ chats: [Int64], at position: Int) {
        guard position < chats.count else {
            CatalogCodec.repairReferences(&index)
            // Merge can reveal a cycle spanning two individually valid snapshots.
            let snapshot = CatalogSnapshot(revision: index.revision, createdAt: Date(), folders: index.folders,
                                           files: index.files, tags: index.tags, recovery: index.recovery)
            do { try CatalogCodec.validate(snapshot) }
            catch { recoveryFailed(error.localizedDescription); return }
            catalogMutation += 1
            recoveryReady = true
            persist()
            refreshRecoveryAnchor()
            isRefreshing = false
            recoveryProgress = "\(index.files.count) Dateien abgeglichen"
            catalogStatus = "Wiederherstellung abgeschlossen"
            scheduleCatalogSync(delay: 1)
            return
        }
        let chat = chats[position]
        knownRecoveryFileIDs = Set(index.files.filter(\.isComplete).map(\.id))
        scanHighWater = index.recovery?.scannedThrough[String(chat)] ?? 0
        scannedRecoveryFiles = Dictionary((index.recovery?.partialFiles ?? []).filter { $0.telegramChatID == chat }
            .map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        recoveryRequest(["@type": "getChat", "chat_id": chat]) { response in
            guard response["@type"] as? String != "error" else {
                self.recoveryFailed("Kein Zugriff auf Sicherungskanal \(chat). Bitte Telegram-Verbindung und Kanalmitgliedschaft prüfen."); return
            }
            self.scanRecoveryPage(chat: chat, cursor: 0, cutoff: self.scanHighWater) {
                self.index.recovery?.scannedThrough[String(chat)] = self.scanHighWater
                self.index.recovery?.partialFiles.removeAll { $0.telegramChatID == chat }
                self.index.recovery?.partialFiles.append(contentsOf: self.scannedRecoveryFiles.values.filter { !$0.isComplete })
                self.persist()
                self.scanRecoveryChat(chats, at: position + 1)
            }
        }
    }

    private func scanRecoveryPage(chat: Int64, cursor: Int64, cutoff: Int64, completion: @escaping () -> Void) {
        recoveryRequest(["@type": "getChatHistory", "chat_id": chat, "from_message_id": cursor,
                         "offset": 0, "limit": 100, "only_local": false]) { response in
            guard response["@type"] as? String != "error", let messages = response["messages"] as? [[String: Any]] else {
                self.recoveryFailed("Der Kanalverlauf konnte nicht vollständig gelesen werden. Uploads bleiben angehalten."); return
            }
            let confirmed = messages.filter { DurableOutbox.isFinal($0) }
            let ids = confirmed.compactMap { TelegramClient.int64($0["id"]) }
            self.scanHighWater = max(self.scanHighWater, ids.max() ?? 0)
            self.recoveryPageFiles = []
            for message in confirmed where (TelegramClient.int64(message["id"]) ?? 0) > cutoff {
                self.recoverMediaMessage(message, chat: chat)
            }
            if !self.recoveryPageFiles.isEmpty { self.index.files.append(contentsOf: self.recoveryPageFiles) }
            self.recoveryProgress = "Kanal wird abgeglichen: \(self.index.files.count) Dateien erkannt"
            // TDLib can return short pages. Only an empty page, an exhausted
            // boundary, or the persisted message-ID cursor ends the scan.
            let next = ids.min() ?? 0
            if messages.isEmpty || (cutoff > 0 && ids.contains(where: { $0 <= cutoff })) || (cursor != 0 && next == cursor) {
                completion()
            } else if next > 0, cursor == 0 || next < cursor {
                self.scanRecoveryPage(chat: chat, cursor: next, cutoff: cutoff, completion: completion)
            } else {
                self.recoveryFailed("Telegram liefert noch ausstehende Nachrichten. Bitte die Wiederherstellung gleich erneut starten.")
            }
        }
    }

    private func recoverMediaMessage(_ message: [String: Any], chat: Int64) {
        guard let manifest = decodeManifest(from: DurableOutbox.caption(message)) else { return }
        if manifest.kind == "folder", let id = manifest.folderID, index.recovery?.deletedFolders[id] == nil {
            if !index.folders.contains(where: { $0.id == id }) {
                index.folders.append(CloudFolder(id: id, name: manifest.name, parentID: manifest.parentFolderID,
                                                createdAt: manifest.createdAt, modifiedAt: manifest.createdAt))
            }
            return
        }
        guard ["fileChunk", "nativePhoto", "nativeVideo"].contains(manifest.kind),
              let id = manifest.fileID, index.recovery?.deletedFiles[id] == nil,
              let messageID = TelegramClient.int64(message["id"]), messageID > 0 else { return }
        // A newer local/catalog entry owns rename, move and tag metadata.
        if knownRecoveryFileIDs.contains(id) { return }
        let info = mediaFileInfo(fromMessage: message)
        guard info.fileID != nil else { return }
        var file = scannedRecoveryFiles[id] ?? CloudFileEntry(id: id, name: manifest.name, folderID: manifest.folderID,
            totalSize: manifest.originalSize ?? info.size, createdAt: manifest.mediaCreationDate ?? manifest.createdAt,
            modifiedAt: manifest.createdAt, tagIDs: manifest.tagIDs ?? [], sourceKey: manifest.sourceKey,
            telegramChatID: chat, storageKind: manifest.kind == "fileChunk" ? "documentChunks" : manifest.kind)
        let part = manifest.chunkIndex ?? 1
        let count = manifest.chunkCount ?? 1
        guard part > 0, part <= count, count <= 100_000 else { return }
        // Reverse history order: keep one already confirmed part rather than
        // adding every historical duplicate to the logical file.
        if !file.chunks.contains(where: { $0.index == part }) {
            file.chunks.append(CloudChunk(index: part, count: count, telegramMessageID: messageID,
                                         telegramFileID: nil, remoteUniqueID: info.uniqueID, size: info.size,
                                         storedName: manifest.name, sha256: manifest.kind == "fileChunk" ? manifest.sha256 : nil))
        }
        file.chunks.sort { $0.index < $1.index }
        scannedRecoveryFiles[id] = file
        if file.isComplete {
            knownRecoveryFileIDs.insert(id)
            recoveryPageFiles.append(file)
        }
    }

    private func recoveryFailed(_ message: String) {
        recoveryReady = false
        isRefreshing = false
        recoveryProgress = message
        catalogStatus = "Wiederherstellung noch nicht abgeschlossen"
        lastError = message
    }
}
