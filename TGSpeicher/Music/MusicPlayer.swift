import SwiftUI
import AVFoundation
import MediaPlayer
import Combine
import ImageIO

@MainActor
final class MusicPlayer: ObservableObject {
    @Published private(set) var queue = MusicQueue()
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var artwork: UIImage?
    @Published private(set) var shuffle = false
    @Published private(set) var rate: Float = 1
    @Published private(set) var sleepUntil: Date?
    @Published private(set) var offlineBusy = false
    @Published private(set) var offlineRevision = 0
    @Published private(set) var isScanningMetadata = false
    @Published private(set) var metadataStatus = ""
    private var scanTask: Task<Void, Never>?
    private var scanResource: TelegramAudioResource?
    private var scanAsset: AVURLAsset?
    private var pendingMetadata: [CloudFileEntry] = []
    private var pendingMetadataIDs = Set<UUID>()
    private var scannedKeys = Set<String>()
    private var diskCoverRequests = Set<String>()
    private var metadataWorkerID = UUID()
    private let network: TGNetworkMonitor
    private let covers = NSCache<NSString, UIImage>()
    @Published var showingPlayer = false
    @Published var error: String?
    let cloud: CloudStore
    private let telegram: TelegramClient
    private let player = AVPlayer()
    private var resource: TelegramAudioResource?
    private var metadataTask: Task<Void, Never>?
    private var generation = UUID()
    private var accountID: Int64?
    private var restoredAccount: Int64?
    private var cancellables = Set<AnyCancellable>()
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var periodic: Any?
    private var notifications: [NSObjectProtocol] = []
    private var commands: [(MPRemoteCommand, Any)] = []
    private var sleepTimer: Timer?
    private var lastSaved = Date.distantPast
    private var unshuffled: [UUID] = []
    private var interruptedPlayback = false
    private var offlineGeneration = UUID()
    private var offlineRequest: (file: CloudFileEntry, account: Int64)?
    private var resumeOffset: Double?

    var currentFile: CloudFileEntry? { queue.current.flatMap { id in cloud.index.files.first { $0.id == id } } }
    var currentInfo: MusicTrackInfo? { queue.current.flatMap { cloud.musicLibrary.tracks[$0] } }
    var title: String { currentInfo?.title ?? currentFile.map { ($0.name as NSString).deletingPathExtension } ?? "Keine Wiedergabe" }
    var artist: String { currentInfo?.artist ?? "Unbekannter Künstler" }
    var availableFiles: [CloudFileEntry] { cloud.index.files.filter { $0.isMusic && $0.isComplete && !cloud.deletingFileIDs.contains($0.id) } }

