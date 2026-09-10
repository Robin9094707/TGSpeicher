import ActivityKit
import UIKit
import Combine

@MainActor
final class TransferActivityController: ObservableObject {
    private let cloud: CloudStore
    private let queue: UploadQueueManager
    private let backup: PhotoBackupManager
    private let telemetry: TelegramTransferTelemetry
    private var subscriptions = Set<AnyCancellable>()
    private var activity: Activity<TransferActivityAttributes>?
    private var lastState: TransferActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast
    private var idleSince: Date?
    private var requested = false
    private var isUpdating = false

    init(cloud: CloudStore, queue: UploadQueueManager, backup: PhotoBackupManager, telemetry: TelegramTransferTelemetry) {
        self.cloud = cloud; self.queue = queue; self.backup = backup; self.telemetry = telemetry
        // A process restart ends stale activities; a new explicit action can start a fresh one.
        Task { for old in Activity<TransferActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) } }
        Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .transferUserRequested).sink { [weak self] _ in
            self?.requested = true; self?.idleSince = nil
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .transferRuntimeExpired).sink { [weak self] _ in
            self?.queue.pause(); self?.backup.pauseBackup(); self?.requested = false
            self?.finish(detail: "Von iOS pausiert · in der App fortsetzen", success: false)
        }.store(in: &subscriptions)
        cloud.telegram.$authorizationStage.receive(on: RunLoop.main).sink { [weak self] stage in
            if stage != .ready { self?.requested = false; self?.finish(detail: "Sitzung beendet", success: false) }
        }.store(in: &subscriptions)
    }
    private func refresh() {
        let backupActive = backup.isRunning && !backup.isPaused
        let active = cloud.upload != nil || backupActive || queue.isPreparingFiles || (!queue.isPaused && queue.queuedCount > 0)
        guard active else {
            if idleSince == nil { idleSince = Date() }
            if Date().timeIntervalSince(idleSince!) >= 3 {
                let paused = queue.isPaused || backup.isPaused
                finish(detail: paused ? "Übertragung pausiert" : (cloud.lastUploadFailure ?? "Übertragungen abgeschlossen"), success: !paused && cloud.lastUploadFailure == nil)
                requested = false
            }
            return
        }
        idleSince = nil
        ContinuedTransfers.shared.update(id: cloud.upload?.id, bytes: max(cloud.upload?.completedBytes ?? 0, telemetry.uploadedBytes),
            total: cloud.upload?.totalBytes ?? 0, queued: queue.queuedCount + backup.pendingResources)
        let state = TransferActivityAttributes.ContentState(
            fileName: String((cloud.upload?.fileName ?? backup.currentFileName ?? "Übertragung vorbereiten …").prefix(160)),
            fraction: cloud.upload == nil ? (backup.totalResources > 0 ? min(1, Double(backup.backedUpResources) / Double(backup.totalResources)) : 0) : telemetry.fraction,
            detail: String((cloud.upload?.status ?? backup.statusText).prefix(160)),
            speed: cloud.upload == nil ? "" : telemetry.speedText,
            pending: queue.queuedCount, backupCompleted: backup.backedUpResources,
            backupTotal: backupActive ? backup.totalResources : 0, nightMode: backup.isNightMode, paused: false)
        guard !isUpdating else { return }
        if activity == nil {
            guard requested, UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(attributes: TransferActivityAttributes(startedAt: Date()),
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(45)), pushType: nil)
                requested = false; lastState = state; lastUpdate = Date()
            } catch { requested = false }
        } else if state != lastState || Date().timeIntervalSince(lastUpdate) >= 20, let activity {
            if activity.activityState == .dismissed || activity.activityState == .ended { self.activity = nil; return }
            lastState = state; lastUpdate = Date(); isUpdating = true
            Task { [weak self] in
                await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(45)))
                self?.isUpdating = false
            }
        }
    }
    private func finish(detail: String, success: Bool) {
        ContinuedTransfers.shared.finish(success: success)
        guard let activity, var state = lastState else { return }
        self.activity = nil; lastState = nil
        state.detail = String(detail.prefix(160)); state.paused = !success; state.speed = ""
        if success { state.fraction = 1 }
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(90))) }
    }
}
