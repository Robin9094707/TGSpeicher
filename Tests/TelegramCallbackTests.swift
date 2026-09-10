import Foundation

@main
struct TelegramCallbackTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        print("PASS: \(message)")
    }

    static func main() {
        let callbacks = TelegramCallbackRegistry()
        let audio = DispatchQueue(label: "test.audio")
        let key = DispatchSpecificKey<String>()
        audio.setSpecific(key: key, value: "audio")
        let received = DispatchSemaphore(value: 0)
        let token = callbacks.insert(queue: audio) { response in
            precondition(DispatchQueue.getSpecific(key: key) == "audio")
            precondition(response["value"] as? Int == 42)
            received.signal()
        }
        require(callbacks.resolve(token, response: ["value": 42]), "response accepted")
        // Deliberately do not run the main run loop: audio still has to complete.
        require(received.wait(timeout: .now() + 3) == .success, "audio callback completes with main thread blocked")
        require(!callbacks.resolve(token, response: [:]), "duplicate response ignored")

        let expired = DispatchSemaphore(value: 0)
        let timed = callbacks.insert(queue: audio, timeout: 0.02) { response in
            precondition(response["code"] as? Int == 408)
            expired.signal()
        }
        require(expired.wait(timeout: .now() + 3) == .success, "lost response times out")
        require(callbacks.count == 0, "timeout releases pending callback")
        require(!callbacks.resolve(timed, response: [:]), "late response after timeout ignored")

        let cancelled = DispatchSemaphore(value: 0)
        let closing = callbacks.insert(queue: audio, timeout: 10) { response in
            precondition(response["code"] as? Int == 499)
            cancelled.signal()
        }
        callbacks.cancelAll()
        require(cancelled.wait(timeout: .now() + 3) == .success, "logout resumes pending request")
        require(!callbacks.resolve(closing, response: [:]), "late response after logout ignored")

        let once = DispatchSemaphore(value: 0)
        let raced = callbacks.insert(queue: audio) { _ in once.signal() }
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            callbacks.resolve(raced, response: ["@type": "ok"])
        }
        require(once.wait(timeout: .now() + 3) == .success, "concurrent responses deliver once")
        require(once.wait(timeout: .now() + 0.05) == .timedOut, "no duplicate completion after response race")
        require(callbacks.count == 0, "all callbacks released")
    }
}
