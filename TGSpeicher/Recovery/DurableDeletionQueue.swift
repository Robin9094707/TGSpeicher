import Foundation

/// One request at a time; a durable remaining-ID list survives partial success and restart.
final class DurableDeletionQueue {
    struct Job: Codable {
        var file: CloudFileEntry
        var chatID: Int64
        var remaining: [Int64]
    }
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    let root: URL
    let request: DurableOutbox.Transport
    let commit: (CloudFileEntry, Int64) -> Bool
    let changed: (Set<UUID>, Bool, String, String?) -> Void
    let schedule: Scheduler
    private var accountID: Int64?
    private var jobs: [Job] = []
    private var running = false
    private var generation = UUID()
    private var floodAttempts = 0

    init(root: URL, request: @escaping DurableOutbox.Transport,
         commit: @escaping (CloudFileEntry, Int64) -> Bool,
         changed: @escaping (Set<UUID>, Bool, String, String?) -> Void,
         schedule: @escaping Scheduler = { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }) {
        self.root = root; self.request = request; self.commit = commit
        self.changed = changed; self.schedule = schedule
    }

    func pause() {
        generation = UUID(); running = false; accountID = nil; jobs = []
        changed([], false, "", nil)
    }

    func resume(account: Int64, adding files: [CloudFileEntry] = []) {
        if accountID != account {
            pause(); accountID = account
            do {
                let path = url(account)
                jobs = FileManager.default.fileExists(atPath: path.path)
                    ? try JSONDecoder().decode([Job].self, from: Data(contentsOf: path)) : []
                guard Set(jobs.map { $0.file.id }).count == jobs.count,
                      jobs.allSatisfy({ $0.remaining.allSatisfy { $0 > 0 } && $0.chatID != 0 }) else {
                    throw RecoveryError.invalid("Das Löschprotokoll enthält ungültige Einträge.")
                }
            } catch { fail("Das Löschprotokoll konnte nicht gelesen werden: \(error.localizedDescription)"); accountID = nil; return }
        }
        do {
            for file in files where !jobs.contains(where: { $0.file.id == file.id }) {
                jobs.append(Job(file: file, chatID: file.telegramChatID ?? account,
                                remaining: Array(Set(file.chunks.compactMap(\.telegramMessageID).filter { $0 > 0 })).sorted()))
            }
            try persist()
        } catch { fail("Der Löschauftrag konnte nicht gespeichert werden: \(error.localizedDescription)"); return }
        guard !running else { publish(); return }
        floodAttempts = 0; running = true; publish(); next()
    }

    private func next() {
        guard running, let account = accountID else { return }
        guard let job = jobs.first else { running = false; changed([], false, "Löschen abgeschlossen", nil); return }
        publish()
        let run = generation
        if job.remaining.isEmpty {
            guard commit(job.file, account) else { fail("Telegram-Löschung erfolgt; der Katalog konnte noch nicht gespeichert werden. Bitte erneut prüfen."); return }
            // A failed write must keep the job available for another attempt.
            let previous = jobs
            jobs.removeFirst()
            do { try persist() }
            catch { jobs = previous; fail("Der Abschluss konnte nicht gespeichert werden. Bitte erneut prüfen."); return }
            schedule(0) { [weak self] in guard let self, self.generation == run else { return }; self.next() }
            return
        }
        let batch = Array(job.remaining.prefix(100))
        request(["@type": "deleteMessages", "chat_id": job.chatID, "message_ids": batch, "revoke": true]) { [weak self] response in
            guard let self, self.generation == run, self.accountID == account else { return }
            if response["@type"] as? String == "ok" {
                let previous = self.jobs
                self.jobs[0].remaining.removeFirst(batch.count)
                do { try self.persist() }
                catch { self.jobs = previous; self.fail("Der Löschfortschritt konnte nicht gespeichert werden. Bitte erneut prüfen."); return }
                self.floodAttempts = 0
                self.schedule(0) { [weak self] in guard let self, self.generation == run else { return }; self.next() }
            } else if (response["code"] as? NSNumber)?.intValue == 429, self.floodAttempts < 3 {
                self.floodAttempts += 1
                let raw = response["message"] as? String ?? ""
                let digits = raw.range(of: #"\d+"#, options: .regularExpression).flatMap { Int(raw[$0]) }
                let wait = min(3600, max(1, digits ?? 30))
                self.changed(Set(self.jobs.map { $0.file.id }), true, "Telegram-Pause: \(wait) Sekunden", nil)
                self.schedule(Double(wait + 1)) { [weak self] in guard let self, self.generation == run else { return }; self.next() }
            } else {
                let raw = (response["message"] as? String ?? "Keine eindeutige Bestätigung erhalten.").replacingOccurrences(of: "_", with: " ")
                self.fail("„\(job.file.name)“ konnte noch nicht vollständig gelöscht werden: \(raw)")
            }
        }
    }

    private func publish() { changed(Set(jobs.map { $0.file.id }), running, "\(jobs.count) Datei(en) werden gelöscht …", nil) }
    private func fail(_ message: String) { running = false; changed(Set(jobs.map { $0.file.id }), false, "Löschen angehalten", message) }
    private func url(_ account: Int64) -> URL { root.appendingPathComponent("\(account).json") }
    private func persist() throws {
        guard let account = accountID else { throw RecoveryError.invalid("Das Telegram-Konto fehlt.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: url(account), options: [.atomic])
    }
}
