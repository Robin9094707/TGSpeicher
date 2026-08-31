import Foundation
import Combine

@MainActor
final class TelegramTransferTelemetry: ObservableObject {
    @Published private(set) var uploadedBytes: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var etaSeconds: TimeInterval?
    @Published private(set) var activeTelegramFileID: Int?

    private let cloud: CloudStore
    private let telegram: TelegramClient
    private var observerID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var lastPart = 0
    private var lastSampleBytes: Int64 = 0
    private var lastSampleDate = Date()

    init(cloud: CloudStore, telegram: TelegramClient) {
        self.cloud = cloud
        self.telegram = telegram

        observerID = telegram.addUpdateObserver { [weak self] update in
            Task { @MainActor in self?.handle(update) }
        }

        cloud.$upload
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                guard let self else { return }
                guard let progress else {
                    self.reset()
                    return
                }

                if progress.currentPart != self.lastPart {
                    self.lastPart = progress.currentPart
                    self.activeTelegramFileID = nil
                    self.uploadedBytes = progress.completedBytes
                    self.lastSampleBytes = progress.completedBytes
                    self.lastSampleDate = Date()
                } else if self.uploadedBytes < progress.completedBytes {
                    self.uploadedBytes = progress.completedBytes
                    self.sample(progress.completedBytes, total: progress.totalBytes)
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let observerID { telegram.removeUpdateObserver(observerID) }
    }

    var fraction: Double {
        guard let progress = cloud.upload, progress.totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(max(uploadedBytes, progress.completedBytes)) / Double(progress.totalBytes)))
    }

    var speedText: String {
        guard bytesPerSecond > 1 else { return "Waiting for Telegram…" }
        return Int64(bytesPerSecond).byteCountString + "/s"
    }

    var etaText: String {
        guard let etaSeconds, etaSeconds.isFinite, etaSeconds >= 0 else { return "—" }
        if etaSeconds < 60 { return "~\(max(1, Int(etaSeconds)))s" }
        if etaSeconds < 3600 { return "~\(Int(ceil(etaSeconds / 60))) min" }
        return "~\(Int(etaSeconds / 3600))h \(Int(etaSeconds.truncatingRemainder(dividingBy: 3600) / 60))m"
    }

    private func handle(_ update: [String: Any]) {
        guard update["@type"] as? String == "updateFile",
              let progress = cloud.upload,
              let file = update["file"] as? [String: Any],
              let fileID = TelegramClient.int(file["id"]),
              let remote = file["remote"] as? [String: Any] else { return }

        let isActive = remote["is_uploading_active"] as? Bool ?? false
        let uploaded = TelegramClient.int64(remote["uploaded_size"]) ?? 0

        if activeTelegramFileID == nil {
            guard isActive else { return }
            activeTelegramFileID = fileID
            lastSampleBytes = progress.completedBytes
            lastSampleDate = Date()
        }

        guard activeTelegramFileID == fileID else { return }

        let partSize = TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
        let boundedPartBytes = partSize > 0 ? min(uploaded, partSize) : uploaded
        let candidate = min(progress.totalBytes, max(progress.completedBytes, progress.completedBytes + boundedPartBytes))
        uploadedBytes = max(uploadedBytes, candidate)
        sample(uploadedBytes, total: progress.totalBytes)

        if remote["is_uploading_completed"] as? Bool == true {
            activeTelegramFileID = nil
        }
    }

    private func sample(_ bytes: Int64, total: Int64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleDate)
        guard elapsed >= 0.20 else { return }

        let delta = max(0, bytes - lastSampleBytes)
        if delta > 0 {
            let instant = Double(delta) / elapsed
            bytesPerSecond = bytesPerSecond > 0 ? (bytesPerSecond * 0.72 + instant * 0.28) : instant
            if bytesPerSecond > 1 {
                etaSeconds = Double(max(0, total - bytes)) / bytesPerSecond
            }
        }

        lastSampleBytes = bytes
        lastSampleDate = now
    }

    private func reset() {
        uploadedBytes = 0
        bytesPerSecond = 0
        etaSeconds = nil
        activeTelegramFileID = nil
        lastPart = 0
        lastSampleBytes = 0
        lastSampleDate = Date()
    }
}
