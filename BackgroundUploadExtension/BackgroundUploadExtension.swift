import Foundation
import Photos
import ExtensionFoundation
import Synchronization
import UIKit

@main
final class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension {
    private let terminating = Atomic(false)
    private let library = PHPhotoLibrary.shared()

    required init() {}

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        guard BackgroundRelayShared.enabled,
              let token = BackgroundRelayShared.deviceToken,
              !token.isEmpty else { return .completed }

        BackgroundRelayShared.lastExtensionRun = Date()
        BackgroundRelayShared.extensionStatus = "iOS prüft neue Fotos …"

        if BackgroundRelayShared.chargingOnly {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let battery = UIDevice.current.batteryState
            guard battery == .charging || battery == .full else {
                BackgroundRelayShared.extensionStatus = "Wartet auf Stromversorgung"
                return .completed
            }
        }

        do {
            var madeProgress = false
            madeProgress = try await retryFailedJobs() || madeProgress
            if terminating.load(ordering: .relaxed) { return .processing }
            madeProgress = try await acknowledgeCompletedJobs() || madeProgress
            if terminating.load(ordering: .relaxed) { return .processing }
            let queued = try await createNewUploadJobs(token: token)
            madeProgress = queued > 0 || madeProgress
            BackgroundRelayShared.extensionStatus = queued > 0 ? "\(queued) Hintergrund-Uploads eingereiht" : "Mediathek überwacht"
            return madeProgress ? .processing : .completed
        } catch PHPhotosError.limitExceeded {
            BackgroundRelayShared.extensionStatus = "Upload-Warteschlange ist gefüllt"
            return .processing
        } catch {
            var index = BackgroundRelayIndexStore.load()
            index.lastError = error.localizedDescription
            index.lastRun = Date()
            BackgroundRelayIndexStore.save(index)
            BackgroundRelayShared.lastServerError = "Background-Extension: \(error.localizedDescription)"
            BackgroundRelayShared.extensionStatus = "Fehler – iOS versucht es später erneut"
            return .failure
        }
    }

    func willTerminate() async {
        terminating.store(true, ordering: .relaxed)
        BackgroundRelayShared.extensionStatus = "Background-Extension wurde von iOS pausiert"
    }

    private func retryFailedJobs() async throws -> Bool {
        let jobs = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)
        guard jobs.count > 0 else { return false }
        for i in 0..<jobs.count {
            if terminating.load(ordering: .relaxed) { break }
            let job = jobs.object(at: i)
            if let error = job.error as? URLError,
               error.code == .badServerResponse || error.code == .userAuthenticationRequired {
                try await library.performChanges {
                    PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
                }
            } else {
                try await library.performChanges {
                    PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: nil)
                }
            }
        }
        return true
    }

    private func acknowledgeCompletedJobs() async throws -> Bool {
        let jobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        guard jobs.count > 0 else { return false }
        var state = BackgroundRelayIndexStore.load()
        for i in 0..<jobs.count {
            if terminating.load(ordering: .relaxed) { break }
            let job = jobs.object(at: i)
            if let resource = PHAssetResource.assetResource(forUploadJob: job), job.error == nil {
                let key = BackgroundRelayShared.resourceKey(resource)
                state.completedKeys.insert(key)
                state.lastSuccess = Date()
                BackgroundRelayShared.lastSuccessfulDelivery = state.lastSuccess
                BackgroundRelayShared.lastServerContact = Date()
                BackgroundRelayShared.lastServerError = nil
            }
            try await library.performChanges {
                PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
            }
        }
        state.lastRun = Date()
        BackgroundRelayIndexStore.save(state)
        return true
    }

    private func createNewUploadJobs(token: String) async throws -> Int {
        let inflight = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil)
        let capacity = max(0, PHAssetResourceUploadJob.jobLimit - inflight.count)
        guard capacity > 0 else { return 0 }

        var activeKeys = Set<String>()
        for i in 0..<inflight.count {
            if let resource = PHAssetResource.assetResource(forUploadJob: inflight.object(at: i)) {
                activeKeys.insert(BackgroundRelayShared.resourceKey(resource))
            }
        }

        var state = BackgroundRelayIndexStore.load()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        if assets.count < state.lastKnownAssetCount || state.scanCursor >= assets.count { state.scanCursor = 0 }
        state.lastKnownAssetCount = assets.count

        var candidates: [(PHAsset, PHAssetResource)] = []
        var cursor = min(state.scanCursor, assets.count)
        var seenResources = 0
        let batchLimit = min(capacity, 64)

        while cursor < assets.count && candidates.count < batchLimit && !terminating.load(ordering: .relaxed) {
            let asset = assets.object(at: cursor)
            for resource in BackgroundRelayShared.preferredResources(for: asset) {
                seenResources += 1
                let key = BackgroundRelayShared.resourceKey(resource, asset: asset)
                if !state.completedKeys.contains(key) && !activeKeys.contains(key) {
                    candidates.append((asset, resource))
                    activeKeys.insert(key)
                    if candidates.count >= batchLimit { break }
                }
            }
            cursor += 1
        }

        state.scanCursor = cursor >= assets.count ? 0 : cursor
        state.lastSeenResources += seenResources
        state.lastQueuedCount = candidates.count
        state.lastRun = Date()
        BackgroundRelayIndexStore.save(state)
        guard !candidates.isEmpty else { return 0 }

        try await library.performChanges {
            for (asset, resource) in candidates {
                guard !self.terminating.load(ordering: .relaxed) else { break }
                var request = URLRequest(url: URL(string: BackgroundRelayShared.baseURLString + "/upload")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 60 * 60
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(BackgroundRelayShared.resourceKey(resource, asset: asset), forHTTPHeaderField: "X-TG-Resource-Key")
                request.setValue(resource.assetLocalIdentifier, forHTTPHeaderField: "X-TG-Asset-ID")
                request.setValue(String(resource.type.rawValue), forHTTPHeaderField: "X-TG-Resource-Type")
                request.setValue(BackgroundRelayShared.mediaKind(asset: asset, resource: resource), forHTTPHeaderField: "X-TG-Media-Kind")
                let filename = BackgroundRelayShared.resourceName(resource, asset: asset)
                let encoded = Data(filename.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                request.setValue(encoded, forHTTPHeaderField: "X-TG-Filename-B64")
                if let date = asset.creationDate { request.setValue(ISO8601DateFormatter().string(from: date), forHTTPHeaderField: "X-TG-Creation-Date") }
                _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: request, resource: resource)
            }
        }
        return candidates.count
    }
}
