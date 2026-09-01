import SwiftUI
import Photos
import Combine

@MainActor
private final class TGCloudGalleryModel: ObservableObject {
    @Published private(set) var records: [PhotoBackupRecord] = []
    @Published private(set) var sizeByCloudFileID: [UUID: Int64] = [:]
    @Published private(set) var isPreparing = true

    private weak var manager: PhotoBackupManager?
    private weak var cloud: CloudStore?
    private var cancellables = Set<AnyCancellable>()
    private var generation = 0
    private var representedAssetIDs = Set<String>()

    init(manager: PhotoBackupManager, cloud: CloudStore) {
        self.manager = manager
        self.cloud = cloud

        manager.$latestCompletedRecord
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] record in self?.apply(record) }
            .store(in: &cancellables)

        manager.$isScanningLibrary
            .removeDuplicates()
            .filter { !$0 }
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func refresh() {
        guard let manager, let cloud else { return }
        generation += 1
        let token = generation
        let source = manager.galleryRecordSnapshot()
        let files = cloud.index.files
        if records.isEmpty { isPreparing = true }

        DispatchQueue.global(qos: .userInitiated).async {
            let grouped = Dictionary(grouping: source, by: { $0.assetLocalIdentifier })
            let result = grouped.values
                .compactMap { group in group.first(where: { $0.mediaKind == "photo" }) ?? group.first }
                .sorted { $0.uploadedAt > $1.uploadedAt }
            let representedIDs = Set(result.map(\.assetLocalIdentifier))
            let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.totalSize) })

            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.records = result
                self.representedAssetIDs = representedIDs
                self.sizeByCloudFileID = sizes
                self.isPreparing = false
            }
        }
    }

    private func apply(_ record: PhotoBackupRecord) {
        if representedAssetIDs.insert(record.assetLocalIdentifier).inserted {
            records.insert(record, at: 0)
            return
        }
        guard record.mediaKind == "photo",
              let index = records.firstIndex(where: {
                  $0.assetLocalIdentifier == record.assetLocalIdentifier && $0.mediaKind != "photo"
              }) else { return }
        records.remove(at: index)
        records.insert(record, at: 0)
    }
}

struct PhotoBackupView: View {
    @ObservedObject var manager: PhotoBackupManager
    let cloud: CloudStore
    @ObservedObject var telemetry: TelegramTransferTelemetry

    @StateObject private var galleryModel: TGCloudGalleryModel
    @State private var selectedCloudFileID: UUID?
    @State private var confirmDeleteLocal = false

    init(manager: PhotoBackupManager, cloud: CloudStore, telemetry: TelegramTransferTelemetry) {
        self.manager = manager
        self.cloud = cloud
        self.telemetry = telemetry
        _galleryModel = StateObject(wrappedValue: TGCloudGalleryModel(manager: manager, cloud: cloud))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if manager.hasLibraryAccess {
                    statistics
                    controls
                    CloudGallerySection(
                        model: galleryModel,
                        selectedCloudFileID: $selectedCloudFileID
                    )
                    .equatable()
                } else {
                    permissionCard
                }
            }
            .padding(14)
        }
        .navigationTitle("Photo Backup")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    manager.refreshLibrary()
                    galleryModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!manager.hasLibraryAccess)
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedCloudFileID != nil },
            set: { if !$0 { selectedCloudFileID = nil } }
        )) {
            if let selectedCloudFileID,
               let file = cloud.index.files.first(where: { $0.id == selectedCloudFileID }) {
                CloudMediaPreviewSheet(file: file, cloud: cloud)
            }
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
                    Text(manager.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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

private struct CloudGallerySection: View, Equatable {
    @ObservedObject var model: TGCloudGalleryModel
    @Binding var selectedCloudFileID: UUID?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var visibleLimit = 60

    static func == (lhs: CloudGallerySection, rhs: CloudGallerySection) -> Bool {
        lhs.model === rhs.model
    }

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 5 : 3
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: count)
    }

    private var visibleRecords: ArraySlice<PhotoBackupRecord> {
        model.records.prefix(visibleLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cloud Gallery", systemImage: "photo.stack").font(.headline)
                Spacer()
                if model.isPreparing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(model.records.count)").foregroundStyle(.secondary)
                }
            }

            if model.isPreparing && model.records.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing gallery efficiently…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if model.records.isEmpty {
                ContentUnavailableView(
                    "No backed-up media yet",
                    systemImage: "photo.stack",
                    description: Text("Start Photo Backup and your Telegram cloud gallery will appear here.")
                )
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(visibleRecords) { record in
                        Button {
                            selectedCloudFileID = record.cloudFileID
                        } label: {
                            CloudPhotoTile(
                                record: record,
                                size: model.sizeByCloudFileID[record.cloudFileID]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.records.count > visibleLimit {
                    GalleryLoadSentinel(remaining: model.records.count - visibleLimit) {
                        visibleLimit = min(model.records.count, visibleLimit + 60)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tgGlassCard()
        .onChange(of: model.records.count) { _, count in
            if count < visibleLimit { visibleLimit = max(60, count) }
        }
    }
}

private struct CloudPhotoTile: View {
    let record: PhotoBackupRecord
    let size: Int64?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                PhotoLibraryThumbnail(assetIdentifier: record.assetLocalIdentifier, mediaKind: record.mediaKind)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.04), .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(record.fileName)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    if let size {
                        Text(size.byteCountString)
                            .font(.system(size: 9, weight: .medium))
                            .opacity(0.82)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(6)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: record.mediaKind == "video" ? "play.circle.fill" : "checkmark.icloud.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private final class TGPhotoThumbnailPipeline {
    static let shared = TGPhotoThumbnailPipeline()

    private let imageManager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        imageManager.allowsCachingHighQualityImages = false
        cache.countLimit = 180
        cache.totalCostLimit = 36 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    func request(
        assetIdentifier: String,
        targetSize: CGSize,
        completion: @escaping (UIImage?, Bool) -> Void
    ) -> PHImageRequestID? {
        let key = "\(assetIdentifier)|\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        if let cached = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(cached, true) }
            return nil
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            DispatchQueue.main.async { completion(nil, true) }
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] result, info in
            guard let self else { return }
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !cancelled else { return }
            if let result {
                let cost = Int(result.size.width * result.size.height * 4)
                self.cache.setObject(result, forKey: key, cost: cost)
            }
            DispatchQueue.main.async { completion(result, true) }
        }
    }

    func cancel(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }
}

private struct PhotoLibraryThumbnail: View {
    let assetIdentifier: String
    let mediaKind: String
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Rectangle().fill(.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: mediaKind == "video" ? "video.fill" : "photo.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .onAppear(perform: requestThumbnail)
        .onDisappear {
            if let requestID {
                TGPhotoThumbnailPipeline.shared.cancel(requestID)
                self.requestID = nil
            }
        }
    }

    private func requestThumbnail() {
        guard image == nil, requestID == nil else { return }
        requestID = TGPhotoThumbnailPipeline.shared.request(
            assetIdentifier: assetIdentifier,
            targetSize: CGSize(
                width: 160 * min(UIScreen.main.scale, 2),
                height: 160 * min(UIScreen.main.scale, 2)
            )
        ) { result, isFinal in
            if let result { image = result }
            if isFinal { requestID = nil }
        }
    }
}

private struct GalleryLoadSentinel: View {
    let remaining: Int
    let load: () -> Void
    @State private var didTrigger = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(remaining) more items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .onAppear {
            guard !didTrigger else { return }
            didTrigger = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { load() }
        }
    }
}

struct NightPhotoBackupScreen: View {
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
