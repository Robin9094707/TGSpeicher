import Foundation

@main
struct RecoveryTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard value() else { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }
    static func rejects(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("FAIL: \(name) did not reject") }
        catch { checks += 1; print("PASS: \(name)") }
    }
    static func main() throws {
        let folder = CloudFolder(name: "Reisen")
        let nested = CloudFolder(name: "Sommer", parentID: folder.id)
        let tag = CloudTag(name: "Familie")
        let part = CloudChunk(index: 1, count: 1, telegramMessageID: 123 << 20, telegramFileID: 81,
                              remoteUniqueID: "remote", size: 100, storedName: "foto.jpg")
        let file = CloudFileEntry(name: "foto.jpg", folderID: nested.id, totalSize: 100, chunks: [part],
                                  tagIDs: [tag.id], sourceKey: "asset|1|foto.jpg", telegramChatID: -100123)
        let metadata = RecoveryMetadata(accountID: 99, destinationChatID: -100123)
        let snapshot = CatalogSnapshot(revision: 8, createdAt: Date(), folders: [folder, nested], files: [file], tags: [tag], recovery: metadata)
        let packed = try CatalogCodec.encode(snapshot)
        let restored = try CatalogCodec.decode(packed, accountID: 99)
        check(restored.files[0].chunks[0].telegramMessageID == part.telegramMessageID, "message IDs survive archive round trip")
        check(restored.folders[1].parentID == folder.id && restored.files[0].tagIDs == [tag.id], "nested folders and tags survive reinstall")
        check(restored.recovery?.destinationChatID == -100123, "channel selection survives reinstall")
        rejects("unrelated JSON cannot replace catalog") { _ = try CatalogCodec.decode(Data("{}".utf8), accountID: 99) }
        rejects("cross-account import rejected") { _ = try CatalogCodec.decode(packed, accountID: 100) }
        var json = try JSONSerialization.jsonObject(with: packed) as! [String: Any]
        json["sha256"] = "bad"
        let tampered = try JSONSerialization.data(withJSONObject: json)
        rejects("corrupt checksum rejected") { _ = try CatalogCodec.decode(tampered, accountID: 99) }
        var emptyPayload = json
        emptyPayload["payload"] = ""
        rejects("empty compressed payload rejected safely") { _ = try CatalogCodec.decode(JSONSerialization.data(withJSONObject: emptyPayload), accountID: 99) }
        json["bytes"] = CatalogCodec.maxBytes + 1
        rejects("decompression size bounded") { _ = try CatalogCodec.decode(JSONSerialization.data(withJSONObject: json), accountID: 99) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var legacy = snapshot; legacy.recovery = nil
        let legacyData = try encoder.encode(legacy)
        check(tryDecode(legacyData)?.files.count == 1, "legacy v2 JSON import supported")
        var bad = snapshot; bad.files[0].chunks[0].count = 2
        rejects("incomplete chunks cannot be marked backed up") { _ = try CatalogCodec.encode(bad) }
        bad = snapshot; bad.folders.append(folder)
        rejects("duplicate IDs rejected without dictionary trap") { _ = try CatalogCodec.encode(bad) }
        bad = snapshot; bad.folders[0].parentID = nested.id
        rejects("cyclic folders rejected") { _ = try CatalogCodec.encode(bad) }
        var local = CloudIndex(files: [file]); local.recovery = metadata
        local.files[0].name = "Umbenannt.jpg"; local.files[0].modifiedAt = Date().addingTimeInterval(60)
        let merged = CatalogCodec.merge(snapshot, into: local, accountID: 99)
        check(merged.files[0].name == "Umbenannt.jpg", "stale snapshot preserves newer local rename")
        check(merged.files[0].chunks[0].telegramFileID == nil, "session-specific TDLib IDs cleared on restore")
        local.recovery?.deletedFiles[file.id] = Date()
        check(CatalogCodec.merge(snapshot, into: local, accountID: 99).files.isEmpty, "tombstones prevent resurrection")
        check(CatalogCodec.resourceIdentity(sourceKey: "asset", accountID: 1, destination: 10) != CatalogCodec.resourceIdentity(sourceKey: "asset", accountID: 1, destination: 20), "same photo in different channels is not discarded by queue deduplication")
        check(CatalogCodec.resourceIdentity(sourceKey: "asset", accountID: 1, destination: 10) != CatalogCodec.resourceIdentity(sourceKey: "asset", accountID: 2, destination: 10), "photo queue resource identities isolated by account")
        let hash = CatalogCodec.digest(Data("original media".utf8))
        check(CatalogCodec.stableMediaID(hash: hash, chatID: 1) == CatalogCodec.stableMediaID(hash: hash, chatID: 1), "media identity stable across queue recreation")
        check(CatalogCodec.stableMediaID(hash: hash, chatID: 1) != CatalogCodec.stableMediaID(hash: hash, chatID: 2), "media identities scoped to destination")
        var cycleLocal = CloudIndex(folders: [folder, nested])
        cycleLocal.folders[0].parentID = nested.id
        cycleLocal.folders[1].parentID = nil
        cycleLocal.folders[0].modifiedAt = Date().addingTimeInterval(90)
        let cycleMerged = CatalogCodec.merge(snapshot, into: cycleLocal, accountID: 99)
        try CatalogCodec.validate(CatalogSnapshot(revision: 1, createdAt: Date(), folders: cycleMerged.folders, files: cycleMerged.files, tags: cycleMerged.tags))
        check(true, "merge repairs cycle spanning independently valid states")
        try testOutbox()
        try testUploadPolicy()
        try testDeletionQueue()
        try testChunker()
        try testMusic()
        try testMusicUpgrade()
        print("\(checks) recovery checks passed")
    }

    static func testMusicUpgrade() throws {
        let legacy = Data(#"{"version":1,"playlists":[],"deletedPlaylists":[],"tracks":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(MusicLibrary.self, from: legacy)
        check(decoded.channel == nil, "3.2 music library decodes without a channel or destructive migration")
        let original = QueuedUpload(localPath: "/queue/track.mp3", displayName: "track.mp3", folderID: nil, tagIDs: [], byteSize: 100)
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        payload.removeValue(forKey: "musicDestinationChatID"); payload.removeValue(forKey: "musicDescriptor")
        let oldQueue = try JSONDecoder().decode(QueuedUpload.self, from: JSONSerialization.data(withJSONObject: payload))
        check(oldQueue.musicDestinationChatID == nil && oldQueue.id == original.id, "3.2 queued uploads retain identity and original default destination")
        var queued = original
        queued.musicDestinationChatID = -10077
        queued.musicDescriptor = NativeMediaUploadDescriptor(kind: "audio", width: 0, height: 0, duration: 120, title: "Titel", performer: "RJ")
        let queueRoundTrip = try JSONDecoder().decode(QueuedUpload.self, from: JSONEncoder().encode(queued))
        check(queueRoundTrip == queued, "music channel and native audio tags survive interrupted queue staging")
        var library = decoded
        library.channel = MusicChannelChoice(chatID: -10077, title: "Musik", updatedAt: 10)
        let id = UUID()
        library.playlists = [MusicPlaylist(name: "Bleibt erhalten", trackIDs: [id])]
        var changed = library
        changed.channel = MusicChannelChoice(chatID: -10088, title: "Neu", updatedAt: 20)
        check(changed.merging(library).channel?.chatID == -10088, "stale snapshot cannot undo a newer channel choice")
        changed.channel = MusicChannelChoice(chatID: nil, title: "Deaktiviert", updatedAt: 30)
        let merged = library.merging(changed)
        check(merged.channel?.chatID == nil && merged.playlists == library.playlists, "disabling music channel keeps playlists and wins over stale selection")
        let file = CloudFileEntry(id: id, name: "Titel.mp3", totalSize: 100,
            createdAt: Date(timeIntervalSince1970: 1000), modifiedAt: Date(timeIntervalSince1970: 1001),
            chunks: [CloudChunk(index: 1, count: 1, telegramMessageID: 1 << 20, telegramFileID: nil, remoteUniqueID: nil, size: 100, storedName: "Titel.mp3")],
            mimeType: "audio/mpeg", telegramChatID: -10077, storageKind: "nativeAudio")
        let snapshot = CatalogSnapshot(revision: 1, createdAt: Date(), folders: [], files: [file], tags: [], recovery: RecoveryMetadata(accountID: 99, music: merged))
        let restored = try CatalogCodec.decode(CatalogCodec.encode(snapshot), accountID: 99)
        check(restored.files[0] == file && restored.recovery?.music?.playlists == library.playlists,
            "channel switch archive retains exact original audio message, file and playlist references")
        let descriptor = try JSONDecoder().decode(NativeMediaUploadDescriptor.self, from: Data(#"{"kind":"video","width":1920,"height":1080,"duration":2}"#.utf8))
        check(descriptor.title == nil && descriptor.kind == "video", "existing photo/video descriptors decode unchanged")
        check(!DestructiveConfirmation.matches("", phrase: DestructiveConfirmation.reset), "empty confirmation cannot reset session")
        check(!DestructiveConfirmation.matches("ABMELDEN ", phrase: DestructiveConfirmation.logout), "logout requires the exact phrase")
        check(!DestructiveConfirmation.matches("Ich möchte", phrase: DestructiveConfirmation.files), "partial sentence cannot delete Telegram files")
        check(DestructiveConfirmation.matches(DestructiveConfirmation.files, phrase: DestructiveConfirmation.files), "complete deliberate deletion sentence is accepted")
    }

    static func testMusic() throws {
        let first = UUID(), second = UUID(), missing = UUID()
        var playlist = MusicPlaylist(name: "Unterwegs")
        playlist.edit(tracks: [first, second, first, missing])
        check(playlist.trackIDs == [first, second, missing], "playlist deduplicates without changing user order or dropping unavailable references")
        var localMusic = MusicLibrary(playlists: [playlist], tracks: [first: MusicTrackInfo(title: "Ein Titel", artist: "Künstler", album: "Album", duration: 125)])
        let old = localMusic
        playlist.edit(tracks: [second, first])
        localMusic.playlists = [playlist]
        check(localMusic.merging(old).playlists[0].trackIDs == [second, first], "stale snapshot cannot undo track removal and reorder")
        check(old.merging(localMusic).playlists == localMusic.merging(old).playlists, "playlist merge converges independently of merge direction")
        var deleted = localMusic
        deleted.deletedPlaylists[playlist.id] = Date().timeIntervalSince1970
        deleted.playlists = []
        check(deleted.merging(old).playlists.isEmpty, "deleted playlist cannot return from old Telegram catalog")
        var local = CloudIndex()
        local.recovery = RecoveryMetadata(accountID: 99, music: localMusic)
        let oldSnapshot = CatalogSnapshot(revision: 1, createdAt: Date(), folders: [], files: [], tags: [], recovery: RecoveryMetadata(accountID: 99))
        check(CatalogCodec.merge(oldSnapshot, into: local, accountID: 99).recovery?.music == localMusic, "v3.1 catalog import preserves v3.2 music state")
        var musical = oldSnapshot; musical.recovery?.music = localMusic
        let archive = try CatalogCodec.encode(musical)
        let restored = try CatalogCodec.decode(archive, accountID: 99)
        check(restored.recovery?.music == localMusic, "playlists order metadata and precise edit times survive compressed Telegram archive")
        rejects("music catalog cannot be imported into different account") { _ = try CatalogCodec.decode(archive, accountID: 100) }
        var corrupt = musical; corrupt.recovery?.music?.playlists.append(playlist)
        rejects("duplicate playlist IDs rejected safely") { _ = try CatalogCodec.encode(corrupt) }
        corrupt = musical; corrupt.recovery?.music?.version = 999
        rejects("future music format cannot silently overwrite current data") { _ = try CatalogCodec.encode(corrupt) }
        corrupt = musical; corrupt.recovery?.music?.playlists[0].trackIDs = [first, first]
        rejects("corrupt duplicate track references rejected") { _ = try CatalogCodec.encode(corrupt) }
        let legacy = try JSONDecoder().decode(RecoveryMetadata.self, from: JSONEncoder().encode(RecoveryMetadata(accountID: 99)))
        check(legacy.music == nil, "existing recovery metadata upgrades without a destructive migration")
        let map = try MusicRangeMap(sizes: [3, 5], total: 8)
        let a = try map.slice(offset: 2, remaining: 6)
        let b = try map.slice(offset: 3, remaining: 5)
        let end = try map.slice(offset: 8, remaining: 100)
        check(a == MusicRangeMap.Slice(chunk: 0, offset: 2, count: 1), "stream stops read at multipart boundary")
        check(b == MusicRangeMap.Slice(chunk: 1, offset: 0, count: 5), "stream continues at next chunk with local offset zero")
        check(end == nil, "end of audio file finishes without an extra Telegram request")
        let large = try MusicRangeMap(sizes: [4_000_000_000], total: 4_000_000_000)
        let block = try large.slice(offset: 3_000_000_000, remaining: 1_000_000_000)
        check(block?.count == MusicRangeMap.blockSize && block?.offset == 3_000_000_000, "4GB audio offsets remain 64-bit while reads stay bounded")
        rejects("negative audio range rejected") { _ = try map.slice(offset: -1, remaining: 1) }
        rejects("incomplete audio layout rejected") { _ = try MusicRangeMap(sizes: [3, 4], total: 8) }
        rejects("overflowing audio layout rejected") { _ = try MusicRangeMap(sizes: [Int64.max, 1], total: 8) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 3, 4, 5]).write(to: root)
        let bytes = try MusicRangeMap.verifiedRead(path: root.path, offset: 2, count: 3, downloadedPrefix: 3)
        check(bytes == Data([2, 3, 4]), "verified stream returns the requested bytes only")
        rejects("sparse or interrupted download cannot expose unverified audio bytes") {
            _ = try MusicRangeMap.verifiedRead(path: root.path, offset: 2, count: 3, downloadedPrefix: 1)
        }
        rejects("truncated local audio read fails rather than reporting successful EOF") {
            _ = try MusicRangeMap.verifiedRead(path: root.path, offset: 5, count: 3, downloadedPrefix: 3)
        }
        var queue = MusicQueue(ids: [first, second])
        check(queue.advance() == second && queue.advance() == nil, "queue stops at end with repeat disabled")
        queue.repeatMode = .all
        check(queue.advance() == first, "repeat all wraps to the first title")
        queue.repeatMode = .one
        check(queue.advance() == first && queue.advance(manual: true) == second, "repeat one repeats naturally but manual next skips")
        check(MusicQueue().current == nil, "empty restored queue cannot crash")
    }

    static func tryDecode(_ data: Data) -> CatalogSnapshot? { try? CatalogCodec.decode(data, accountID: 99) }

    static func testOutbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = DurableOutbox.token(fileID: UUID(), part: 1, kind: "photo")
        let message: [String: Any] = ["@type": "message", "id": Int64(1 << 20), "chat_id": Int64(99),
                                      "content": ["caption": ["text": operation]]]
        let payload: [String: Any] = ["@type": "sendMessage", "chat_id": Int64(99)]
        var sends = 0
        var serverHasMessage = false
        var searchError = false
        let request: DurableOutbox.Transport = { request, reply in
            if request["@type"] as? String == "getMessage" { reply(serverHasMessage ? message : DurableOutbox.error("offline")); return }
            if searchError { reply(DurableOutbox.error("offline")); return }
            reply(["@type": "foundChatMessages", "messages": serverHasMessage ? [message] : []])
        }
        let send: DurableOutbox.Transport = { _, _ in sends += 1 } // Process dies without a reply.
        let first = DurableOutbox(root: root, request: request, sendFinal: send)
        first.send(payload, operation: operation) { _ in }
        check(sends == 1, "first operation writes intent and sends once")
        var reply: [String: Any] = [:]
        first.send(payload, operation: operation) { reply = $0 }
        check(sends == 1 && reply["@type"] as? String == "error", "concurrent duplicate operation blocked")
        let restart = DurableOutbox(root: root, request: request, sendFinal: send)
        restart.send(payload, operation: operation) { reply = $0 }
        check(sends == 1 && reply["@type"] as? String == "error", "crash without confirmation never blindly resends")
        serverHasMessage = true
        restart.send(payload, operation: operation) { reply = $0 }
        check(sends == 1 && DurableOutbox.isFinal(reply), "server delivery after crash recovered from marker")
        let confirmedRestart = DurableOutbox(root: root, request: request, sendFinal: send)
        confirmedRestart.send(payload, operation: operation) { reply = $0 }
        check(sends == 1 && DurableOutbox.isFinal(reply), "confirmed receipt survives process restart")
        serverHasMessage = false
        confirmedRestart.send(payload, operation: operation) { reply = $0 }
        check(sends == 1 && reply["@type"] as? String == "error", "unreachable confirmed message does not trigger duplicate")
        searchError = true
        let fresh = DurableOutbox(root: root, request: request, sendFinal: send)
        fresh.send(payload, operation: "another") { reply = $0 }
        check(sends == 1, "failed recovery search blocks network send")
        searchError = false
        serverHasMessage = true
        let reinstall = DurableOutbox(root: root.appendingPathComponent("new-install"), request: request, sendFinal: send)
        reinstall.send(payload, operation: operation) { reply = $0 }
        check(sends == 1 && DurableOutbox.isFinal(reply), "fresh install recognizes remote operation token")
        serverHasMessage = false
        let fileRoot = root.appendingPathComponent("file-not-directory")
        try Data("blocked".utf8).write(to: fileRoot)
        let unwritable = DurableOutbox(root: fileRoot, request: request, sendFinal: send)
        unwritable.send(payload, operation: "disk-full") { reply = $0 }
        check(sends == 1 && reply["@type"] as? String == "error", "journal persistence failure blocks send")
        var attempts = 0
        let rejected = DurableOutbox(root: root.appendingPathComponent("rejected"), request: request, sendFinal: { _, reply in
            attempts += 1
            reply(["@type": "error", "code": 429, "message": "FLOOD_WAIT_1"])
        })
        rejected.send(payload, operation: "rejected") { _ in }
        rejected.send(payload, operation: "rejected") { _ in }
        check(attempts == 2, "explicit Telegram rejection can safely retry")
        var uncertainAttempts = 0
        let uncertain = DurableOutbox(root: root.appendingPathComponent("uncertain"), request: request, sendFinal: { _, reply in
            uncertainAttempts += 1
            reply(["@type": "error", "code": 500, "message": "timeout"])
        })
        uncertain.send(payload, operation: "uncertain") { _ in }
        uncertain.send(payload, operation: "uncertain") { _ in }
        check(uncertainAttempts == 1, "uncertain server error never starts a second send")
    }

    static func testUploadPolicy() throws {
        var policy = UploadPolicy()
        check(policy.bytes() == 2_000_000_000, "unknown Premium status uses safe standard limit")
        policy.isPremium = true
        check(policy.bytes() == 4_000_000_000, "confirmed Premium enables 4 GB")
        check(policy.bytes(usePremium: false) == 2_000_000_000, "user can retain standard-size parts on Premium")
        policy.applyConfiguration(["@type": "jsonValueObject", "value": [
            ["key": "upload_max_fileparts_premium", "value": ["@type": "jsonValueNumber", "value": 7000.0]]
        ]])
        check(policy.bytes() == 7000 * 524_288, "lower server configuration overrides advertised Premium limit")
        policy.applyConfiguration(["@type": "jsonValueObject", "value": [
            ["key": "upload_max_fileparts_premium", "value": ["@type": "jsonValueNumber", "value": Double.infinity]],
            ["key": "upload_max_fileparts_default", "value": ["@type": "jsonValueNumber", "value": -1.0]]
        ]])
        check(policy.bytes() == 7000 * 524_288 && policy.bytes(usePremium: false) == 2_000_000_000, "malformed limits cannot overflow or increase allowance")
        policy.isPremium = false
        check(policy.bytes() == 2_000_000_000, "Premium expiration updates allowance")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = DurableOutbox(root: root, request: { _, _ in }, sendFinal: { _, _ in })
        let id = UUID()
        let original = try outbox.uploadLayout(fileID: id, chatID: 99, total: 5_000_000_000, limit: 4_000_000_000, nativeKind: nil, partial: nil)
        let restarted = try outbox.uploadLayout(fileID: id, chatID: 99, total: 5_000_000_000, limit: 2_000_000_000, nativeKind: nil, partial: nil)
        check(original == restarted, "restart and Premium change preserve existing part boundaries")
        rejects("changed source size cannot reuse upload layout") { _ = try outbox.uploadLayout(fileID: id, chatID: 99, total: 123, limit: 2_000_000_000, nativeKind: nil, partial: nil) }
        let oldID = UUID(), op = DurableOutbox.token(fileID: oldID, part: 1, kind: "document")
        let receipt = DurableOutbox.Receipt(operation: op, chatID: 99, phase: .pending, temporaryID: -1)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(CatalogCodec.digest(Data(op.utf8)) + ".json"))
        let migrated = try outbox.uploadLayout(fileID: oldID, chatID: 99, total: 5_000_000_000, limit: 4_000_000_000, nativeKind: "video", partial: nil)
        check(migrated.chunkBytes == 1_900_000_000 && migrated.nativeKind == nil, "legacy send receipts preserve v3.0 layout")
        let partial = CloudFileEntry(name: "large.zip", totalSize: 5_000_000_000, chunks: [CloudChunk(index: 1, count: 2, telegramMessageID: 1, telegramFileID: nil, remoteUniqueID: nil, size: 4_000_000_000, storedName: "part")], telegramChatID: 99)
        let restored = try outbox.uploadLayout(fileID: partial.id, chatID: 99, total: partial.totalSize, limit: 2_000_000_000, nativeKind: nil, partial: partial)
        check(restored.chunkBytes == 4_000_000_000, "reinstall recovers part boundaries from Telegram metadata")
        var index = CloudIndex()
        let key = CatalogCodec.resourceIdentity(sourceKey: "asset|1|a.jpg", accountID: 99, destination: -7)
        index.recovery = RecoveryMetadata(accountID: 99, excludedPhotoResources: [key: Date()])
        let snapshot = CatalogSnapshot(revision: 1, createdAt: Date(), folders: [], files: [], tags: [], recovery: index.recovery)
        let decoded = try CatalogCodec.decode(CatalogCodec.encode(snapshot), accountID: 99)
        check(CatalogCodec.merge(decoded, into: CloudIndex(), accountID: 99).recovery?.excludedPhotoResources?[key] != nil, "intentional photo exclusions survive catalog export and reinstall")
    }

    static func testDeletionQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chunks = (1...205).map { CloudChunk(index: $0, count: 205, telegramMessageID: Int64($0), telegramFileID: nil, remoteUniqueID: nil, size: 1, storedName: "part") }
        let file = CloudFileEntry(name: "archive.zip", totalSize: 205, chunks: chunks, telegramChatID: -7)
        var scheduled: [() -> Void] = []
        let schedule: DurableDeletionQueue.Scheduler = { _, action in scheduled.append(action) }
        func drain() { var i = 0; while !scheduled.isEmpty { i += 1; precondition(i < 100); scheduled.removeFirst()() } }
        var batches: [[Int64]] = [], committed = 0, seenError: String?
        let first = DurableDeletionQueue(root: root, request: { payload, done in
            batches.append(payload["message_ids"] as! [Int64]); done(["@type": "ok"])
        }, commit: { _, _ in committed += 1; return true }, changed: { _, _, _, error in seenError = error }, schedule: schedule)
        first.resume(account: 99, adding: [file, file])
        check(batches.count == 1 && batches[0].count == 100 && committed == 0, "bulk deletion deduplicates and starts only one bounded request")
        first.pause() // Simulated process interruption after the first confirmed batch.
        drain()
        let restart = DurableDeletionQueue(root: root, request: { payload, done in
            batches.append(payload["message_ids"] as! [Int64]); done(["@type": "ok"])
        }, commit: { _, _ in committed += 1; return true }, changed: { _, _, _, error in seenError = error }, schedule: schedule)
        restart.resume(account: 99); drain()
        check(batches.map(\.count) == [100, 100, 5] && committed == 1, "deletion restart resumes remaining IDs and commits only after all batches")
        let other = DurableDeletionQueue(root: root, request: { _, _ in fatalError("wrong-account deletion") }, commit: { _, _ in false }, changed: { _, _, _, _ in }, schedule: schedule)
        other.resume(account: 100); drain()
        check(true, "deletion jobs isolated by Telegram account")
        var delayed: DurableOutbox.Reply?
        let stale = DurableDeletionQueue(root: root.appendingPathComponent("stale"), request: { _, reply in delayed = reply }, commit: { _, _ in committed += 1; return true }, changed: { _, _, _, _ in }, schedule: schedule)
        stale.resume(account: 99, adding: [file]); stale.pause(); delayed?(["@type": "ok"]); drain()
        check(committed == 1, "late delete callback after logout cannot mutate catalog")
        var calls = 0
        let retry = DurableDeletionQueue(root: root.appendingPathComponent("retry"), request: { _, done in
            calls += 1; done(calls == 1 ? ["@type": "error", "code": 429, "message": "FLOOD_WAIT_2"] : ["@type": "ok"])
        }, commit: { _, _ in true }, changed: { _, _, _, _ in }, schedule: schedule)
        retry.resume(account: 99, adding: [file]); drain()
        check(calls == 4, "Telegram flood wait retries the same delete batch serially")
        var deniedCommit = false
        let denied = DurableDeletionQueue(root: root.appendingPathComponent("denied"), request: { _, done in done(["@type": "error", "code": 403, "message": "CHAT_ADMIN_REQUIRED"]) }, commit: { _, _ in deniedCommit = true; return true }, changed: { _, _, _, error in seenError = error }, schedule: schedule)
        denied.resume(account: 99, adding: [file]); drain()
        check(!deniedCommit && seenError != nil, "permission failure preserves catalog and exposes retry state")
        let blocked = root.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let disk = DurableDeletionQueue(root: blocked, request: { _, _ in fatalError("delete before durable intent") }, commit: { _, _ in false }, changed: { _, _, _, error in seenError = error }, schedule: schedule)
        disk.resume(account: 99, adding: [file]); drain()
        check(seenError != nil, "unwritable delete journal blocks destructive request")
        var allowCommit = false, finalCalls = 0
        let tiny = CloudFileEntry(name: "tiny", totalSize: 1, chunks: [chunks[0]], telegramChatID: -7)
        let finalize = DurableDeletionQueue(root: root.appendingPathComponent("finalize"), request: { _, done in finalCalls += 1; done(["@type": "ok"]) }, commit: { _, _ in allowCommit }, changed: { _, _, _, _ in }, schedule: schedule)
        finalize.resume(account: 99, adding: [tiny]); drain(); allowCommit = true
        finalize.resume(account: 99); drain()
        check(finalCalls == 1, "catalog write retry does not repeat a confirmed deletion")
        var timeoutReply: DurableOutbox.Reply?, timeoutCommitted = false
        let timeout = DurableDeletionQueue(root: root.appendingPathComponent("timeout"), request: { _, reply in timeoutReply = reply }, commit: { _, _ in timeoutCommitted = true; return true }, changed: { _, _, _, error in seenError = error }, schedule: schedule)
        timeout.resume(account: 99, adding: [tiny]); drain()
        timeoutReply?(["@type": "ok"]); drain()
        check(seenError != nil && !timeoutCommitted, "missing delete response times out safely and ignores late callback")
    }

    static func testChunker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let bytes = Data((0..<30).map(UInt8.init))
        try bytes.write(to: source)
        let prepared = try FileChunker.prepare(source: source, maxChunkBytes: 10) { _, _ in }
        defer { FileChunker.cleanup(prepared) }
        check(prepared.chunks.map(\.size) == [10, 10, 10], "exact split boundary never creates an extra empty part")
        let target = root.appendingPathComponent("joined.bin")
        try FileChunker.join(chunks: prepared.chunks.map(\.url), destination: target) { _ in }
        let joined = try Data(contentsOf: target)
        check(joined == bytes, "chunked download reconstructs byte-identical original")
        rejects("source truncation during split cannot produce a false complete backup") {
            _ = try FileChunker.prepare(source: source, maxChunkBytes: 10) { completed, _ in
                if completed == 10 { try? Data().write(to: source, options: []) }
            }
        }
    }
}

