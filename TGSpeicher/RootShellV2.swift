import SwiftUI
import UIKit


struct V2RootView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    @StateObject private var preferences: AppPreferences
    @StateObject private var queue: UploadQueueManager
    @StateObject private var remoteImporter: RemoteURLImporter
    @StateObject private var network: TGNetworkMonitor
    @StateObject private var proxy: TGProxyManager
    @StateObject private var runtime: TransferRuntime

    init(telegram: TelegramClient, cloud: CloudStore) {
        self.telegram = telegram
        self.cloud = cloud
        let preferences = AppPreferences()
        let network = TGNetworkMonitor()
        _preferences = StateObject(wrappedValue: preferences)
        _queue = StateObject(wrappedValue: UploadQueueManager(cloud: cloud, preferences: preferences, network: network))
        _remoteImporter = StateObject(wrappedValue: RemoteURLImporter())
        _network = StateObject(wrappedValue: network)
        _proxy = StateObject(wrappedValue: TGProxyManager())
        _runtime = StateObject(wrappedValue: TransferRuntime(cloud: cloud, preferences: preferences))
    }

    var body: some View {
        ZStack {
            AppBackground()
            switch telegram.authorizationStage {
            case .ready:
                DriveShellV2(
                    telegram: telegram,
                    cloud: cloud,
                    preferences: preferences,
                    queue: queue,
                    remoteImporter: remoteImporter,
                    network: network,
                    proxy: proxy,
                    runtime: runtime
                )
            default:
                LoginView(telegram: telegram)
            }
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
        .alert("Telegram", isPresented: Binding(
            get: { telegram.lastError != nil },
            set: { if !$0 { telegram.clearError() } }
        )) {
            Button("OK", role: .cancel) { telegram.clearError() }
        } message: {
            Text(telegram.lastError ?? "")
        }
        .alert("TGSpeicher", isPresented: Binding(
            get: { cloud.lastError != nil || queue.lastError != nil || remoteImporter.lastError != nil || proxy.lastError != nil },
            set: { visible in
                if !visible {
                    cloud.lastError = nil
                    queue.lastError = nil
                    remoteImporter.lastError = nil
                    proxy.lastError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                cloud.lastError = nil
                queue.lastError = nil
                remoteImporter.lastError = nil
                proxy.lastError = nil
            }
        } message: {
            Text(cloud.lastError ?? queue.lastError ?? remoteImporter.lastError ?? proxy.lastError ?? "Unknown error")
        }
    }
}

struct DriveShellV2: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var remoteImporter: RemoteURLImporter
    @ObservedObject var network: TGNetworkMonitor
    @ObservedObject var proxy: TGProxyManager
    let runtime: TransferRuntime

    var body: some View {
        TabView {
            NavigationStack {
                DriveBrowserV2(
                    folderID: nil,
                    title: "TG Drive",
                    cloud: cloud,
                    preferences: preferences,
                    queue: queue,
                    remoteImporter: remoteImporter
                )
            }
            .tabItem { Label("Drive", systemImage: "externaldrive.fill.badge.icloud") }

            NavigationStack {
                SearchHubV2(cloud: cloud, preferences: preferences)
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack {
                TransfersViewV2(cloud: cloud, queue: queue, remoteImporter: remoteImporter)
            }
            .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down.circle.fill") }

            NavigationStack {
                OverviewV2(telegram: telegram, cloud: cloud, network: network, queue: queue)
            }
            .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }

            NavigationStack {
                SettingsV2(
                    telegram: telegram,
                    cloud: cloud,
                    preferences: preferences,
                    queue: queue,
                    network: network,
                    proxy: proxy,
                    runtime: runtime
                )
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .overlay(alignment: .bottom) {
            if let upload = cloud.upload {
                CompactTransferGlass(progress: upload)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: cloud.upload)
    }
}

