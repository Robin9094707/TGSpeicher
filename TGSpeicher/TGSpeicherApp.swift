import SwiftUI

@main
struct TGSpeicherApp: App {
    @StateObject private var telegram: TelegramClient
    @StateObject private var cloud: CloudStore

    init() {
        let client = TelegramClient()
        _telegram = StateObject(wrappedValue: client)
        _cloud = StateObject(wrappedValue: CloudStore(telegram: client))
    }

    var body: some Scene {
        WindowGroup {
            RootView(telegram: telegram, cloud: cloud)
                .tint(.blue)
        }
    }
}
