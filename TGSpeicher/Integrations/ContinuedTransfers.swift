import BackgroundTasks
import UIKit

extension Notification.Name {
    static let transferUserRequested = Notification.Name("TGSpeicher.transferUserRequested")
    static let transferRuntimeExpired = Notification.Name("TGSpeicher.transferRuntimeExpired")
}

/// Explicit user actions request runtime; restored/automatic backups never submit it.
@MainActor
final class ContinuedTransfers {
    static let shared = ContinuedTransfers()
    private var registered = false
    private var pending = false
    private var storedTask: AnyObject?
    private var completedBeforeCurrent: Int64 = 0
    private var previousID: UUID?
    private var previousBytes: Int64 = 0
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "eu.simplexsmp.tgspeicher") + ".transfer" }

    func start() {
        NotificationCenter.default.post(name: .transferUserRequested, object: nil)
        guard #available(iOS 26.0, *), !pending, storedTask == nil,
              UIApplication.shared.applicationState == .active else { return }
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in
                    let owner = ContinuedTransfers.shared
                    guard owner.pending else { task.setTaskCompleted(success: false); return }
                    owner.pending = false; owner.storedTask = task
                    owner.completedBeforeCurrent = 0; owner.previousID = nil; owner.previousBytes = 0
                    task.progress.totalUnitCount = 1; task.progress.completedUnitCount = 0
                    task.expirationHandler = { [weak owner] in
                        Task { @MainActor in
                            NotificationCenter.default.post(name: .transferRuntimeExpired, object: nil)
                            owner?.finish(success: false)
                        }
                    }
                }
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: "TGSpeicher Upload", subtitle: "Dateien werden in Telegram gesichert")
        request.strategy = .fail
        do { pending = true; try BGTaskScheduler.shared.submit(request) }
        catch { pending = false } // Older/sideloaded/unsupported devices retain the normal foreground path.
    }
    func update(id: UUID?, bytes: Int64, total: Int64, queued: Int) {
        guard #available(iOS 26.0, *), let task = storedTask as? BGContinuedProcessingTask else { return }
        if previousID != id { completedBeforeCurrent += previousBytes; previousBytes = 0; previousID = id }
        previousBytes = max(previousBytes, max(0, bytes))
        let completed = completedBeforeCurrent + previousBytes
        task.progress.totalUnitCount = max(completed + 1, completedBeforeCurrent + max(1, total) + Int64(max(0, queued)))
        task.progress.completedUnitCount = completed
    }
    func finish(success: Bool) {
        if #available(iOS 26.0, *) {
            if let task = storedTask as? BGContinuedProcessingTask {
                if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
                task.setTaskCompleted(success: success)
            }
            if pending { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        }
        storedTask = nil; pending = false
    }
}
