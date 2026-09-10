import SwiftUI
import UIKit

@MainActor
struct V2RootView: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences: AppPreferences
    @StateObject private var queue: UploadQueueManager
    @StateObject private var remoteImporter: RemoteURLImporter
    @StateObject private var network: TGNetworkMonitor
    @StateObject private var proxy: TGProxyManager
    @StateObject private var runtime: TransferRuntime
    @StateObject private var telemetry: TelegramTransferTelemetry
    @StateObject private var usageScanner: TelegramUsageScanner
    @StateObject private var music: MusicPlayer
    @StateObject private var channel: MusicChannelManager
    @StateObject private var activities: TransferActivityController
    @State private var selectedTab = 0
    @StateObject private var photoBackup: PhotoBackupManager

    init(telegram: TelegramClient, cloud: CloudStore) {
        self.telegram = telegram
        self.cloud = cloud
        let preferences = AppPreferences()
        let network = TGNetworkMonitor()
        let queue = UploadQueueManager(cloud: cloud, preferences: preferences, network: network)
        _music = StateObject(wrappedValue: MusicPlayer(cloud: cloud, telegram: telegram, network: network))
        _preferences = StateObject(wrappedValue: preferences)
        _queue = StateObject(wrappedValue: queue)
        _remoteImporter = StateObject(wrappedValue: RemoteURLImporter())
        _network = StateObject(wrappedValue: network)
        _proxy = StateObject(wrappedValue: TGProxyManager())
        let telemetry = TelegramTransferTelemetry(cloud: cloud, telegram: telegram)
        let backup = PhotoBackupManager(cloud: cloud, queue: queue, telegram: telegram)
        _runtime = StateObject(wrappedValue: TransferRuntime(cloud: cloud, preferences: preferences, backup: backup))
        _telemetry = StateObject(wrappedValue: telemetry)
        _channel = StateObject(wrappedValue: MusicChannelManager(cloud: cloud, telegram: telegram, queue: queue, network: network))
        _activities = StateObject(wrappedValue: TransferActivityController(cloud: cloud, queue: queue, backup: backup, telemetry: telemetry))
        _usageScanner = StateObject(wrappedValue: TelegramUsageScanner(telegram: telegram))
        _photoBackup = StateObject(wrappedValue: backup)
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
                    runtime: runtime,
                    telemetry: telemetry,
                    usageScanner: usageScanner,
                    photoBackup: photoBackup,
                    selectedTab: $selectedTab
                )
            default:
                LoginView(telegram: telegram)
            }
        }
        .environmentObject(music)
        .environmentObject(channel)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                telegram.refreshUploadLimits()
                music.refreshOfflineLibrary()
                handleShortcut()
            } else {
                // Metadata prefetch is opportunistic work. It must never compete with
                // real AVPlayer background playback or keep Telegram range loaders alive
                // while iOS is transitioning the process out of the foreground.
                music.cancelMetadataScan()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uploadShortcutRequested)) { _ in handleShortcut() }
        .onChange(of: cloud.recoveryReady) { _, ready in if ready { handleShortcut() } }
        .onOpenURL { url in if url.scheme == "tgspeicher", url.host == "transfers" { selectedTab = 2 } }
        .alert("Telegram", isPresented: Binding(
            get: { telegram.lastError != nil && !photoBackup.isRunning },
            set: { if !$0 { telegram.clearError() } }
        )) {
            Button("OK", role: .cancel) { telegram.clearError() }
        } message: {
            Text(telegram.lastError ?? "")
        }
        .alert("TGSpeicher", isPresented: Binding(
            get: {
                !photoBackup.isRunning && (
                    cloud.lastError != nil || queue.lastError != nil || remoteImporter.lastError != nil || proxy.lastError != nil || photoBackup.lastError != nil
                )
            },
            set: { visible in
                if !visible {
                    cloud.lastError = nil
                    queue.lastError = nil
                    remoteImporter.lastError = nil
                    proxy.lastError = nil
                    photoBackup.lastError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                cloud.lastError = nil
                queue.lastError = nil
                remoteImporter.lastError = nil
                proxy.lastError = nil
                photoBackup.lastError = nil
            }
        } message: {
            Text(cloud.lastError ?? queue.lastError ?? remoteImporter.lastError ?? proxy.lastError ?? photoBackup.lastError ?? "Unbekannter Fehler")
        }
        .fullScreenCover(isPresented: Binding(
            get: { photoBackup.isNightMode && telegram.authorizationStage == .ready },
            set: { if !$0, photoBackup.isNightMode { photoBackup.pauseBackup() } }
        )) {
            NightPhotoBackupScreen(manager: photoBackup, cloud: cloud, telemetry: telemetry)
                .interactiveDismissDisabled()
        }
        .onAppear {
            photoBackup.activateRestoredNightModeIfNeeded()
            handleShortcut()
        }
    }
    private func handleShortcut() {
        guard scenePhase == .active, telegram.authorizationStage == .ready, cloud.recoveryReady,
              let action = UploadShortcutRequest.consume() else { return }
        switch action {
        case "backup", "night":
            selectedTab = 1
            photoBackup.resumeBackup(nightMode: action == "night")
        case "inbox":
            selectedTab = 2; cloud.refreshLocalInbox()
            let pendingPaths = Set(queue.items.filter { $0.state != .completed }.map(\.displayName))
            queue.enqueue(urls: cloud.localInboxFiles.filter { !pendingPaths.contains($0.lastPathComponent) }, folderID: nil)
            queue.resume()
        case "resume": selectedTab = 2; queue.resume()
        default: break
        }
    }
}

