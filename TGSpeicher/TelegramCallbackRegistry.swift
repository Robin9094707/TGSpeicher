import Foundation

/// Completes requests exactly once on their chosen queue, including timeouts and logout.
/// AVFoundation range reads must be able to complete while the main queue is busy.
final class TelegramCallbackRegistry {
    private struct Pending {
        let queue: DispatchQueue
        let completion: ([String: Any]) -> Void
        let timeout: DispatchWorkItem?

        func deliver(_ response: [String: Any]) {
            timeout?.cancel()
            queue.async { self.completion(response) }
        }
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func insert(queue: DispatchQueue = .main, timeout: TimeInterval? = nil,
                completion: @escaping ([String: Any]) -> Void) -> String {
        let token = UUID().uuidString
        let work: DispatchWorkItem? = timeout.map { _ in
            DispatchWorkItem { [weak self] in
                _ = self?.resolve(token, response: ["@type": "error", "code": 408,
                    "message": "Telegram antwortet gerade nicht. Bitte erneut versuchen."])
            }
        }
        lock.lock()
        pending[token] = Pending(queue: queue, completion: completion, timeout: work)
        lock.unlock()
        if let timeout, let work {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout), execute: work)
        }
        return token
    }

    @discardableResult
    func resolve(_ token: String, response: [String: Any]) -> Bool {
        lock.lock(); let callback = pending.removeValue(forKey: token); lock.unlock()
        callback?.deliver(response)
        return callback != nil
    }

    func cancelAll() {
        lock.lock(); let callbacks = Array(pending.values); pending.removeAll(); lock.unlock()
        let response: [String: Any] = ["@type": "error", "code": 499, "message": "Die Telegram-Sitzung wurde beendet."]
        callbacks.forEach { $0.deliver(response) }
    }
}
