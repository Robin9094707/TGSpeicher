import SwiftUI

struct TransfersViewV2: View {
    @ObservedObject var cloud: CloudStore
    @ObservedObject var queue: UploadQueueManager
    @ObservedObject var remoteImporter: RemoteURLImporter
    var body: some View {
        List {
            if let upload = cloud.upload { Section("Active Upload") { VStack(alignment: .leading, spacing: 9) { HStack { Label(upload.fileName, systemImage: "arrow.up.circle.fill"); Spacer(); Text("\(Int(upload.fraction * 100))%").monospacedDigit().foregroundStyle(.secondary) }; ProgressView(value: upload.fraction); Text(upload.status).font(.caption).foregroundStyle(.secondary) } } }
            if cloud.isDownloading { Section("Active Download") { HStack { ProgressView(); Text("Downloading and verifying Telegram chunks…") } } }
            Section("Upload Queue") {
                if queue.items.isEmpty { ContentUnavailableView("Queue is empty", systemImage: "tray", description: Text("Multi-file and URL uploads appear here.")) }
                else { ForEach(queue.items) { item in QueueRow(item: item, queue: queue) } }
                HStack { Button(queue.isPaused ? "Resume Queue" : "Pause Queue", systemImage: queue.isPaused ? "play.fill" : "pause.fill") { queue.isPaused ? queue.resume() : queue.pause() }; Spacer(); if queue.items.contains(where: { $0.state == .completed }) { Button("Clear Done") { queue.clearCompleted() } } }
            }
            Section("Offline") { NavigationLink { LocalDownloadsView() } label: { LabeledContent("Downloaded files", value: "\(TGLocalDownloads.allFiles().count)") }; LabeledContent("Offline disk usage", value: TGLocalDownloads.totalBytes().byteCountString) }
            if remoteImporter.isRunning { Section("Remote Import") { HStack { ProgressView(); Text(remoteImporter.status) } } }
        }.navigationTitle("Transfers")
    }
}

struct QueueRow: View {
    let item: QueuedUpload; @ObservedObject var queue: UploadQueueManager
    var body: some View { HStack(spacing: 12) { Image(systemName: icon).foregroundStyle(tint).frame(width: 28); VStack(alignment: .leading, spacing: 3) { Text(item.displayName).lineLimit(1); Text(item.byteSize.byteCountString + " • " + statusText).font(.caption).foregroundStyle(.secondary); if let error = item.lastError, item.state == .failed { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) } }; Spacer(); if item.state == .failed { Button { queue.retry(item) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless) } }.swipeActions { if item.state != .uploading { Button(role: .destructive) { queue.remove(item) } label: { Label("Remove", systemImage: "trash") } } } }
    private var icon: String { switch item.state { case .queued: "clock.fill"; case .uploading: "arrow.up.circle.fill"; case .failed: "exclamationmark.triangle.fill"; case .completed: "checkmark.circle.fill" } }
    private var tint: Color { switch item.state { case .queued: .secondary; case .uploading: .blue; case .failed: .red; case .completed: .green } }
    private var statusText: String { switch item.state { case .queued: "Queued"; case .uploading: "Uploading"; case .failed: "Failed"; case .completed: "Completed" } }
}

struct OverviewV2: View {
    @ObservedObject var telegram: TelegramClient; @ObservedObject var cloud: CloudStore; @ObservedObject var network: TGNetworkMonitor; @ObservedObject var queue: UploadQueueManager
    var body: some View { ScrollView { VStack(spacing: 14) { HStack { VStack(alignment: .leading, spacing: 4) { Text("Connected as").font(.caption).foregroundStyle(.secondary); Text(telegram.accountName).font(.title2.bold()); Text(network.isConnected ? "\(network.interfaceName) connected" : "Offline").font(.caption).foregroundStyle(network.isConnected ? .green : .red) }; Spacer(); Image(systemName: "checkmark.icloud.fill").font(.largeTitle).foregroundStyle(.green) }.tgGlassCard(); LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { MetricCard(title: "Tracked cloud", value: cloud.totalTrackedBytes.byteCountString, icon: "externaldrive.fill"); MetricCard(title: "Files", value: "\(cloud.index.files.count)", icon: "doc.fill"); MetricCard(title: "Folders", value: "\(cloud.index.folders.count)", icon: "folder.fill"); MetricCard(title: "Tags", value: "\(cloud.index.tags.count)", icon: "tag.fill"); MetricCard(title: "Chunks", value: "\(cloud.totalChunks)", icon: "square.stack.3d.up.fill"); MetricCard(title: "Queued", value: "\(queue.queuedCount)", icon: "arrow.up.circle.fill") }; VStack(alignment: .leading, spacing: 10) { Label("Cloud Catalog", systemImage: "arrow.triangle.2.circlepath.icloud.fill").font(.headline); Text(cloud.catalogStatus).foregroundStyle(.secondary); LabeledContent("Revision", value: "\(cloud.index.revision)"); Button("Sync now", systemImage: "arrow.up.doc.on.clipboard") { cloud.syncCatalogNow() }.buttonStyle(.bordered).disabled(cloud.isCatalogSyncing) }.frame(maxWidth: .infinity, alignment: .leading).tgGlassCard(); VStack(alignment: .leading, spacing: 10) { Label("iPhone Storage", systemImage: "iphone.gen3").font(.headline); LabeledContent("Offline downloads", value: "\(TGLocalDownloads.allFiles().count)"); LabeledContent("Offline size", value: TGLocalDownloads.totalBytes().byteCountString); LabeledContent("Upload queue", value: "\(queue.items.count)") }.frame(maxWidth: .infinity, alignment: .leading).tgGlassCard() }.padding(14) }.navigationTitle("Overview") }
}
