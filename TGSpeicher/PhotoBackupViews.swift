import SwiftUI
import Photos

struct PhotoBackupView: View {
    @ObservedObject var manager: PhotoBackupManager
    @ObservedObject var cloud: CloudStore
    @ObservedObject var telemetry: TelegramTransferTelemetry
    let telegram: TelegramClient

    @State private var selectedCloudFileID: UUID?
    @State private var confirmDeleteLocal = false

    private var galleryRecords: [PhotoBackupRecord] {
        Dictionary(grouping: manager.records, by: { $0.assetLocalIdentifier })
            .values
            .compactMap { group in group.first(where: { $0.mediaKind == "photo" }) ?? group.first }
            .sorted { $0.uploadedAt > $1.uploadedAt }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if manager.hasLibraryAccess {
                    statistics
                    controls
                    gallery
                } else {
                    permissionCard
                }
            }
            .padding(14)
        }
        .navigationTitle("Photo Backup")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { manager.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!manager.hasLibraryAccess)
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedCloudFileID != nil },
            set: { if !$0 { selectedCloudFileID = nil } }
        )) {
            if let selectedCloudFileID,
               let file = cloud.index.files.first(where: { $0.id == selectedCloudFileID }) {
                CloudMediaPreviewSheet(file: file, telegram: telegram)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { manager.isNightMode },
            set: { if !$0 { manager.pauseBackup() } }
        )) {
            NightPhotoBackupScreen(manager: manager, cloud: cloud, telemetry: telemetry)
        }
        .confirmationDialog(
            "Remove fully backed-up items from the iPhone Photos library?",
            isPresented: $confirmDeleteLocal,
            titleVisibility: .visible
        ) {
            Button("Delete \(manager.deletableAssetCount) Backed-Up Item(s)", role: .destructive) {
                manager.deleteFullyBackedUpAssetsFromPhotos()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only items whose required resources are present in the TGSpeicher cloud index are included. iOS may show an additional Photos confirmation.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.blue.opacity(0.13))
                    Image(systemName: "photo.stack.fill").font(.title).foregroundStyle(.blue)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Telegram Photo Vault").font(.title3.bold())
                    Text(manager.statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if manager.isRunning { ProgressView() }
            }
            if manager.isExportingFromPhotos {
                ProgressView(value: manager.iCloudProgress)
                HStack {
                    Text(manager.currentFileName ?? "Preparing photo…").lineLimit(1)
                    Spacer()
                    Text("\(Int(manager.iCloudProgress * 100))%").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var permissionCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus").font(.system(size: 44)).foregroundStyle(.blue)
            Text("Allow Photos access").font(.title3.bold())
            Text("TGSpeicher can read your Photos library, fetch originals from iCloud when needed, and back them up one by one to your own Telegram Saved Messages.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Allow Full Photos Access", systemImage: "checkmark.shield.fill") {
                manager.requestFullAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .tgGlassCard()
    }

    private var statistics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            PhotoMetric(title: "Library", value: "\(manager.totalAssets)", icon: "photo.on.rectangle.angled")
            PhotoMetric(title: "Backed up", value: "\(manager.backedUpAssets)", icon: "checkmark.icloud.fill")
            PhotoMetric(title: "Resources", value: "\(manager.backedUpResources)/\(manager.totalResources)", icon: "square.stack.3d.up.fill")
            PhotoMetric(title: "Remaining", value: "\(manager.pendingResources)", icon: "clock.arrow.circlepath")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Backup Control", systemImage: "externaldrive.badge.icloud").font(.headline)

            HStack(spacing: 10) {
                if manager.isRunning && !manager.isPaused {
                    Button("Pause", systemImage: "pause.fill") { manager.pauseBackup() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(manager.isPaused ? "Continue" : "Start Backup", systemImage: "play.fill") {
                        manager.resumeBackup(nightMode: false)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Night Mode", systemImage: "moon.stars.fill") {
                    manager.resumeBackup(nightMode: true)
                }
                .buttonStyle(.bordered)
            }

            Toggle("Auto-continue when TGSpeicher opens", isOn: $manager.autoResumeOnLaunch)

            Divider()

            Button("Verify & repair missing Telegram files", systemImage: "checkmark.shield") {
                manager.verifyAndRepairMissingCloudFiles()
            }
            .disabled(manager.isVerifying)

            if manager.isVerifying {
                HStack { ProgressView(); Text(manager.statusText).font(.caption).foregroundStyle(.secondary) }
            }

            Button("Remove backed-up originals from iPhone…", systemImage: "trash", role: .destructive) {
                confirmDeleteLocal = true
            }
            .disabled(manager.deletableAssetCount == 0)

            Text("Deletion is always optional. TGSpeicher only offers Photos items whose required backup resources are mapped to cloud files.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cloud Gallery", systemImage: "photo.stack").font(.headline)
                Spacer()
                Text("\(galleryRecords.count)").foregroundStyle(.secondary)
            }

            if galleryRecords.isEmpty {
                ContentUnavailableView(
                    "No backed-up media yet",
                    systemImage: "photo.stack",
                    description: Text("Start Photo Backup and your Telegram cloud gallery will appear here.")
                )
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 8)], spacing: 8) {
                    ForEach(galleryRecords) { record in
                        Button {
                            selectedCloudFileID = record.cloudFileID
                        } label: {
                            CloudPhotoTile(record: record, manager: manager, cloud: cloud)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
    }
}

private struct PhotoMetric: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.blue)
            Text(value).font(.headline).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .tgGlassCard()
    }
}