struct DriveShellV2: View {
    @EnvironmentObject private var music: MusicPlayer
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var remoteImporter: RemoteURLImporter
    @ObservedObject var network: TGNetworkMonitor
    @ObservedObject var proxy: TGProxyManager
    let runtime: TransferRuntime
    @ObservedObject var telemetry: TelegramTransferTelemetry
    @ObservedObject var usageScanner: TelegramUsageScanner
    @ObservedObject var photoBackup: PhotoBackupManager
    @Binding var selectedTab: Int

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                OptimizedDriveBrowserV2(
                    folderID: nil,
                    title: "Meine Dateien",
                    cloud: cloud,
                    preferences: preferences,
                    queue: queue,
                    remoteImporter: remoteImporter
                )
            }
            .safeAreaPadding(.bottom, music.queue.current == nil ? 0 : 76)
            .tabItem { Label("Dateien", systemImage: "externaldrive.fill.badge.icloud") }
            .tag(0)

            NavigationStack {
                PhotoBackupView(manager: photoBackup, cloud: cloud, telemetry: telemetry)
            }
            .safeAreaPadding(.bottom, music.queue.current == nil ? 0 : 76)
            .tabItem { Label("Fotos", systemImage: "photo.stack.fill") }
            .tag(1)

            NavigationStack {
                TransfersViewV2(cloud: cloud, queue: queue, remoteImporter: remoteImporter, telemetry: telemetry)
            }
            .safeAreaPadding(.bottom, music.queue.current == nil ? 0 : 76)
            .tabItem { Label("Übertragungen", systemImage: "arrow.up.arrow.down.circle.fill") }
            .tag(2)

            NavigationStack {
                MusicLibraryView(cloud: cloud)
            }
            .safeAreaPadding(.bottom, music.queue.current == nil ? 0 : 76)
            .tabItem { Label("Musik", systemImage: "music.note") }
            .tag(3)

            NavigationStack {
                SettingsV2(
                    telegram: telegram,
                    cloud: cloud,
                    preferences: preferences,
                    queue: queue,
                    network: network,
                    proxy: proxy,
                    runtime: runtime,
                    overview: AnyView(OverviewV2(telegram: telegram, cloud: cloud, network: network, queue: queue, telemetry: telemetry, usageScanner: usageScanner, photoBackup: photoBackup))
                )
            }
            .safeAreaPadding(.bottom, music.queue.current == nil ? 0 : 76)
            .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
            .tag(4)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 4) { RecoveryStatusBanner(cloud: cloud); DeletionStatusBanner(cloud: cloud) }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let upload = cloud.upload { LiveCompactTransferGlass(progress: upload, telemetry: telemetry) }
                if music.queue.current != nil { MusicMiniPlayer() }
            }
            .padding(.horizontal, 14).padding(.bottom, 58)
        }
        .sheet(isPresented: $music.showingPlayer) { MusicPlayerSheet().environmentObject(music) }
        .onChange(of: music.error) { _, error in if error != nil { music.showingPlayer = true } }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: cloud.upload)
    }
}

private struct LiveCompactTransferGlass: View {
    let progress: UploadProgress
    @ObservedObject var telemetry: TelegramTransferTelemetry

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                Text(progress.fileName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(Int(telemetry.fraction * 100))%")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: telemetry.fraction)
            HStack {
                Text(telemetry.speedText)
                Spacer()
                if progress.partCount > 1 { Text("Teil \(max(1, progress.currentPart))/\(progress.partCount)") }
                Text("Restzeit \(telemetry.etaText)")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }
}
