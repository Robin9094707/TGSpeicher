import SwiftUI

struct TransfersViewV2: View {
    @ObservedObject var cloud: CloudStore
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var remoteImporter: RemoteURLImporter
    @ObservedObject var telemetry: TelegramTransferTelemetry

    var body: some View {
        List {
            if let upload = cloud.upload {
                Section("Active Upload") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(upload.fileName, systemImage: "arrow.up.circle.fill")
                            Spacer()
                            Text("\(Int(telemetry.fraction * 100))%")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: telemetry.fraction)
                        HStack {
                            Text(telemetry.speedText)
                            Spacer()
                            Text("ETA \(telemetry.etaText)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(max(telemetry.uploadedBytes, upload.completedBytes).byteCountString)
                            Text("of")
                            Text(upload.totalBytes.byteCountString)
                            if upload.partCount > 1 {
                                Spacer()
                                Text("Part \(max(1, upload.currentPart))/\(upload.partCount)")
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        Text(upload.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if cloud.isDownloading {
                Section("Active Download") {
                    HStack { ProgressView(); Text("Downloading and verifying Telegram chunks…") }
                }
            }

            Section("Upload Queue") {
                if queue.items.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "tray", description: Text("Multi-file, URL and Photo Backup uploads appear here."))
                } else {
                    ForEach(queue.items) { item in QueueRow(item: item, queue: queue) }
                }
                HStack {
                    Button(queue.isPaused ? "Resume Queue" : "Pause Queue", systemImage: queue.isPaused ? "play.fill" : "pause.fill") {
                        queue.isPaused ? queue.resume() : queue.pause()
                    }
                    Spacer()
                    if queue.items.contains(where: { $0.state == .completed }) {
                        Button("Clear Done") { queue.clearCompleted() }
                    }
                }
            }

            Section("Offline") {
                NavigationLink { LocalDownloadsView() } label: {
                    LabeledContent("Downloaded files", value: "\(TGLocalDownloads.allFiles().count)")
                }
                LabeledContent("Offline disk usage", value: TGLocalDownloads.totalBytes().byteCountString)
            }

            if remoteImporter.isRunning {
                Section("Remote Import") { HStack { ProgressView(); Text(remoteImporter.status) } }
            }
        }
        .navigationTitle("Transfers")
    }
}

struct QueueRow: View {
    let item: QueuedUpload
    @ObservedObject var queue: UploadQueueManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).lineLimit(1)
                Text(item.byteSize.byteCountString + " • " + statusText).font(.caption).foregroundStyle(.secondary)
                if let error = item.lastError, item.state == .failed {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if item.state == .failed {
                Button { queue.retry(item) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
        }
        .swipeActions {
            if item.state != .uploading {
                Button(role: .destructive) { queue.remove(item) } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    private var icon: String {
        switch item.state {
        case .queued: "clock.fill"
        case .uploading: "arrow.up.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch item.state {
        case .queued: .secondary
        case .uploading: .blue
        case .failed: .red
        case .completed: .green
        }
    }

    private var statusText: String {
        switch item.state {
        case .queued: "Queued"
        case .uploading: "Uploading"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }
}

struct OverviewV2: View {
    @ObservedObject var telegram: TelegramClient
    @ObservedObject var cloud: CloudStore
    @ObservedObject var network: TGNetworkMonitor
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var telemetry: TelegramTransferTelemetry
    @ObservedObject var usageScanner: TelegramUsageScanner
    @ObservedObject var photoBackup: PhotoBackupManager

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                connectionCard
                primaryMetrics
                storageBreakdown
                folderBreakdown
                telegramVerification
                photoStats
                localStats
            }
            .padding(14)
        }
        .navigationTitle("Nerd Stats")
        .refreshable { usageScanner.refresh() }
    }

    private var connectionCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected as").font(.caption).foregroundStyle(.secondary)
                Text(telegram.accountName).font(.title2.bold())
                Text(network.isConnected ? "\(network.interfaceName) connected" : "Offline")
                    .font(.caption).foregroundStyle(network.isConnected ? .green : .red)
            }
            Spacer()
            Image(systemName: "checkmark.icloud.fill").font(.largeTitle).foregroundStyle(.green)
        }
        .tgGlassCard()
    }

