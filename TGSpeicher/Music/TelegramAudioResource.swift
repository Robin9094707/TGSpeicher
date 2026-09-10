import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Serial, bounded AVAsset range reader backed by Telegram/TDLib.
/// Malformed or legacy catalog entries must fail with an error instead of trapping.
final class TelegramAudioResource: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "TGSpeicher.audio.ranges", qos: .userInitiated)

    private let telegram: TelegramClient
    private let file: CloudFileEntry
    private let chatID: Int64
    private let chunks: [CloudChunk]
    private let messageIDs: [Int64]
    private let map: MusicRangeMap
    private let virtualURL: URL
    private let byteBudget: Int?

    private var pending: [AVAssetResourceLoadingRequest] = []
    private var fileIDs: [Int: Int] = [:]
    private var busy = false
    private var stopped = false
    private var requestedBytes = 0

    init(file: CloudFileEntry, accountID: Int64, telegram: TelegramClient, byteBudget: Int? = nil) throws {
        guard file.isComplete else {
            throw RecoveryError.invalid("Dieser Titel ist noch nicht vollständig gesichert.")
        }
        let sorted = file.chunks.sorted { $0.index < $1.index }
        guard !sorted.isEmpty,
              sorted.allSatisfy({ $0.size > 0 && ($0.telegramMessageID ?? 0) > 0 }),
              sorted.enumerated().allSatisfy({ offset, chunk in
                  chunk.index > 0 && chunk.count == sorted.count && chunk.index == offset + 1
              }) else {
            throw RecoveryError.invalid("Dieser Musiktitel hat unvollständige Telegram-Referenzen. Bitte den Katalog aktualisieren oder die Datei erneut sichern.")
        }
        guard let url = URL(string: "tgs-audio://track/\(file.id.uuidString)") else {
            throw RecoveryError.invalid("Für diesen Titel konnte keine sichere Streaming-Adresse erstellt werden.")
        }

        self.file = file
        self.telegram = telegram
        self.chatID = file.telegramChatID ?? accountID
        self.chunks = sorted
        self.messageIDs = sorted.compactMap(\.telegramMessageID)
        self.map = try MusicRangeMap(sizes: sorted.map(\.size), total: file.totalSize)
        self.virtualURL = url
        self.byteBudget = byteBudget
        super.init()
    }

    func asset() -> AVURLAsset {
        let asset = AVURLAsset(url: virtualURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.busy = false
            let requests = self.pending
            self.pending.removeAll()
            for request in requests where !request.isCancelled && !request.isFinished {
                request.finishLoading(with: URLError(.cancelled))
            }
        }
    }

    func resourceLoader(
        _ loader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !stopped else {
            request.finishLoading(with: URLError(.cancelled))
            return true
        }

        if let info = request.contentInformationRequest {
            let ext = (file.name as NSString).pathExtension
            info.contentType = (UTType(filenameExtension: ext)
                ?? file.mimeType.flatMap { UTType(mimeType: $0) }
                ?? .audio).identifier
            info.contentLength = map.total
            info.isByteRangeAccessSupported = true
        }

        guard request.dataRequest != nil else {
            request.finishLoading()
            return true
        }

        // AVFoundation normally keeps only a few requests alive. A hard ceiling prevents
        // a corrupt asset/parser from building an unbounded retained request array.
        guard pending.count < 32 else {
            request.finishLoading(with: RecoveryError.invalid("Zu viele gleichzeitige Audio-Anfragen. Bitte den Titel erneut starten."))
            return true
        }
        pending.append(request)
        schedulePump()
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
        schedulePump()
    }

    private func schedulePump() {
        queue.async { [weak self] in self?.pump() }
    }

    private func pump() {
        guard !busy, !stopped else { return }
        while let request = pending.first {
            if request.isCancelled || request.isFinished {
                pending.removeFirst()
                continue
            }
            guard let dataRequest = request.dataRequest else {
                finish(request)
                return
            }

            let requestedOffset = dataRequest.requestedOffset
            let requestedLength = dataRequest.requestedLength
            guard requestedOffset >= 0, requestedLength >= 0 else {
                finish(request, error: RecoveryError.invalid("Ungültige Audio-Anfrage."))
                return
            }
            let end = requestedOffset.addingReportingOverflow(Int64(requestedLength))
            guard !end.overflow else {
                finish(request, error: RecoveryError.invalid("Die Audio-Anfrage ist zu groß."))
                return
            }

            let offset = max(dataRequest.currentOffset, requestedOffset)
            let limit = dataRequest.requestsAllDataToEndOfResource
                ? map.total
                : min(map.total, end.partialValue)
            do {
                guard let slice = try map.slice(offset: offset, remaining: max(0, limit - offset)) else {
                    finish(request)
                    return
                }
                if let byteBudget {
                    guard slice.count <= byteBudget, requestedBytes <= byteBudget - slice.count else {
                        finish(request, error: RecoveryError.invalid("Metadaten-Vorladen wurde aus Stabilitätsgründen begrenzt."))
                        return
                    }
                }
                requestedBytes += slice.count
                busy = true
                resolve(slice.chunk) { [weak self, weak request] result in
                    guard let self else { return }
                    guard !self.stopped, let request, !request.isCancelled else {
                        self.busy = false
                        self.schedulePump()
                        return
                    }
                    switch result {
                    case .failure(let error):
                        self.busy = false
                        self.finish(request, error: error)
                    case .success(let id):
                        self.read(id: id, slice: slice, request: request, attempt: 0)
                    }
                }
                return
            } catch {
                finish(request, error: error)
                return
            }
        }
    }

    private func resolve(_ chunk: Int, completion: @escaping (Result<Int, Error>) -> Void) {
        guard messageIDs.indices.contains(chunk), chunks.indices.contains(chunk) else {
            completion(.failure(RecoveryError.invalid("Ungültiger Audio-Dateiteil.")))
            return
        }
        if let id = fileIDs[chunk] {
            completion(.success(id))
            return
        }

        call(["@type": "getMessage", "chat_id": chatID, "message_id": messageIDs[chunk]]) { [weak self] result in
            guard let self else { return }
            do {
                let message = try result.get()
                let content = message["content"] as? [String: Any] ?? [:]
                var media: [String: Any]?
                for key in ["document", "audio", "video", "voice_note"] {
                    guard let outer = content[key] as? [String: Any] else { continue }
                    let innerKey = key == "voice_note" ? "voice" : key
                    if let inner = outer[innerKey] as? [String: Any] {
                        media = inner
                        break
                    }
                }
                guard let media,
                      let id = TelegramClient.int(media["id"]), id > 0 else {
                    throw RecoveryError.invalid("Der Musiktitel wurde in Telegram nicht gefunden. Bitte den Katalog aktualisieren.")
                }
                if let size = TelegramClient.int64(media["size"]), size > 0, size != self.chunks[chunk].size {
                    throw RecoveryError.invalid("Die Telegram-Datei passt nicht mehr zum gesicherten Titel.")
                }
                self.fileIDs[chunk] = id
                completion(.success(id))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func read(id: Int, slice: MusicRangeMap.Slice, request: AVAssetResourceLoadingRequest, attempt: Int) {
        guard !stopped, !request.isCancelled, !request.isFinished else {
            busy = false
            schedulePump()
            return
        }

        call([
            "@type": "downloadFile",
            "file_id": id,
            "priority": 32,
            "offset": slice.offset,
            "limit": slice.count,
            "synchronous": true
        ]) { [weak self, weak request] result in
            guard let self, let request else { return }
            guard !self.stopped, !request.isCancelled, !request.isFinished else {
                self.busy = false
                self.schedulePump()
                return
            }

            switch result {
            case .failure(let error):
                self.busy = false
                self.finish(request, error: error)
            case .success(let response):
                let path = (response["local"] as? [String: Any])?["path"] as? String ?? ""
                self.call(["@type": "getFileDownloadedPrefixSize", "file_id": id, "offset": slice.offset]) { [weak self, weak request] prefixResult in
                    guard let self, let request else { return }
                    guard !self.stopped, !request.isCancelled, !request.isFinished else {
                        self.busy = false
                        self.schedulePump()
                        return
                    }
                    do {
                        let prefix = TelegramClient.int64(try prefixResult.get()["size"]) ?? 0
                        if prefix < Int64(slice.count), attempt < 2 {
                            self.queue.asyncAfter(deadline: .now() + 0.35) { [weak self, weak request] in
                                guard let self, let request, !self.stopped else { return }
                                self.read(id: id, slice: slice, request: request, attempt: attempt + 1)
                            }
                            return
                        }
                        let data = try MusicRangeMap.verifiedRead(
                            path: path,
                            offset: slice.offset,
                            count: slice.count,
                            downloadedPrefix: prefix
                        )
                        guard !request.isCancelled, !request.isFinished else {
                            self.busy = false
                            self.schedulePump()
                            return
                        }
                        request.dataRequest?.respond(with: data)
                        self.busy = false
                        self.pending.removeAll { $0 === request }
                        if !request.isCancelled && !request.isFinished { self.pending.append(request) }
                        self.schedulePump()
                    } catch {
                        self.busy = false
                        self.finish(request, error: error)
                    }
                }
            }
        }
    }

    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error? = nil) {
        pending.removeAll { $0 === request }
        if !request.isCancelled && !request.isFinished {
            if let error { request.finishLoading(with: error) }
            else { request.finishLoading() }
        }
        busy = false
        schedulePump()
    }

    /// Completes at most once and times out so a lost TDLib callback cannot retain an
    /// AVFoundation loading request forever.
    private func call(_ body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var completed = false // Accessed only on `queue`.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !completed else { return }
            completed = true
            completion(.failure(RecoveryError.invalid("Telegram antwortet gerade nicht. Bitte Verbindung prüfen und erneut abspielen.")))
        }
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.telegram.send(body) { [weak self] response in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped, !completed else { return }
                    completed = true
                    timeout.cancel()
                    if response["@type"] as? String == "error" {
                        completion(.failure(RecoveryError.invalid("Der Audiobereich konnte nicht von Telegram geladen werden. Bitte Verbindung und Zugriff prüfen.")))
                    } else {
                        completion(.success(response))
                    }
                }
            }
        }
    }
}
