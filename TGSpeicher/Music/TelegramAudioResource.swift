import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// One serial bounded reader per asset. Never trusts a session-old TDLib file ID or sparse-file length.
final class TelegramAudioResource: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "TGSpeicher.audio.ranges", qos: .userInitiated)
    private let telegram: TelegramClient
    private let file: CloudFileEntry
    private let chatID: Int64
    private let chunks: [CloudChunk]
    private let map: MusicRangeMap
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var fileIDs: [Int: Int] = [:]
    private var busy = false
    private var stopped = false
    private let byteBudget: Int?
    private var requestedBytes = 0

    init(file: CloudFileEntry, accountID: Int64, telegram: TelegramClient, byteBudget: Int? = nil) throws {
        self.byteBudget = byteBudget
        guard file.isComplete else { throw RecoveryError.invalid("Dieser Titel ist noch nicht vollständig gesichert.") }
        self.file = file; self.telegram = telegram; self.chatID = file.telegramChatID ?? accountID
        chunks = file.chunks.sorted { $0.index < $1.index }
        map = try MusicRangeMap(sizes: chunks.map(\.size), total: file.totalSize)
        super.init()
    }

    func asset() -> AVURLAsset {
        let ext = (file.name as NSString).pathExtension
        let url = URL(string: "tgs-audio://track/\(file.id.uuidString).\(ext.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "audio")")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending.forEach { $0.finishLoading(with: URLError(.cancelled)) }
            pending.removeAll()
        }
        // Do not cancelDownloadFile: TDLib's cache may be shared by another consumer.
        // At most the current 512 KiB request finishes; no further ranges are scheduled.
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped else { request.finishLoading(with: URLError(.cancelled)); return true }
        if let info = request.contentInformationRequest {
            let ext = (file.name as NSString).pathExtension
            info.contentType = (UTType(filenameExtension: ext) ?? file.mimeType.flatMap { UTType(mimeType: $0) } ?? .audio).identifier
            info.contentLength = map.total
            info.isByteRangeAccessSupported = true
        }
        guard request.dataRequest != nil else { request.finishLoading(); return true }
        pending.append(request)
        pump()
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
        pump()
    }

    private func pump() {
        guard !busy, !stopped, let request = pending.first, let dataRequest = request.dataRequest else { return }
        if request.isCancelled || request.isFinished { pending.removeFirst(); pump(); return }
        let end = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
        let offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
        guard !end.overflow, dataRequest.requestedOffset >= 0, dataRequest.requestedLength >= 0 else {
            finish(request, error: RecoveryError.invalid("Ungültige Audio-Anfrage.")); return
        }
        let limit = dataRequest.requestsAllDataToEndOfResource ? map.total : min(map.total, end.partialValue)
        do {
            guard let slice = try map.slice(offset: offset, remaining: max(0, limit - offset)) else {
                finish(request); return
            }
            if let byteBudget, requestedBytes + slice.count > byteBudget {
                finish(request, error: RecoveryError.invalid("Metadaten-Vorladen begrenzt; vollständige Tags beim Abspielen.")); return
            }
            requestedBytes += slice.count
            busy = true
            resolve(slice.chunk) { [weak self, weak request] result in
                guard let self else { return }
                guard !self.stopped, let request, !request.isCancelled else { self.busy = false; self.pump(); return }
                switch result {
                case .failure(let error): self.busy = false; self.finish(request, error: error)
                case .success(let id): self.read(id: id, slice: slice, request: request, attempt: 0)
                }
            }
        } catch { finish(request, error: error) }
    }

    private func resolve(_ chunk: Int, completion: @escaping (Result<Int, Error>) -> Void) {
        if let id = fileIDs[chunk] { completion(.success(id)); return }
        call(["@type": "getMessage", "chat_id": chatID, "message_id": chunks[chunk].telegramMessageID!]) { [weak self] result in
            guard let self else { return }
            do {
                let message = try result.get()
                let content = message["content"] as? [String: Any] ?? [:]
                var media: [String: Any]?
                for key in ["document", "audio", "video", "voice_note"] {
                    if let outer = content[key] as? [String: Any], let inner = outer[key == "voice_note" ? "voice" : key] as? [String: Any] {
                        media = inner; break
                    }
                }
                guard let media, let id = TelegramClient.int(media["id"]), id > 0 else {
                    throw RecoveryError.invalid("Der Musiktitel wurde in Telegram nicht gefunden. Bitte den Katalog aktualisieren.")
                }
                if let size = TelegramClient.int64(media["size"]), size > 0, size != self.chunks[chunk].size {
                    throw RecoveryError.invalid("Die Telegram-Datei passt nicht mehr zum gesicherten Titel.")
                }
                self.fileIDs[chunk] = id
                completion(.success(id))
            } catch { completion(.failure(error)) }
        }
    }

    private func read(id: Int, slice: MusicRangeMap.Slice, request: AVAssetResourceLoadingRequest, attempt: Int) {
        guard !stopped, !request.isCancelled else { busy = false; pump(); return }
        call(["@type": "downloadFile", "file_id": id, "priority": 32, "offset": slice.offset,
              "limit": slice.count, "synchronous": true]) { [weak self, weak request] result in
            guard let self, let request else { return }
            guard !self.stopped, !request.isCancelled else { self.busy = false; self.pump(); return }
            switch result {
            case .failure(let error): self.busy = false; self.finish(request, error: error)
            case .success(let response):
                let path = (response["local"] as? [String: Any])?["path"] as? String ?? ""
                self.call(["@type": "getFileDownloadedPrefixSize", "file_id": id, "offset": slice.offset]) { [weak self, weak request] prefixResult in
                    guard let self, let request else { return }
                    guard !self.stopped, !request.isCancelled else { self.busy = false; self.pump(); return }
                    do {
                        let prefix = TelegramClient.int64(try prefixResult.get()["size"]) ?? 0
                        if prefix < Int64(slice.count), attempt < 2 {
                            self.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.read(id: id, slice: slice, request: request, attempt: attempt + 1) }
                            return
                        }
                        let data = try MusicRangeMap.verifiedRead(path: path, offset: slice.offset, count: slice.count, downloadedPrefix: prefix)
                        request.dataRequest?.respond(with: data)
                        self.busy = false
                        // Round-robin lets format metadata and playback both make progress.
                        self.pending.removeAll { $0 === request }
                        self.pending.append(request)
                        self.pump()
                    } catch { self.busy = false; self.finish(request, error: error) }
                }
            }
        }
    }

    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error? = nil) {
        pending.removeAll { $0 === request }
        if !request.isCancelled && !request.isFinished {
            if let error { request.finishLoading(with: error) } else { request.finishLoading() }
        }
        pump()
    }

    /// Every request completes exactly once, even if connectivity disappears without a TDLib callback.
    private func call(_ body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var completed = false // Accessed exclusively on queue.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !completed else { return }
            completed = true
            completion(.failure(RecoveryError.invalid("Telegram antwortet gerade nicht. Bitte die Verbindung prüfen und erneut abspielen.")))
        }
        queue.asyncAfter(deadline: .now() + 60, execute: timeout)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.telegram.send(body) { [weak self] response in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped, !completed else { return }
                    completed = true; timeout.cancel()
                    if response["@type"] as? String == "error" {
                        completion(.failure(RecoveryError.invalid("Der Audiobereich konnte nicht von Telegram geladen werden. Bitte Verbindung und Zugriff auf den Ordner prüfen.")))
                    } else { completion(.success(response)) }
                }
            }
        }
    }
}

