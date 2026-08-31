import Foundation
import SwiftUI
import AVKit
import UniformTypeIdentifiers
import UIKit

private enum TGTelegramFileResolver {
    static func resolveSingleChunk(
        file: CloudFileEntry,
        telegram: TelegramClient,
        completion: @escaping (Result<(fileID: Int, size: Int64), Error>) -> Void
    ) {
        guard file.chunks.count == 1, let chunk = file.chunks.first else {
            completion(.failure(NSError(domain: "TGSpeicher.Stream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Streaming currently requires a single Telegram chunk. Large multi-part files can still be downloaded normally."])))
            return
        }

        if let id = chunk.telegramFileID {
            completion(.success((id, max(file.totalSize, chunk.size))))
            return
        }

        guard let chatID = telegram.savedMessagesChatID, let messageID = chunk.telegramMessageID else {
            completion(.failure(NSError(domain: "TGSpeicher.Stream", code: 2, userInfo: [NSLocalizedDescriptionKey: "The Telegram message reference for this media file is missing."])))
            return
        }

        telegram.send(["@type": "getMessage", "chat_id": chatID, "message_id": messageID]) { response in
            if response["@type"] as? String == "error" {
                completion(.failure(NSError(domain: "TGSpeicher.Stream", code: 3, userInfo: [NSLocalizedDescriptionKey: response["message"] as? String ?? "Telegram could not resolve this media file."])))
                return
            }
            guard let info = fileInfo(fromMessage: response), let id = info.fileID else {
                completion(.failure(NSError(domain: "TGSpeicher.Stream", code: 4, userInfo: [NSLocalizedDescriptionKey: "Telegram returned no file identifier for this media."])))
                return
            }
            completion(.success((id, info.size > 0 ? info.size : file.totalSize)))
        }
    }

    private static func fileInfo(fromMessage message: [String: Any]) -> (fileID: Int?, size: Int64)? {
        guard let content = message["content"] as? [String: Any] else { return nil }
        if content["@type"] as? String == "messageDocument",
           let document = content["document"] as? [String: Any],
           let file = document["document"] as? [String: Any] {
            return (
                TelegramClient.int(file["id"]),
                TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
            )
        }
        if content["@type"] as? String == "messageVideo",
           let video = content["video"] as? [String: Any],
           let file = video["video"] as? [String: Any] {
            return (
                TelegramClient.int(file["id"]),
                TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
            )
        }
        if content["@type"] as? String == "messagePhoto",
           let photo = content["photo"] as? [String: Any],
           let sizes = photo["sizes"] as? [[String: Any]],
           let largest = sizes.max(by: { (TelegramClient.int64(($0["photo"] as? [String: Any])?["size"]) ?? 0) < (TelegramClient.int64(($1["photo"] as? [String: Any])?["size"]) ?? 0) }),
           let file = largest["photo"] as? [String: Any] {
            return (
                TelegramClient.int(file["id"]),
                TelegramClient.int64(file["size"]) ?? TelegramClient.int64(file["expected_size"]) ?? 0
            )
        }
        return nil
    }
}