    private var primaryMetrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricCard(title: "Logical cloud", value: cloud.totalTrackedBytes.byteCountString, icon: "externaldrive.fill")
            MetricCard(title: "Telegram payload", value: cloud.trackedTelegramPayloadBytes.byteCountString, icon: "paperplane.fill")
            MetricCard(title: "Files", value: "\(cloud.index.files.count)", icon: "doc.fill")
            MetricCard(title: "Folders", value: "\(cloud.index.folders.count)", icon: "folder.fill")
            MetricCard(title: "Chunks", value: "\(cloud.totalChunks)", icon: "square.stack.3d.up.fill")
            MetricCard(title: "Avg. file", value: cloud.averageTrackedFileBytes.byteCountString, icon: "divide.circle.fill")
        }
    }

    private var storageBreakdown: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Storage Breakdown", systemImage: "chart.pie.fill").font(.headline)
            if let largest = cloud.largestTrackedFile {
                LabeledContent("Largest file", value: largest.totalSize.byteCountString)
                Text(largest.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(cloud.fileTypeUsage) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.label)
                        Spacer()
                        Text("\(item.count) • \(item.bytes.byteCountString)").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    ProgressView(value: cloud.totalTrackedBytes > 0 ? Double(item.bytes) / Double(cloud.totalTrackedBytes) : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var folderBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Largest Folders", systemImage: "folder.fill.badge.gearshape").font(.headline)
            if cloud.topLevelFolderUsage.isEmpty {
                Text("No folders yet").foregroundStyle(.secondary)
            } else {
                ForEach(Array(cloud.topLevelFolderUsage.prefix(8))) { item in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.orange)
                        Text(item.label).lineLimit(1)
                        Spacer()
                        Text("\(item.count) • \(item.bytes.byteCountString)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var telegramVerification: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Telegram Verification", systemImage: "checkmark.shield.fill").font(.headline)
                Spacer()
                if usageScanner.isScanning { ProgressView() }
            }
            if let bytes = usageScanner.verifiedBytes {
                LabeledContent("Verified objects", value: "\(usageScanner.verifiedMessages)")
                LabeledContent("Verified bytes", value: bytes.byteCountString)
                if let date = usageScanner.lastScanAt {
                    LabeledContent("Last scan", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            } else {
                Text("The fast numbers above come from the synced TGSpeicher catalog. Run verification to also scan the actual TGSpeicher documents in Saved Messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(usageScanner.status).font(.caption).foregroundStyle(.secondary)
            Button("Verify Telegram usage", systemImage: "magnifyingglass") { usageScanner.refresh() }
                .buttonStyle(.bordered)
                .disabled(usageScanner.isScanning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var photoStats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Photo Vault", systemImage: "photo.stack.fill").font(.headline)
            LabeledContent("Photos in cloud", value: "\(cloud.photoFileCount)")
            LabeledContent("Photo bytes", value: cloud.photoBytes.byteCountString)
            LabeledContent("Videos in cloud", value: "\(cloud.videoFileCount)")
            LabeledContent("Video bytes", value: cloud.videoBytes.byteCountString)
            LabeledContent("Library backed up", value: "\(photoBackup.backedUpAssets) / \(photoBackup.totalAssets)")
            LabeledContent("Backup resources", value: "\(photoBackup.backedUpResources) / \(photoBackup.totalResources)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var localStats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("iPhone Storage", systemImage: "iphone.gen3").font(.headline)
            LabeledContent("Offline downloads", value: "\(TGLocalDownloads.allFiles().count)")
            LabeledContent("Offline size", value: TGLocalDownloads.totalBytes().byteCountString)
            LabeledContent("Upload queue", value: "\(queue.items.count)")
            if cloud.upload != nil {
                LabeledContent("Live upload", value: "\(Int(telemetry.fraction * 100))% • \(telemetry.speedText)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }
}