    init(cloud: CloudStore, telegram: TelegramClient, network: TGNetworkMonitor) {
        self.network = network
        self.cloud = cloud; self.telegram = telegram
        covers.countLimit = 64; covers.totalCostLimit = 32 * 1024 * 1024
        player.automaticallyWaitsToMinimizeStalling = true
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = self.player.timeControlStatus == .playing
                self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.updateNowPlaying()
            }
        })
        telegram.$savedMessagesChatID.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] account in
            guard let self, self.accountID != account else { return }
            self.saveSession(); self.stop(clearQueue: true)
            self.accountID = account; self.restoredAccount = nil
            self.offlineRevision += 1
            self.restoreSessionIfReady()
        }.store(in: &cancellables)
        telegram.$authorizationStage.receive(on: RunLoop.main).sink { [weak self] stage in
            if stage != .ready { self?.stop(clearQueue: true) }
        }.store(in: &cancellables)
        cloud.$index.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.restoreSessionIfReady()
            if self.cloud.recoveryReady, self.queue.current != nil, self.currentFile == nil { self.stop(clearQueue: true) }
        }.store(in: &cancellables)
        cloud.$recoveryReady.receive(on: RunLoop.main).sink { [weak self] ready in
            if ready { self?.restoreSessionIfReady() }
        }.store(in: &cancellables)
        cloud.$deletingFileIDs.receive(on: RunLoop.main).sink { [weak self] ids in
            if let id = self?.queue.current, ids.contains(id) { self?.stop(clearQueue: true) }
        }.store(in: &cancellables)
        cloud.$isDownloading.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] downloading in
            if !downloading { self?.completeOfflineDownload() }
        }.store(in: &cancellables)
        network.$isConnected.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] connected in
            guard let self else { return }
            self.offlineRevision += 1
            self.restoreSessionIfReady()
            if connected { self.scannedKeys.removeAll(); self.prefetchMetadata(self.availableFiles.filter { self.offlineURL(for: $0) != nil }) }
        }.store(in: &cancellables)
        observeSystemAudio()
        configureCommands()
    }

    func play(_ ids: [UUID], startingAt id: UUID? = nil) {
        guard canAccess, !offlineBusy else { return }
        let playable = network.isConnected ? availableFiles : offlineFiles
        let allowed = Set(playable.map(\.id))
        var seen = Set<UUID>()
        let ids = ids.filter { allowed.contains($0) && seen.insert($0).inserted }
        guard !ids.isEmpty else { error = "Diese Titel sind im aktuellen Katalog noch nicht verfügbar."; return }
        queue.ids = ids; queue.position = id.flatMap { ids.firstIndex(of: $0) } ?? 0
        unshuffled = ids
        if shuffle { shuffleUpcoming() }
        loadCurrent(autoplay: true)
    }

    func togglePlayback() {
        guard !offlineBusy else { return }
        if player.timeControlStatus != .paused { pause(); return }
        guard canAccess else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed { loadCurrent(autoplay: true, offset: elapsed); return }
        if duration > 0 && elapsed >= duration - 0.2 { seek(0) }
        do { try activateAudio(); player.playImmediately(atRate: rate) }
        catch { self.error = "Die Audioausgabe konnte nicht aktiviert werden: \(error.localizedDescription)" }
    }

    func pause() { interruptedPlayback = false; player.pause(); isPlaying = false; isBuffering = false; saveSession(); updateNowPlaying() }
    func next() {
        guard !offlineBusy else { return }
        if advancePlayable(manual: true) { loadCurrent(autoplay: true) }
        else { pause() }
    }
    func previous() {
        guard !offlineBusy else { return }
        if elapsed > 3 { seek(0); return }
        queue.position = max(0, queue.position - 1); loadCurrent(autoplay: true)
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        elapsed = min(duration, max(0, seconds))
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        saveSession(); updateNowPlaying()
    }
    func setRate(_ value: Float) {
        rate = min(2, max(0.5, value))
        if player.timeControlStatus != .paused { player.rate = rate }
        saveSession(); updateNowPlaying()
    }
    func cycleRepeat() {
        switch queue.repeatMode { case .off: queue.repeatMode = .all; case .all: queue.repeatMode = .one; case .one: queue.repeatMode = .off }
        saveSession()
    }
    func toggleShuffle() {
        shuffle.toggle()
        if shuffle { unshuffled = queue.ids; shuffleUpcoming() }
        else if let id = queue.current {
            let available = Set(queue.ids)
            queue.ids = unshuffled.filter { available.contains($0) } + queue.ids.filter { !unshuffled.contains($0) }
            queue.position = queue.ids.firstIndex(of: id) ?? 0
        }
        saveSession()
    }
    private func shuffleUpcoming() {
        guard queue.position + 1 < queue.ids.count else { return }
        let prefix = Array(queue.ids.prefix(queue.position + 1))
        queue.ids = prefix + queue.ids.dropFirst(queue.position + 1).shuffled()
    }
    func enqueue(_ id: UUID, next: Bool) {
        guard availableFiles.contains(where: { $0.id == id }), queue.current != id else { return }
        if queue.ids.isEmpty { play([id]); pause(); return }
        if let old = queue.ids.firstIndex(of: id) { queue.ids.remove(at: old); if old < queue.position { queue.position -= 1 } }
        queue.ids.insert(id, at: next ? min(queue.position + 1, queue.ids.count) : queue.ids.count)
        saveSession()
    }
    func removeQueued(_ id: UUID) {
        guard let index = queue.ids.firstIndex(of: id), id != queue.current else { return }
        queue.ids.remove(at: index); if index < queue.position { queue.position -= 1 }
        saveSession()
    }
    func moveQueue(from: IndexSet, to: Int) {
        let id = queue.current
        queue.ids.move(fromOffsets: from, toOffset: to)
        queue.position = id.flatMap { queue.ids.firstIndex(of: $0) } ?? 0
        saveSession()
    }
    func jumpTo(_ id: UUID) {
        guard !offlineBusy, let index = queue.ids.firstIndex(of: id) else { return }
        queue.position = index; loadCurrent(autoplay: true)
    }
    func setSleep(minutes: Int?) {
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        guard let date = sleepUntil else { return }
        sleepTimer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkSleep() }
        }
        RunLoop.main.add(sleepTimer!, forMode: .common)
    }
    private func checkSleep() {
        if let date = sleepUntil, date <= Date() { pause(); setSleep(minutes: nil) }
    }
    private var canAccess: Bool {
        telegram.authorizationStage == .ready && accountID != nil && (cloud.recoveryReady || !network.isConnected) && cloud.index.recovery?.accountID == accountID
    }

    private func loadCurrent(autoplay: Bool, offset: Double = 0) {
        guard canAccess, !offlineBusy, let file = currentFile, !cloud.deletingFileIDs.contains(file.id), let accountID else { return }
        generation = UUID(); let token = generation
        metadataTask?.cancel(); resource?.stop(); resource = nil
        itemObservation = nil; player.pause(); player.replaceCurrentItem(with: nil)
        artwork = covers.object(forKey: file.id.uuidString as NSString); elapsed = max(0, offset); duration = currentInfo?.duration ?? 0
        error = nil; isBuffering = autoplay; resumeOffset = offset > 0 ? offset : nil
        do {
            let asset: AVURLAsset
            if let local = offlineURL(for: file) { asset = AVURLAsset(url: local) }
            else {
                let loader = try TelegramAudioResource(file: file, accountID: accountID, telegram: telegram)
                resource = loader; asset = loader.asset()
            }
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 15
            player.replaceCurrentItem(with: item)
            itemObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if item.status == .failed {
                        self.pause()
                        self.error = "Dieser Titel konnte nicht abgespielt werden. Bitte erneut versuchen oder zuerst offline laden. Das Audioformat muss von iOS unterstützt werden."
                    } else if item.status == .readyToPlay {
                        let seconds = item.duration.seconds
                        if seconds.isFinite && seconds > 0 { self.duration = seconds }
                        if let resume = self.resumeOffset, self.duration > 0 { self.resumeOffset = nil; self.seek(resume) }
                    }
                }
            }
            if autoplay { try activateAudio(); player.playImmediately(atRate: rate) }
            metadataTask = Task { [weak self] in
                let result = await MusicMetadata.read(asset)
                guard !Task.isCancelled, let self, self.generation == token, self.canAccess else { return }
                if let seconds = result.info.duration { self.duration = seconds }
                if let cover = result.artwork { self.artwork = cover; self.cacheCover(cover, id: file.id) }
                var info = result.info
                if info.title == nil { info.title = self.cloud.musicLibrary.tracks[file.id]?.title }
                if info.artist == nil { info.artist = self.cloud.musicLibrary.tracks[file.id]?.artist }
                if info.album == nil { info.album = self.cloud.musicLibrary.tracks[file.id]?.album }
                if info.duration != nil || !info.details.isEmpty { self.storeMetadata(info, id: file.id) }
                self.updateNowPlaying()
            }
            saveSession(); updateNowPlaying()
        } catch { isBuffering = false; self.error = error.localizedDescription }
    }

    func refreshMetadata() { let active = player.timeControlStatus != .paused; loadCurrent(autoplay: active, offset: elapsed) }

    private func tick() {
        let time = player.currentTime().seconds
        if player.currentItem != nil && time.isFinite && resumeOffset == nil { elapsed = max(0, time) }
        let length = player.currentItem?.duration.seconds ?? 0
        if length.isFinite && length > 0 { duration = length }
        checkSleep()
        if Date().timeIntervalSince(lastSaved) >= 10 { saveSession(); updateNowPlaying() }
    }
    private func ended(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem else { return }
        if let date = sleepUntil, date <= Date() { checkSleep(); return }
        if advancePlayable(manual: false) { loadCurrent(autoplay: true) }
        else { pause() }
    }
    private func advancePlayable(manual: Bool) -> Bool {
        let available = Set(availableFiles.map(\.id))
        for _ in 0..<queue.ids.count {
            guard let next = queue.advance(manual: manual) else { return false }
            if available.contains(next) { return true }
        }
        return false
    }
    private func activateAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }
    private func stop(clearQueue: Bool) {
        saveSession(); generation = UUID(); metadataTask?.cancel(); metadataTask = nil
        cancelMetadataScan(); covers.removeAllObjects(); scannedKeys.removeAll(); diskCoverRequests.removeAll()
        resource?.stop(); resource = nil; itemObservation = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        isPlaying = false; isBuffering = false; artwork = nil; elapsed = 0; duration = 0
        offlineGeneration = UUID(); offlineRequest = nil; offlineBusy = false; error = nil; showingPlayer = false
        setSleep(minutes: nil)
        if clearQueue { queue = MusicQueue(); unshuffled = []; shuffle = false; rate = 1 }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private struct Session: Codable { let queue: MusicQueue; let elapsed: Double; let rate: Float; let shuffle: Bool; let original: [UUID] }
    private func saveSession() {
        guard let accountID, queue.current != nil else { return }
        let value = Session(queue: queue, elapsed: elapsed, rate: rate, shuffle: shuffle, original: unshuffled)
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "music.session.v1.\(accountID)") }
        lastSaved = Date()
    }
    private func restoreSessionIfReady() {
        guard canAccess, let accountID, restoredAccount != accountID else { return }
        restoredAccount = accountID
        guard let data = UserDefaults.standard.data(forKey: "music.session.v1.\(accountID)"),
              let session = try? JSONDecoder().decode(Session.self, from: data), session.elapsed.isFinite, session.rate.isFinite else { return }
        let available = Set(availableFiles.map(\.id)); let current = session.queue.current
        queue = session.queue
        var seen = Set<UUID>(); queue.ids = queue.ids.filter { available.contains($0) && seen.insert($0).inserted }
        queue.position = current.flatMap { queue.ids.firstIndex(of: $0) } ?? 0
        elapsed = current == queue.current ? max(0, session.elapsed) : 0
        rate = min(2, max(0.5, session.rate)); shuffle = session.shuffle; unshuffled = session.original
        duration = currentInfo?.duration ?? 0
        // Restoring never starts playback or downloads without the user pressing play.
    }

    private func observeSystemAudio() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in self?.ended(notification.object as? AVPlayerItem) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { let resume = self.player.timeControlStatus != .paused; self.pause(); self.interruptedPlayback = resume }
                else {
                    let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let resume = self.interruptedPlayback && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                    self.interruptedPlayback = false
                    if resume, self.player.timeControlStatus == .paused { self.togglePlayback() }
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(); self?.refreshMetadata() }
        })
        notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveSession() }
        })
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, action: @escaping @MainActor (MusicPlayer, MPRemoteCommandEvent) -> Void) {
            let token = command.addTarget { [weak self] event in
                Task { @MainActor in if let self { action(self, event) } }
                return .success
            }
            commands.append((command, token))
        }
        bind(center.playCommand) { player, _ in if player.player.timeControlStatus == .paused { player.togglePlayback() } }
        bind(center.pauseCommand) { player, _ in player.pause() }
        bind(center.togglePlayPauseCommand) { player, _ in player.togglePlayback() }
        bind(center.nextTrackCommand) { player, _ in player.next() }
        bind(center.previousTrackCommand) { player, _ in player.previous() }
        bind(center.changePlaybackPositionCommand) { player, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { player.seek(event.positionTime) }
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        bind(center.skipForwardCommand) { player, _ in player.seek(player.elapsed + 15) }
        bind(center.skipBackwardCommand) { player, _ in player.seek(player.elapsed - 15) }
    }
    private func updateNowPlaying() {
        guard let file = currentFile else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: currentInfo?.album ?? "", MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyExternalContentIdentifier: file.id.uuidString,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queue.position,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.ids.count]
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }


    func trackTitle(_ file: CloudFileEntry) -> String { cloud.musicLibrary.tracks[file.id]?.title ?? (file.name as NSString).deletingPathExtension }
    func matches(_ file: CloudFileEntry, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        let info = cloud.musicLibrary.tracks[file.id]
        return [file.name, info?.title ?? "", info?.artist ?? "", info?.album ?? ""].contains { $0.localizedStandardContains(search) }
    }
    private func coverURL(_ file: CloudFileEntry) -> URL? {
        guard let accountID else { return nil }
        return offlineDestination(file, account: accountID).appendingPathExtension("cover.jpg")
    }
    private func metadataKey(_ file: CloudFileEntry) -> String { coverURL(file)?.path ?? file.id.uuidString }
    private func cacheCover(_ cover: UIImage, id: UUID) {
        covers.setObject(cover, forKey: id.uuidString as NSString, cost: cover.cgImage.map { $0.bytesPerRow * $0.height } ?? 2_560_000)
        guard let file = availableFiles.first(where: { $0.id == id }), let url = coverURL(file) else { return }
        Task.detached(priority: .utility) {
            guard let data = cover.jpegData(compressionQuality: 0.85) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }
    func cover(for id: UUID) -> UIImage? {
        if id == queue.current, let artwork { return artwork }
        return covers.object(forKey: id.uuidString as NSString)
    }
    private func storeMetadata(_ value: MusicTrackInfo, id: UUID) {
        var info = value
        if let old = cloud.musicLibrary.tracks[id] {
            info.title = info.title ?? old.title; info.artist = info.artist ?? old.artist
            info.album = info.album ?? old.album; info.duration = info.duration ?? old.duration
            info.details = old.details.merging(info.details) { _, new in new }
            if old.title == info.title, old.artist == info.artist, old.album == info.album,
               old.duration == info.duration, old.details == info.details { return }
        }
        cloud.editMusic { $0.tracks[id] = info }
    }
    func prefetchMetadata(_ files: [CloudFileEntry]) {
        guard canAccess else { return }
        for file in files {
            let key = metadataKey(file)
            if covers.object(forKey: file.id.uuidString as NSString) == nil,
               let url = coverURL(file), diskCoverRequests.insert(key).inserted {
                let account = accountID
                Task { [weak self] in
                    let image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
                    guard let self, self.accountID == account else { return }
                    self.diskCoverRequests.remove(key)
                    if let image {
                        self.covers.setObject(image, forKey: file.id.uuidString as NSString,
                            cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 2_560_000)
                        if self.queue.current == file.id, self.artwork == nil { self.artwork = image }
                        self.objectWillChange.send()
                    }
                }
            }
            let last = UserDefaults.standard.double(forKey: "music.metadata.v2." + key)
            guard !scannedKeys.contains(key), Date().timeIntervalSince1970 - last > 86_400,
                  file.id != queue.current || player.currentItem == nil,
                  network.isConnected || offlineURL(for: file) != nil,
                  pendingMetadataIDs.insert(file.id).inserted else { continue }
            pendingMetadata.append(file)
        }
        startMetadataWorker()
    }
    func cancelMetadataScan() {
        metadataWorkerID = UUID()
        scanTask?.cancel(); scanTask = nil; scanAsset?.cancelLoading(); scanAsset = nil
        scanResource?.stop(); scanResource = nil; isScanningMetadata = false
        pendingMetadata.removeAll(); pendingMetadataIDs.removeAll()
    }
    func scanMetadata() {
        for file in availableFiles {
            scannedKeys.remove(metadataKey(file))
            UserDefaults.standard.removeObject(forKey: "music.metadata.v2." + metadataKey(file))
        }
        prefetchMetadata(availableFiles)
    }
    private func startMetadataWorker() {
        guard !isScanningMetadata, !pendingMetadata.isEmpty, canAccess, !offlineBusy, let accountID else { return }
        isScanningMetadata = true
        let worker = UUID(); metadataWorkerID = worker
        scanTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            while !self.pendingMetadata.isEmpty {
                guard !Task.isCancelled, self.canAccess, self.accountID == accountID else { break }
                let file = self.pendingMetadata.removeFirst()
                let key = self.metadataKey(file)
                self.metadataStatus = "Cover & Tags · \(completed + 1) · \(self.pendingMetadata.count) warten"
                do {
                    let asset: AVURLAsset
                    if let local = self.offlineURL(for: file) { asset = AVURLAsset(url: local) }
                    else {
                        guard self.network.isConnected else { self.pendingMetadataIDs.remove(file.id); continue }
                        let loader = try TelegramAudioResource(file: file, accountID: accountID, telegram: self.telegram, byteBudget: 8 * 1024 * 1024)
                        self.scanResource = loader; asset = loader.asset()
                    }
                    self.scanAsset = asset
                    let loader = self.scanResource
                    let timeout = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(15))
                        if !Task.isCancelled { asset.cancelLoading(); loader?.stop() }
                    }
                    let result = await MusicMetadata.read(asset)
                    timeout.cancel(); loader?.stop()
                    guard !Task.isCancelled, self.metadataWorkerID == worker, self.accountID == accountID else { return }
                    self.scanResource = nil; self.scanAsset = nil
                    self.scannedKeys.insert(key)
                    if result.info.duration != nil || !result.info.details.isEmpty || result.info.title != nil {
                        self.storeMetadata(result.info, id: file.id)
                        if self.cloud.recoveryReady && !self.cloud.isRefreshing {
                            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "music.metadata.v2." + key)
                        }
                    }
                    if let cover = result.artwork {
                        self.cacheCover(cover, id: file.id)
                        if self.queue.current == file.id { self.artwork = cover }
                        self.objectWillChange.send()
                    }
                } catch { self.scannedKeys.insert(key) }
                self.pendingMetadataIDs.remove(file.id); completed += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard self.metadataWorkerID == worker else { return }
            self.isScanningMetadata = false; self.scanTask = nil
            self.metadataStatus = "Cover & Tags aktualisiert"
        }
    }
    var offlineFiles: [CloudFileEntry] { availableFiles.filter { offlineURL(for: $0) != nil } }
    func refreshOfflineLibrary() {
        offlineRevision += 1
        prefetchMetadata(offlineFiles)
    }

    private func offlineDestination(_ file: CloudFileEntry, account: Int64) -> URL {
        let identity = file.chunks.sorted { $0.index < $1.index }.map { "\($0.telegramMessageID ?? 0):\($0.size)" }.joined(separator: "|")
        let suffix = CatalogCodec.digest(Data(identity.utf8)).prefix(16)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TGSpeicher/Music/\(account)/\(file.id.uuidString)-\(suffix).\((file.name as NSString).pathExtension)")
    }
    func offlineURL(for file: CloudFileEntry) -> URL? {
        guard let accountID else { return nil }
        let url = offlineDestination(file, account: accountID)
        guard FileManager.default.fileExists(atPath: url.path), url.fileByteSize == file.totalSize else { return nil }
        return url
    }
    func downloadCurrentOffline() {
        guard let file = currentFile else { return }
        downloadOffline(file)
    }
    func downloadOffline(_ file: CloudFileEntry) {
        guard canAccess, cloud.recoveryReady, network.isConnected, !cloud.isDownloading, !offlineBusy, let accountID else { return }
        cancelMetadataScan()
        pause(); generation = UUID(); metadataTask?.cancel(); resource?.stop(); resource = nil
        player.replaceCurrentItem(with: nil)
        offlineGeneration = UUID(); offlineBusy = true; offlineRequest = (file, accountID)
        cloud.lastDownloadedFileID = nil
        cloud.downloadAndReassemble(file)
    }
    private func completeOfflineDownload() {
        guard !cloud.isDownloading, let request = offlineRequest else { return }
        offlineRequest = nil
        guard request.account == accountID, cloud.lastDownloadedFileID == request.file.id,
              let source = cloud.lastExportURL else { offlineBusy = false; return }
        let destination = offlineDestination(request.file, account: request.account)
        let token = offlineGeneration
        Task { [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    guard source.fileByteSize == request.file.totalSize else { throw RecoveryError.invalid("Die Offline-Datei ist unvollständig.") }
                    let folder = destination.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let temporary = folder.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(at: source, to: temporary)
                    if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                    else { try FileManager.default.moveItem(at: temporary, to: destination) }
                    var values = URLResourceValues(); values.isExcludedFromBackup = true
                    var local = destination; try local.setResourceValues(values)
                    return .success(())
                } catch { return .failure(error) }
            }.value
            guard let self, self.accountID == request.account, self.offlineGeneration == token else { return }
            self.offlineBusy = false; self.offlineRevision += 1
            if case .failure(let error) = result { self.error = error.localizedDescription }
            else { self.prefetchMetadata([request.file]) }
        }
    }
    deinit {
        metadataTask?.cancel(); scanTask?.cancel()
        resource?.stop(); scanResource?.stop()
        sleepTimer?.invalidate()
        if let periodic { player.removeTimeObserver(periodic) }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        commands.forEach { $0.0.removeTarget($0.1) }
    }

    func removeCurrentOffline() {
        guard let file = currentFile else { return }
        removeOffline(file)
    }
    func removeOffline(_ file: CloudFileEntry) {
        guard let url = offlineURL(for: file), !offlineBusy else { return }
        if currentFile?.id == file.id { pause(); player.replaceCurrentItem(with: nil) }
        do { try FileManager.default.removeItem(at: url); offlineRevision += 1 }
        catch { self.error = error.localizedDescription }
    }
}