final class TelegramStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let file: CloudFileEntry
    private let telegram: TelegramClient
    private let delegateQueue: DispatchQueue
    private var resolvedFileID: Int?
    private var resolvedSize: Int64
    private var resolutionInFlight = false
    private var waitingResolutions: [(Result<(Int, Int64), Error>) -> Void] = []

    init(file: CloudFileEntry, telegram: TelegramClient, queue: DispatchQueue) {
        self.file = file
        self.telegram = telegram
        self.delegateQueue = queue
        self.resolvedSize = file.totalSize
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            let fallbackType = file.isTGVideo ? UTType.movie.identifier : UTType.data.identifier
            info.contentType = file.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? fallbackType
            info.contentLength = max(0, resolvedSize > 0 ? resolvedSize : file.totalSize)
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let requestedOffset = max(0, dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset)
        let wanted = max(1, dataRequest.requestedLength)

        resolveFile { [weak self, weak loadingRequest] result in
            guard let self, let loadingRequest else { return }
            self.delegateQueue.async {
                switch result {
                case .failure(let error):
                    loadingRequest.finishLoading(with: error)
                case .success(let tuple):
                    self.downloadRange(fileID: tuple.0, offset: requestedOffset, length: wanted, loadingRequest: loadingRequest)
                }
            }
        }
        return true
    }

    private func resolveFile(completion: @escaping (Result<(Int, Int64), Error>) -> Void) {
        if let resolvedFileID {
            completion(.success((resolvedFileID, resolvedSize)))
            return
        }
        waitingResolutions.append(completion)
        guard !resolutionInFlight else { return }
        resolutionInFlight = true

        TGTelegramFileResolver.resolveSingleChunk(file: file, telegram: telegram) { [weak self] result in
            guard let self else { return }
            self.delegateQueue.async {
                self.resolutionInFlight = false
                if case .success(let value) = result {
                    self.resolvedFileID = value.fileID
                    self.resolvedSize = value.size
                }
                let waiting = self.waitingResolutions
                self.waitingResolutions.removeAll()
                let bridged = result.map { ($0.fileID, $0.size) }
                waiting.forEach { $0(bridged) }
            }
        }
    }

    private func downloadRange(fileID: Int, offset: Int64, length: Int, loadingRequest: AVAssetResourceLoadingRequest) {
        telegram.send([
            "@type": "downloadFile",
            "file_id": fileID,
            "priority": 32,
            "offset": offset,
            "limit": Int64(length),
            "synchronous": true
        ]) { [weak self, weak loadingRequest] response in
            guard let self, let loadingRequest else { return }
            self.delegateQueue.async {
                if response["@type"] as? String == "error" {
                    loadingRequest.finishLoading(with: NSError(domain: "TGSpeicher.Stream", code: 5, userInfo: [NSLocalizedDescriptionKey: response["message"] as? String ?? "Telegram range download failed."]))
                    return
                }
                guard let local = response["local"] as? [String: Any],
                      let path = local["path"] as? String,
                      !path.isEmpty else {
                    loadingRequest.finishLoading(with: NSError(domain: "TGSpeicher.Stream", code: 6, userInfo: [NSLocalizedDescriptionKey: "Telegram returned no local cache path for the requested media range."]))
                    return
                }

                do {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    let data = try handle.read(upToCount: length) ?? Data()
                    guard !data.isEmpty else {
                        throw NSError(domain: "TGSpeicher.Stream", code: 7, userInfo: [NSLocalizedDescriptionKey: "The requested Telegram media range is not available yet."])
                    }
                    loadingRequest.dataRequest?.respond(with: data)
                    loadingRequest.finishLoading()
                } catch {
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
    }
}

@MainActor
final class TelegramVideoStreamController: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published var errorMessage: String?

    private var loader: TelegramStreamResourceLoader?
    private let loaderQueue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.media-stream", qos: .userInitiated)

    init(file: CloudFileEntry, telegram: TelegramClient) {
        guard file.chunks.count == 1 else {
            errorMessage = "This video is stored in multiple Telegram chunks. Use Download for this file; single-part videos can stream immediately."
            return
        }
        guard let url = URL(string: "tgspeicher-stream://media/\(file.id.uuidString)") else {
            errorMessage = "Could not create the streaming URL."
            return
        }
        let asset = AVURLAsset(url: url)
        let loader = TelegramStreamResourceLoader(file: file, telegram: telegram, queue: loaderQueue)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        self.loader = loader
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    func play() { player.play() }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil) }
}

@MainActor
final class TelegramCloudImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let file: CloudFileEntry
    private let telegram: TelegramClient

    init(file: CloudFileEntry, telegram: TelegramClient) {
        self.file = file
        self.telegram = telegram
    }

    func load() {
        guard !isLoading, image == nil else { return }
        isLoading = true
        TGTelegramFileResolver.resolveSingleChunk(file: file, telegram: telegram) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            case .success(let value):
                self.telegram.send([
                    "@type": "downloadFile",
                    "file_id": value.fileID,
                    "priority": 32,
                    "offset": 0,
                    "limit": 0,
                    "synchronous": true
                ]) { [weak self] response in
                    guard let self else { return }
                    self.isLoading = false
                    if response["@type"] as? String == "error" {
                        self.errorMessage = response["message"] as? String ?? "Telegram image download failed."
                        return
                    }
                    guard let local = response["local"] as? [String: Any],
                          let path = local["path"] as? String,
                          !path.isEmpty,
                          let image = UIImage(contentsOfFile: path) else {
                        self.errorMessage = "The Telegram image could not be decoded."
                        return
                    }
                    self.image = image
                }
            }
        }
    }
}

struct CloudMediaPreviewSheet: View {
    let file: CloudFileEntry
    let telegram: TelegramClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if file.isTGVideo {
                    TelegramVideoStreamView(file: file, telegram: telegram)
                } else if file.isTGImage {
                    TelegramCloudImageView(file: file, telegram: telegram)
                } else {
                    ContentUnavailableView("No cloud stream", systemImage: "doc", description: Text("Use Download + Preview for this file type."))
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }
}

private struct TelegramVideoStreamView: View {
    @StateObject private var controller: TelegramVideoStreamController

    init(file: CloudFileEntry, telegram: TelegramClient) {
        _controller = StateObject(wrappedValue: TelegramVideoStreamController(file: file, telegram: telegram))
    }

    var body: some View {
        Group {
            if let error = controller.errorMessage {
                ContentUnavailableView("Streaming unavailable", systemImage: "play.slash", description: Text(error))
            } else {
                VideoPlayer(player: controller.player)
                    .background(.black)
                    .onAppear { controller.play() }
                    .onDisappear { controller.stop() }
            }
        }
    }
}

private struct TelegramCloudImageView: View {
    @StateObject private var loader: TelegramCloudImageLoader

    init(file: CloudFileEntry, telegram: TelegramClient) {
        _loader = StateObject(wrappedValue: TelegramCloudImageLoader(file: file, telegram: telegram))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let error = loader.errorMessage {
                ContentUnavailableView("Preview failed", systemImage: "photo.badge.exclamationmark", description: Text(error))
                    .foregroundStyle(.white)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading from Telegram…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { loader.load() }
    }
}
