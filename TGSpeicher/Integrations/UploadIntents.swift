import AppIntents
import Foundation

extension Notification.Name { static let uploadShortcutRequested = Notification.Name("TGSpeicher.uploadShortcutRequested") }

@MainActor
enum UploadShortcutRequest {
    static func submit(_ action: String) {
        UserDefaults.standard.set(action, forKey: "shortcut.upload.action.v1")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "shortcut.upload.time.v1")
        NotificationCenter.default.post(name: .uploadShortcutRequested, object: nil)
    }
    static func consume() -> String? {
        let defaults = UserDefaults.standard
        guard let action = defaults.string(forKey: "shortcut.upload.action.v1") else { return nil }
        defaults.removeObject(forKey: "shortcut.upload.action.v1")
        guard Date().timeIntervalSince1970 - defaults.double(forKey: "shortcut.upload.time.v1") < 120 else { return nil }
        return action
    }
}

struct StartPhotoBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "Fotosicherung starten"
    static var description = IntentDescription("Öffnet TGSpeicher und startet die Fotosicherung im gewählten Sicherungsziel.")
    static var openAppWhenRun = true
    @Parameter(title: "Nachtmodus", default: false) var nightMode: Bool
    @MainActor func perform() async throws -> some IntentResult {
        UploadShortcutRequest.submit(nightMode ? "night" : "backup")
        return .result()
    }
}
struct UploadInboxIntent: AppIntent {
    static var title: LocalizedStringResource = "Datei-Eingang hochladen"
    static var description = IntentDescription("Öffnet TGSpeicher und fügt Dateien aus Upload Inbox zur Upload-Warteschlange hinzu.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UploadShortcutRequest.submit("inbox")
        return .result()
    }
}
struct ResumeUploadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Uploads fortsetzen"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UploadShortcutRequest.submit("resume")
        return .result()
    }
}
struct TGSpeicherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartPhotoBackupIntent(), phrases: ["Starte Fotosicherung mit \(.applicationName)"], shortTitle: "Fotos sichern", systemImageName: "photo.badge.arrow.down")
        AppShortcut(intent: UploadInboxIntent(), phrases: ["Lade meinen Datei-Eingang mit \(.applicationName) hoch"], shortTitle: "Eingang hochladen", systemImageName: "tray.and.arrow.up")
        AppShortcut(intent: ResumeUploadsIntent(), phrases: ["Setze Uploads mit \(.applicationName) fort"], shortTitle: "Uploads fortsetzen", systemImageName: "arrow.up.circle")
    }
}