private struct CloudPhotoTile: View {
    let record: PhotoBackupRecord
    @ObservedObject var manager: PhotoBackupManager
    @ObservedObject var cloud: CloudStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoLibraryThumbnail(assetIdentifier: record.assetLocalIdentifier, mediaKind: record.mediaKind)
                .frame(height: 112)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.fileName).font(.caption2.weight(.semibold)).lineLimit(1)
                if let file = manager.cloudFile(for: record) {
                    Text(file.totalSize.byteCountString).font(.caption2).opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(7)
        }
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: record.mediaKind == "video" ? "play.circle.fill" : "checkmark.icloud.fill")
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .padding(6)
        }
    }
}

private struct PhotoLibraryThumbnail: View {
    let assetIdentifier: String
    let mediaKind: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: mediaKind == "video" ? "video.fill" : "photo.fill")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: requestThumbnail)
    }

    private func requestThumbnail() {
        guard image == nil,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 260, height: 260),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result { DispatchQueue.main.async { image = result } }
        }
    }
}

private struct NightPhotoBackupScreen: View {
    @ObservedObject var manager: PhotoBackupManager
    @ObservedObject var cloud: CloudStore
    @ObservedObject var telemetry: TelegramTransferTelemetry

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "moon.stars.fill").font(.system(size: 46)).foregroundStyle(.white.opacity(0.9))
                Text("Night Backup").font(.title2.bold()).foregroundStyle(.white)
                Text(manager.currentFileName ?? manager.statusText)
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(2).multilineTextAlignment(.center)

                if let upload = cloud.upload {
                    ProgressView(value: telemetry.fraction)
                        .tint(.white)
                        .frame(maxWidth: 320)
                    HStack(spacing: 16) {
                        Text("\(Int(telemetry.fraction * 100))%").monospacedDigit()
                        Text(telemetry.speedText)
                        Text("ETA \(telemetry.etaText)")
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                    Text(upload.status).font(.caption2).foregroundStyle(.white.opacity(0.5))
                } else if manager.isExportingFromPhotos {
                    ProgressView(value: manager.iCloudProgress).tint(.white).frame(maxWidth: 320)
                    Text("iCloud \(Int(manager.iCloudProgress * 100))%").font(.caption).foregroundStyle(.white.opacity(0.6))
                } else {
                    ProgressView().tint(.white)
                }

                Text("\(manager.backedUpAssets) / \(manager.totalAssets) library items backed up")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                Spacer()
                HStack {
                    Button("Pause", systemImage: "pause.fill") { manager.pauseBackup() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { manager.stopBackup() }
                        .buttonStyle(.bordered)
                }
                .padding(.bottom, 24)
            }
            .padding(24)
        }
        .persistentSystemOverlays(.hidden)
    }
}
