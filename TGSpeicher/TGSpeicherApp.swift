import SwiftUI

@main
struct TGSpeicherApp: App {
    @StateObject private var telegram: TelegramClient
    @StateObject private var cloud: CloudStore
    @StateObject private var backgroundRelay = BackgroundRelayCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let client = TelegramClient()
        _telegram = StateObject(wrappedValue: client)
        _cloud = StateObject(wrappedValue: CloudStore(telegram: client))
    }

    var body: some Scene {
        WindowGroup {
            V2RootView(telegram: telegram, cloud: cloud)
                .tint(.blue)
                .environment(\.locale, Locale(identifier: "de_DE"))
                .onAppear { backgroundRelay.appBecameActive() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { backgroundRelay.appBecameActive() }
                }
                .alert("Background-Server nicht erreichbar", isPresented: $backgroundRelay.needsFallbackDecision) {
                    Button("Direkt zu Telegram") { Task { await backgroundRelay.useDirectFallback() } }
                    Button("Erneut prüfen") { Task { _ = await backgroundRelay.ping(showFallback: true) } }
                    Button("Später", role: .cancel) { }
                } message: {
                    Text("Deine Daten bleiben erhalten. Du kannst den optionalen Servermodus ausschalten und TGSpeicher wie bisher direkt mit Telegram weiterverwenden.")
                }
        }
    }
}
