import Foundation
import UIKit
import UserNotifications
import Combine

@MainActor
final class TransferRuntime: ObservableObject {
    private let cloud: CloudStore
    private let backup: PhotoBackupManager
    private let preferences: AppPreferences
    private var cancellables = Set<AnyCancellable>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var previousUpload: UploadProgress?
    private var wasDownloading = false

    init(cloud: CloudStore, preferences: AppPreferences, backup: PhotoBackupManager) {
        self.backup = backup
        self.cloud = cloud
        self.preferences = preferences

        backup.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshRuntimeProtection() }.store(in: &cancellables)
        cloud.$upload
            .receive(on: RunLoop.main)
            .sink { [weak self] upload in
                guard let self else { return }
                let finishedUpload = self.previousUpload != nil && upload == nil
                let previous = self.previousUpload
                self.previousUpload = upload
                self.refreshRuntimeProtection()
                if finishedUpload, let previous, self.cloud.lastUploadFailure == nil,
                   self.cloud.index.files.contains(where: { $0.id == previous.id && $0.isComplete }) {
                    self.notify(title: "Upload abgeschlossen", body: previous.fileName)
                }
            }
            .store(in: &cancellables)

        cloud.$isDownloading
            .receive(on: RunLoop.main)
            .sink { [weak self] downloading in
                guard let self else { return }
                let finished = self.wasDownloading && !downloading
                self.wasDownloading = downloading
                self.refreshRuntimeProtection()
                if finished, let url = self.cloud.lastExportURL, self.cloud.lastError == nil {
                    self.notify(title: "Download bereit", body: url.lastPathComponent)
                }
            }
            .store(in: &cancellables)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func refreshRuntimeProtection() {
        let active = cloud.upload != nil || cloud.isDownloading || (backup.isRunning && !backup.isPaused)
        UIApplication.shared.isIdleTimerDisabled = backup.isNightMode || (preferences.keepScreenAwakeDuringTransfers && active)
        if active { beginBackgroundTaskIfNeeded() } else { endBackgroundTaskIfNeeded() }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TGSpeicher transfer") { [weak self] in
            Task { @MainActor in self?.endBackgroundTaskIfNeeded() }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func notify(title: String, body: String) {
        guard preferences.transferNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}