enum MusicMetadata {
    struct Result { var info: MusicTrackInfo; var artwork: UIImage? }
    static func read(_ asset: AVURLAsset) async -> Result {
        var info = MusicTrackInfo(); var cover: UIImage?
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 { info.duration = duration.seconds }
        var metadata = (try? await asset.load(.commonMetadata)) ?? []
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            if Task.isCancelled { return Result(info: info, artwork: cover) }
            metadata += (try? await asset.loadMetadata(for: format)) ?? []
        }
        for item in metadata.prefix(256) {
            if Task.isCancelled { break }
            let key = item.identifier?.rawValue ?? item.commonKey?.rawValue ?? "Metadatum"
            let lower = key.lowercased()
            if item.commonKey == .commonKeyArtwork || lower.contains("apic") || lower.contains("covr") || lower.contains("picture") {
                if cover == nil, let data = try? await item.load(.dataValue), data.count <= 12 * 1024 * 1024,
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 800, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                    cover = UIImage(cgImage: image)
                }
                continue
            }
            var value = try? await item.load(.stringValue)
            if value == nil, let number = try? await item.load(.numberValue) { value = number.stringValue }
            guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let text = String(raw.prefix(32_768))
            if item.commonKey == .commonKeyTitle { info.title = String(text.prefix(1000)) }
            if item.commonKey == .commonKeyArtist { info.artist = String(text.prefix(1000)) }
            if item.commonKey == .commonKeyAlbumName { info.album = String(text.prefix(1000)) }
            if info.details.count < 128 { info.details[String(key.prefix(256))] = text }
        }
        return Result(info: info, artwork: cover)
    }
}

