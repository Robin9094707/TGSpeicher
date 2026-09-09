import Foundation

/// Each receipt is committed before the network side effect. An uncertain send is
/// reconciled, never automatically replaced by a second sendMessage request.
final class DurableOutbox {
    struct Receipt: Codable {
        enum Phase: String, Codable { case intent, pending, confirmed, rejected }
        var operation: String
        var chatID: Int64
        var phase: Phase
        var temporaryID: Int64?
        var messageID: Int64?
    }

    typealias Reply = ([String: Any]) -> Void
    typealias Transport = ([String: Any], @escaping Reply) -> Void
    let root: URL
    let request: Transport
    let sendFinal: Transport
    private var active = Set<String>()

    init(root: URL, request: @escaping Transport, sendFinal: @escaping Transport) {
        self.root = root
        self.request = request
        self.sendFinal = sendFinal
    }

    static func token(fileID: UUID, part: Int, kind: String) -> String {
        "TGSOP" + CatalogCodec.digest(Data("\(fileID.uuidString)|\(part)|\(kind)".utf8))
    }

    func send(_ payload: [String: Any], operation: String, completion: @escaping Reply) {
        guard active.insert(operation).inserted else {
            completion(Self.error("Dieser Sendevorgang wird bereits geprüft.")); return
        }
        let done: Reply = { [weak self] response in
            self?.active.remove(operation)
            completion(response)
        }
        guard let chat = (payload["chat_id"] as? NSNumber)?.int64Value else {
            done(Self.error("Das Telegram-Ziel fehlt.")); return
        }
        let receipt: Receipt?
        do { receipt = try load(operation) }
        catch { done(Self.error("Das Upload-Protokoll ist beschädigt. Kein erneuter Upload wurde gestartet.")); return }

        if let receipt, receipt.chatID != chat {
            done(Self.error("Das Upload-Protokoll gehört zu einem anderen Kanal.")); return
        }
        if let receipt, receipt.phase == .confirmed, let id = receipt.messageID {
            request(["@type": "getMessage", "chat_id": chat, "message_id": id]) { response in
                if Self.isFinal(response) { done(response) }
                else { done(Self.error("Die gespeicherte Telegram-Nachricht ist gerade nicht erreichbar. Bitte später erneut prüfen.")) }
            }
            return
        }

        // Search also covers reinstalls that lost the local receipt. The token is
        // plain caption text, because Telegram cannot search inside base64 JSON.
        request(["@type": "searchChatMessages", "chat_id": chat, "topic_id": NSNull(),
                 "query": operation, "sender_id": NSNull(), "from_message_id": 0,
                 "offset": 0, "limit": 100, "filter": NSNull()]) { [weak self] response in
            guard let self else { return }
            guard response["@type"] as? String != "error",
                  let messages = response["messages"] as? [[String: Any]] else {
                done(Self.error("Telegram konnte den bisherigen Upload nicht prüfen. Er wird nicht erneut gesendet.")); return
            }
            if let found = messages.first(where: { Self.isFinal($0) && Self.caption($0).contains(operation) }) {
                self.confirm(found, operation: operation, chat: chat, done: done)
                return
            }
            if let receipt, receipt.phase != .rejected {
                // TDLib may still be sending the old message after a restart.
                if let id = receipt.temporaryID {
                    self.request(["@type": "getMessage", "chat_id": chat, "message_id": id]) { message in
                        if Self.isFinal(message) {
                            self.confirm(message, operation: operation, chat: chat, done: done)
                        } else { done(Self.uncertain) }
                    }
                } else { done(Self.uncertain) }
                return
            }
            do {
                try self.write(Receipt(operation: operation, chatID: chat, phase: .intent))
            } catch {
                done(Self.error("Das Upload-Protokoll konnte nicht gespeichert werden. Bitte freien Speicher prüfen.")); return
            }
            self.sendFinal(payload) { result in
                if Self.isFinal(result) {
                    self.confirm(result, operation: operation, chat: chat, done: done)
                } else {
                    // Explicit validation / flood errors mean Telegram rejected this
                    // attempt. Other errors leave the outcome uncertain.
                    let code = (result["code"] as? NSNumber)?.intValue ?? 0
                    if code == 400 || code == 429 {
                        do { try self.write(Receipt(operation: operation, chatID: chat, phase: .rejected)) }
                        catch { done(Self.uncertain); return }
                    }
                    done(result)
                }
            }
        }
    }

    func notePending(operation: String, chatID: Int64, temporaryID: Int64) throws {
        guard var receipt = try load(operation), receipt.phase != .confirmed else { return }
        receipt.phase = .pending
        receipt.temporaryID = temporaryID
        try write(receipt)
    }

    private func confirm(_ message: [String: Any], operation: String, chat: Int64, done: Reply) {
        do {
            try write(Receipt(operation: operation, chatID: chat, phase: .confirmed,
                              messageID: (message["id"] as? NSNumber)?.int64Value))
            done(message)
        } catch { done(Self.error("Telegram hat die Datei erhalten, aber das Protokoll konnte nicht gespeichert werden. Beim nächsten Versuch wird nur nach der Nachricht gesucht.")) }
    }

    private func url(_ operation: String) -> URL {
        root.appendingPathComponent(CatalogCodec.digest(Data(operation.utf8)) + ".json")
    }
    func load(_ operation: String) throws -> Receipt? {
        let path = url(operation)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: path))
    }
    private func write(_ receipt: Receipt) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: url(receipt.operation), options: [.atomic])
    }
    static func caption(_ message: [String: Any]) -> String {
        let content = message["content"] as? [String: Any] ?? [:]
        return ((content["caption"] ?? content["text"]) as? [String: Any])?["text"] as? String ?? ""
    }
    static func isFinal(_ message: [String: Any]) -> Bool {
        message["@type"] as? String == "message"
            && ((message["id"] as? NSNumber)?.int64Value ?? 0) > 0
            && (message["sending_state"] == nil || message["sending_state"] is NSNull)
    }
    static func error(_ text: String) -> [String: Any] { ["@type": "error", "code": -32001, "message": text] }
    static var uncertain: [String: Any] {
        error("Sendeausgang noch unklar. Der Upload bleibt angehalten, damit keine Kopie entsteht. Bitte den Katalog aktualisieren und anschließend erneut prüfen.")
    }
}
