import SwiftUI

struct TransfersViewV2: View {
    @ObservedObject var cloud: CloudStore
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var remoteImporter: RemoteURLImporter
    @ObservedObject var telemetry: TelegramTransferTelemetry

    var body: some View {
        List {
            if let upload = cloud.upload {
                Section("Aktiver Upload") {
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
                            Text("Restzeit \(telemetry.etaText)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(max(telemetry.uploadedBytes, upload.completedBytes).byteCountString)
                            Text("von")
                            Text(upload.totalBytes.byteCountString)
                            if upload.partCount > 1 {
                                Spacer()
                                Text("Teil \(max(1, upload.currentPart))/\(upload.partCount)")
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        Text(upload.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if cloud.isDownloading {
                Section("Aktiver Download") {
                    HStack { ProgressView(); Text("Dateiteile werden geladen und geprüft …") }
                }
            }

            Section("Upload-Warteschlange") {
                if queue.items.isEmpty {
                    ContentUnavailableView("Warteschlange ist leer", systemImage: "tray", description: Text("Hier erscheinen Uploads von Dateien, Links und der Fotosicherung."))
                } else {
                    ForEach(queue.items) { item in QueueRow(item: item, queue: queue) }
                }
                HStack {
                    Button(queue.isPaused ? "Warteschlange fortsetzen" : "Warteschlange pausieren", systemImage: queue.isPaused ? "play.fill" : "pause.fill") {
                        queue.isPaused ? queue.resume() : queue.pause()
                    }
                    Spacer()
                    if queue.items.contains(where: { $0.state == .completed }) {
                        Button("Abgeschlossene entfernen") { queue.clearCompleted() }
                    }
                }
            }

            Section("Offline") {
                NavigationLink { LocalDownloadsView() } label: {
                    LabeledContent("Heruntergeladene Dateien", value: "\(TGLocalDownloads.allFiles().count)")
                }
                LabeledContent("Offline-Speicherbelegung", value: TGLocalDownloads.totalBytes().byteCountString)
            }

            if remoteImporter.isRunning {
                Section("Link-Import") { HStack { ProgressView(); Text(remoteImporter.status) } }
            }
        }
        .navigationTitle("Übertragungen")
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
                Button(role: .destructive) { queue.remove(item) } label: { Label("Entfernen", systemImage: "trash") }
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
        case .queued: "Wartend"
        case .uploading: "Wird hochgeladen"
        case .failed: "Fehlgeschlagen"
        case .completed: "Abgeschlossen"
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
        .navigationTitle("Speicherübersicht")
        .refreshable { usageScanner.refresh() }
    }

    private var connectionCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Angemeldet als").font(.caption).foregroundStyle(.secondary)
                Text(telegram.accountName).font(.title2.bold())
                Text(network.isConnected ? "Mit \(network.interfaceName) verbunden" : "Offline")
                    .font(.caption).foregroundStyle(network.isConnected ? .green : .red)
            }
            Spacer()
            Image(systemName: "checkmark.icloud.fill").font(.largeTitle).foregroundStyle(.green)
        }
        .tgGlassCard()
    }

    private var primaryMetrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricCard(title: "Erfasster Speicher", value: cloud.totalTrackedBytes.byteCountString, icon: "externaldrive.fill")
            MetricCard(title: "Telegram-Dateigröße", value: cloud.trackedTelegramPayloadBytes.byteCountString, icon: "paperplane.fill")
            MetricCard(title: "Dateien", value: "\(cloud.index.files.count)", icon: "doc.fill")
            MetricCard(title: "Ordner", value: "\(cloud.index.folders.count)", icon: "folder.fill")
            MetricCard(title: "Dateiteile", value: "\(cloud.totalChunks)", icon: "square.stack.3d.up.fill")
            MetricCard(title: "Ø Dateigröße", value: cloud.averageTrackedFileBytes.byteCountString, icon: "divide.circle.fill")
        }
    }

    private var storageBreakdown: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Speicher nach Dateityp", systemImage: "chart.pie.fill").font(.headline)
            if let largest = cloud.largestTrackedFile {
                LabeledContent("Größte Datei", value: largest.totalSize.byteCountString)
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
            Label("Größte Ordner", systemImage: "folder.fill.badge.gearshape").font(.headline)
            if cloud.topLevelFolderUsage.isEmpty {
                Text("Noch keine Ordner").foregroundStyle(.secondary)
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
                Label("Telegram-Prüfung", systemImage: "checkmark.shield.fill").font(.headline)
                Spacer()
                if usageScanner.isScanning { ProgressView() }
            }
            if let bytes = usageScanner.verifiedBytes {
                LabeledContent("Geprüfte Nachrichten", value: "\(usageScanner.verifiedMessages)")
                LabeledContent("Geprüfter Speicher", value: bytes.byteCountString)
                if let date = usageScanner.lastScanAt {
                    LabeledContent("Letzte Prüfung", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            } else {
                Text("Die Übersicht zeigt alle im gemeinsamen Katalog erfassten Dateien und Kanäle. Die zusätzliche Prüfung unten erfasst ältere TGSpeicher-Dokumente in „Gespeichertes“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(usageScanner.status).font(.caption).foregroundStyle(.secondary)
            Button("Telegram-Belegung prüfen", systemImage: "magnifyingglass") { usageScanner.refresh() }
                .buttonStyle(.bordered)
                .disabled(usageScanner.isScanning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var photoStats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fotosicherung", systemImage: "photo.stack.fill").font(.headline)
            LabeledContent("Gesicherte Fotos", value: "\(cloud.photoFileCount)")
            LabeledContent("Fotospeicher", value: cloud.photoBytes.byteCountString)
            LabeledContent("Gesicherte Videos", value: "\(cloud.videoFileCount)")
            LabeledContent("Videospeicher", value: cloud.videoBytes.byteCountString)
            LabeledContent("Mediathek gesichert", value: "\(photoBackup.backedUpAssets) / \(photoBackup.totalAssets)")
            LabeledContent("Gesicherte Bestandteile", value: "\(photoBackup.backedUpResources) / \(photoBackup.totalResources)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var localStats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("iPhone-Speicher", systemImage: "iphone.gen3").font(.headline)
            LabeledContent("Offline-Dateien", value: "\(TGLocalDownloads.allFiles().count)")
            LabeledContent("Offline-Größe", value: TGLocalDownloads.totalBytes().byteCountString)
            LabeledContent("Upload-Warteschlange", value: "\(queue.items.count)")
            if cloud.upload != nil {
                LabeledContent("Aktueller Upload", value: "\(Int(telemetry.fraction * 100))% • \(telemetry.speedText)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }
}

