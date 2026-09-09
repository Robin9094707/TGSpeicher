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
        rejects("cross-account import rejected") { _ = try CatalogCodec.decode(packed, accountID: 100) }
        var json = try JSONSerialization.jsonObject(with: packed) as! [String: Any]
        json["sha256"] = "bad"
        let tampered = try JSONSerialization.data(withJSONObject: json)
        rejects("corrupt checksum rejected") { _ = try CatalogCodec.decode(tampered, accountID: 99) }
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
        let hash = CatalogCodec.digest(Data("original media".utf8))
        check(CatalogCodec.stableMediaID(hash: hash, chatID: 1) == CatalogCodec.stableMediaID(hash: hash, chatID: 1), "media identity stable across queue recreation")
        check(CatalogCodec.stableMediaID(hash: hash, chatID: 1) != CatalogCodec.stableMediaID(hash: hash, chatID: 2), "media identities scoped to destination")
        try testOutbox()
        print("\(checks) recovery checks passed")
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
    }
}
