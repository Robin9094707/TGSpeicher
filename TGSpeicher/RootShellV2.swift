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
    @StateObject private var telemetry: TelegramTransferTelemetry
    @StateObject private var usageScanner: TelegramUsageScanner
    @StateObject private var photoBackup: PhotoBackupManager

    init(telegram: TelegramClient, cloud: CloudStore) {
        self.telegram = telegram
        self.cloud = cloud
        let preferences = AppPreferences()
        let network = TGNetworkMonitor()
        let queue = UploadQueueManager(cloud: cloud, preferences: preferences, network: network)
        _preferences = StateObject(wrappedValue: preferences)
        _queue = StateObject(wrappedValue: queue)
        _remoteImporter = StateObject(wrappedValue: RemoteURLImporter())
        _network = StateObject(wrappedValue: network)
        _proxy = StateObject(wrappedValue: TGProxyManager())
        _runtime = StateObject(wrappedValue: TransferRuntime(cloud: cloud, preferences: preferences))
        _telemetry = StateObject(wrappedValue: TelegramTransferTelemetry(cloud: cloud, telegram: telegram))
        _usageScanner = StateObject(wrappedValue: TelegramUsageScanner(telegram: telegram))
        _photoBackup = StateObject(wrappedValue: PhotoBackupManager(cloud: cloud, queue: queue, telegram: telegram))
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
                    photoBackup: photoBackup
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
            get: {
                cloud.lastError != nil || queue.lastError != nil || remoteImporter.lastError != nil || proxy.lastError != nil || photoBackup.lastError != nil
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
            Text(cloud.lastError ?? queue.lastError ?? remoteImporter.lastError ?? proxy.lastError ?? photoBackup.lastError ?? "Unknown error")
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
    @ObservedObject var telemetry: TelegramTransferTelemetry
    @ObservedObject var usageScanner: TelegramUsageScanner
    @ObservedObject var photoBackup: PhotoBackupManager

    var body: some View {
        TabView {
            NavigationStack {
                OptimizedDriveBrowserV2(
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
                PhotoBackupView(manager: photoBackup, cloud: cloud, telemetry: telemetry, telegram: telegram)
            }
            .tabItem { Label("Photos", systemImage: "photo.stack.fill") }

            NavigationStack {
                TransfersViewV2(cloud: cloud, queue: queue, remoteImporter: remoteImporter, telemetry: telemetry)
            }
            .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down.circle.fill") }

            NavigationStack {
                OverviewV2(
                    telegram: telegram,
                    cloud: cloud,
                    network: network,
                    queue: queue,
                    telemetry: telemetry,
                    usageScanner: usageScanner,
                    photoBackup: photoBackup
                )
            }
            .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }

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
                LiveCompactTransferGlass(progress: upload, telemetry: telemetry)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
                if progress.partCount > 1 { Text("Part \(max(1, progress.currentPart))/\(progress.partCount)") }
                Text("ETA \(telemetry.etaText)")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 10, y: 5)
    }
}