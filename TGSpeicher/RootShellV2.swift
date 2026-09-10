import SwiftUI
import UIKit

/// Own the dependency graph once. Constructing shared dependencies in a View.init
/// reruns queue recovery, disk reads/writes and photo cleanup on every parent update.
@MainActor
private final class V2AppServices: ObservableObject {
    let telegram: TelegramClient
    let cloud: CloudStore
    let preferences: AppPreferences
    let queue: UploadQueueManager
    let remoteImporter: RemoteURLImporter
    let network: TGNetworkMonitor
    let proxy: TGProxyManager
    let runtime: TransferRuntime
    let telemetry: TelegramTransferTelemetry
    let usageScanner: TelegramUsageScanner
    let music: MusicPlayer
    let channel: MusicChannelManager
    let activities: TransferActivityController
    let photoBackup: PhotoBackupManager

    init(telegram: TelegramClient, cloud: CloudStore) {
        self.telegram = telegram
        self.cloud = cloud
        let preferences = AppPreferences()
        let network = TGNetworkMonitor()
        let queue = UploadQueueManager(cloud: cloud, preferences: preferences, network: network)
        let telemetry = TelegramTransferTelemetry(cloud: cloud, telegram: telegram)
        let backup = PhotoBackupManager(cloud: cloud, queue: queue, telegram: telegram)
        self.preferences = preferences
        self.network = network
        self.queue = queue
        self.telemetry = telemetry
        self.photoBackup = backup
        self.music = MusicPlayer(cloud: cloud, telegram: telegram, network: network)
        self.remoteImporter = RemoteURLImporter()
        self.proxy = TGProxyManager()
        self.runtime = TransferRuntime(cloud: cloud, preferences: preferences, backup: backup)
        self.channel = MusicChannelManager(cloud: cloud, telegram: telegram, queue: queue, network: network)
        self.activities = TransferActivityController(cloud: cloud, queue: queue, backup: backup, telemetry: telemetry)
        self.usageScanner = TelegramUsageScanner(telegram: telegram)
    }
}

@MainActor
struct V2RootView: View {
    @StateObject private var services: V2AppServices

    init(telegram: TelegramClient, cloud: CloudStore) {
        // Keep construction inside StateObject's lazy autoclosure.
        _services = StateObject(wrappedValue: V2AppServices(telegram: telegram, cloud: cloud))
    }

    var body: some View { V2RootContent(services: services) }
}

@MainActor
private struct V2RootContent: View {
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
    let music: MusicPlayer
    let channel: MusicChannelManager
    let activities: TransferActivityController
    @ObservedObject var photoBackup: PhotoBackupManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0

    init(services: V2AppServices) {
        self.telegram = services.telegram
        self.cloud = services.cloud
        self.preferences = services.preferences
        self.queue = services.queue
        self.remoteImporter = services.remoteImporter
        self.network = services.network
        self.proxy = services.proxy
        self.runtime = services.runtime
        self.telemetry = services.telemetry
        self.usageScanner = services.usageScanner
        self.music = services.music
        self.channel = services.channel
        self.activities = services.activities
        self.photoBackup = services.photoBackup
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

