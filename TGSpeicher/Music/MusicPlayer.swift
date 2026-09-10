import SwiftUI
import AVFoundation
import MediaPlayer
import Combine
import ImageIO
import UniformTypeIdentifiers

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
    @Published var showingPlayer = false
    @Published var error: String?

    let cloud: CloudStore
    private let telegram: TelegramClient
    private let network: TGNetworkMonitor
    private let player = AVPlayer()
    private let covers = NSCache<NSString, UIImage>()

    private var resource: TelegramAudioResource?
    private var metadataTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var manualScanTask: Task<Void, Never>?
    private var coverNotifyTask: Task<Void, Never>?
    private var coverLoadTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingPrefetch: [CloudFileEntry] = []
    private var pendingPrefetchIDs = Set<UUID>()
    private var prefetchGeneration = UUID()
    private var offlineScanGeneration = UUID()
    private var offlineURLs: [UUID: URL] = [:]

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

    var currentFile: CloudFileEntry? {
        queue.current.flatMap { id in cloud.index.files.first { $0.id == id } }
    }
    var currentInfo: MusicTrackInfo? {
        queue.current.flatMap { cloud.musicLibrary.tracks[$0] }
    }
    var title: String {
        currentInfo?.title ?? currentFile.map { ($0.name as NSString).deletingPathExtension } ?? "Keine Wiedergabe"
    }
    var artist: String { currentInfo?.artist ?? "Unbekannter Künstler" }
    var availableFiles: [CloudFileEntry] {
        cloud.index.files.filter { $0.isMusic && $0.isComplete && !cloud.deletingFileIDs.contains($0.id) }
    }
    var offlineFiles: [CloudFileEntry] {
        availableFiles.filter { offlineURLs[$0.id] != nil }
    }

    init(cloud: CloudStore, telegram: TelegramClient, network: TGNetworkMonitor) {
        self.cloud = cloud
        self.telegram = telegram
        self.network = network

        covers.countLimit = 40
        covers.totalCostLimit = 18 * 1024 * 1024
        player.automaticallyWaitsToMinimizeStalling = true

        periodic = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.75, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
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

        telegram.$savedMessagesChatID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] account in
                guard let self, self.accountID != account else { return }
                self.saveSession()
                self.stop(clearQueue: true)
                self.accountID = account
                self.restoredAccount = nil
                self.offlineURLs.removeAll()
                self.offlineRevision += 1
                self.restoreSessionIfReady()
                self.refreshOfflineLibrary()
            }
            .store(in: &cancellables)

        telegram.$authorizationStage
            .receive(on: RunLoop.main)
            .sink { [weak self] stage in
                if stage != .ready { self?.stop(clearQueue: true) }
            }
            .store(in: &cancellables)

        cloud.$index
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.restoreSessionIfReady()
                if self.cloud.recoveryReady, self.queue.current != nil, self.currentFile == nil {
                    self.stop(clearQueue: true)
                }
            }
            .store(in: &cancellables)

        cloud.$recoveryReady
            .receive(on: RunLoop.main)
            .sink { [weak self] ready in
                guard let self else { return }
                if ready {
                    self.restoreSessionIfReady()
                    self.refreshOfflineLibrary()
                }
            }
            .store(in: &cancellables)

        cloud.$deletingFileIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
                if let id = self?.queue.current, ids.contains(id) { self?.stop(clearQueue: true) }
            }
            .store(in: &cancellables)

        cloud.$isDownloading
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] downloading in
                if !downloading { self?.completeOfflineDownload() }
            }
            .store(in: &cancellables)

        network.$isConnected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.restoreSessionIfReady()
                self.refreshOfflineLibrary()
            }
            .store(in: &cancellables)

        observeSystemAudio()
        configureCommands()
    }

    // MARK: - Playback

    func play(_ ids: [UUID], startingAt id: UUID? = nil) {
        guard canAccess, !offlineBusy else { return }
        cancelMetadataScan()
        let playable = network.isConnected ? availableFiles : offlineFiles
        let allowed = Set(playable.map(\.id))
        var seen = Set<UUID>()
        let filtered = ids.filter { allowed.contains($0) && seen.insert($0).inserted }
        guard !filtered.isEmpty else {
            error = "Diese Titel sind im aktuellen Katalog oder offline noch nicht verfügbar."
            return
        }
        queue.ids = filtered
        queue.position = id.flatMap { filtered.firstIndex(of: $0) } ?? 0
        unshuffled = filtered
        if shuffle { shuffleUpcoming() }
        loadCurrent(autoplay: true)
    }

    func togglePlayback() {
        guard !offlineBusy else { return }
        if player.timeControlStatus != .paused {
            pause()
            return
        }
        guard canAccess else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed {
            loadCurrent(autoplay: true, offset: elapsed)
            return
        }
        if duration > 0, elapsed >= duration - 0.2 { seek(0) }
        do {
            try activateAudio()
            player.playImmediately(atRate: rate)
        } catch {
            self.error = "Die Audioausgabe konnte nicht aktiviert werden: \(error.localizedDescription)"
        }
    }

    func pause() {
        interruptedPlayback = false
        player.pause()
        isPlaying = false
        isBuffering = false
        saveSession()
        updateNowPlaying()
    }

    func next() {
        guard !offlineBusy else { return }
        if advancePlayable(manual: true) { loadCurrent(autoplay: true) }
        else { pause() }
    }

    func previous() {
        guard !offlineBusy else { return }
        if elapsed > 3 { seek(0); return }
        queue.position = max(0, queue.position - 1)
        loadCurrent(autoplay: true)
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        elapsed = min(duration, max(0, seconds))
        player.seek(
            to: CMTime(seconds: elapsed, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.15, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.15, preferredTimescale: 600)
        )
        saveSession()
        updateNowPlaying()
    }

    func setRate(_ value: Float) {
        rate = min(2, max(0.5, value))
        if player.timeControlStatus != .paused { player.rate = rate }
        saveSession()
        updateNowPlaying()
    }

    func cycleRepeat() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
        saveSession()
    }

    func toggleShuffle() {
        shuffle.toggle()
        if shuffle {
            unshuffled = queue.ids
            shuffleUpcoming()
        } else if let id = queue.current {
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
        if let old = queue.ids.firstIndex(of: id) {
            queue.ids.remove(at: old)
            if old < queue.position { queue.position -= 1 }
        }
        queue.ids.insert(id, at: next ? min(queue.position + 1, queue.ids.count) : queue.ids.count)
        saveSession()
    }

    func removeQueued(_ id: UUID) {
        guard let index = queue.ids.firstIndex(of: id), id != queue.current else { return }
        queue.ids.remove(at: index)
        if index < queue.position { queue.position -= 1 }
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
        cancelMetadataScan()
        queue.position = index
        loadCurrent(autoplay: true)
    }

    func setSleep(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        guard let date = sleepUntil else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkSleep() }
        }
        sleepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkSleep() {
        if let date = sleepUntil, date <= Date() {
            pause()
            setSleep(minutes: nil)
        }
    }

    private var canAccess: Bool {
        telegram.authorizationStage == .ready
            && accountID != nil
            && (cloud.recoveryReady || !network.isConnected)
            && cloud.index.recovery?.accountID == accountID
    }

    private func loadCurrent(autoplay: Bool, offset: Double = 0) {
        guard canAccess, !offlineBusy, let file = currentFile,
              !cloud.deletingFileIDs.contains(file.id), let accountID else { return }

        cancelMetadataScan()
        generation = UUID()
        let token = generation
        metadataTask?.cancel()
        metadataTask = nil
        resource?.stop()
        resource = nil
        itemObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)

        artwork = covers.object(forKey: file.id.uuidString as NSString)
        if artwork == nil { loadCachedCoverIfNeeded(for: file) }
        elapsed = max(0, offset.isFinite ? offset : 0)
        duration = sanitizedDuration(currentInfo?.duration)
        error = nil
        isBuffering = autoplay
        resumeOffset = elapsed > 0 ? elapsed : nil

        do {
            let asset: AVURLAsset
            let localURL = offlineURL(for: file)
            if let localURL {
                asset = AVURLAsset(url: localURL)
            } else {
                let loader = try TelegramAudioResource(file: file, accountID: accountID, telegram: telegram)
                resource = loader
                asset = loader.asset()
            }

            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 8
            player.replaceCurrentItem(with: item)

            itemObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if item.status == .failed {
                        self.pause()
                        self.error = "Dieser Titel konnte nicht abgespielt werden. Der Eintrag bleibt erhalten; bitte erneut versuchen oder ihn zuerst offline laden."
                    } else if item.status == .readyToPlay {
                        let seconds = item.duration.seconds
                        if seconds.isFinite, seconds > 0 { self.duration = seconds }
                        if let resume = self.resumeOffset, self.duration > 0 {
                            self.resumeOffset = nil
                            self.seek(resume)
                        }
                    }
                }
            }

            if autoplay {
                try activateAudio()
                player.playImmediately(atRate: rate)
            }

            // Metadata and artwork are intentionally loaded only for the currently
            // selected track. Opening or scrolling the music library never triggers
            // remote metadata/thumbnail traffic anymore.
            if localURL != nil {
                metadataTask = Task { [weak self] in
                    let result = await MusicMetadata.readLocal(asset)
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    self.applyMetadata(result, to: file, makeCurrentArtwork: true)
                }
            } else if file.storageKind == "nativeAudio" {
                metadataTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.fetchTelegramAudioMetadata(file: file, accountID: accountID, includeCover: true)
                    guard !Task.isCancelled, self.generation == token else { return }
                    if let result { self.applyMetadata(result, to: file, makeCurrentArtwork: true) }
                }
            }

            saveSession()
            updateNowPlaying()
        } catch {
            isBuffering = false
            self.error = error.localizedDescription
        }
    }

    func refreshMetadata() {
        guard let file = currentFile, let accountID, !offlineBusy else { return }
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            guard let self else { return }
            if let local = self.offlineURL(for: file) {
                let result = await MusicMetadata.readLocal(AVURLAsset(url: local))
                guard !Task.isCancelled else { return }
                self.applyMetadata(result, to: file, makeCurrentArtwork: true)
            } else if file.storageKind == "nativeAudio", self.network.isConnected {
                let result = await self.fetchTelegramAudioMetadata(file: file, accountID: accountID, includeCover: true)
                guard !Task.isCancelled else { return }
                if let result { self.applyMetadata(result, to: file, makeCurrentArtwork: true) }
            } else {
                self.error = "Eingebettete Metadaten dieses Dokument-Titels werden aus Stabilitätsgründen erst aus einer Offline-Kopie gelesen."
            }
        }
    }

    private func tick() {
        let time = player.currentTime().seconds
        if player.currentItem != nil, time.isFinite, resumeOffset == nil { elapsed = max(0, time) }
        let length = player.currentItem?.duration.seconds ?? 0
        if length.isFinite, length > 0 { duration = length }
        checkSleep()
        if Date().timeIntervalSince(lastSaved) >= 12 {
            saveSession()
            updateNowPlaying()
        }
    }

    private func ended(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem else { return }
        if let date = sleepUntil, date <= Date() { checkSleep(); return }
        if advancePlayable(manual: false) { loadCurrent(autoplay: true) }
        else { pause() }
    }

    private func advancePlayable(manual: Bool) -> Bool {
        let available = Set((network.isConnected ? availableFiles : offlineFiles).map(\.id))
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
        saveSession()
        generation = UUID()
        metadataTask?.cancel()
        metadataTask = nil
        cancelMetadataScan()
        coverLoadTasks.values.forEach { $0.cancel() }
        coverLoadTasks.removeAll()
        coverNotifyTask?.cancel()
        coverNotifyTask = nil
        resource?.stop()
        resource = nil
        itemObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isBuffering = false
        artwork = nil
        elapsed = 0
        duration = 0
        offlineGeneration = UUID()
        offlineRequest = nil
        offlineBusy = false
        error = nil
        showingPlayer = false
        setSleep(minutes: nil)
        if clearQueue {
            queue = MusicQueue()
            unshuffled = []
            shuffle = false
            rate = 1
            covers.removeAllObjects()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Session and system audio

    private struct Session: Codable {
        let queue: MusicQueue
        let elapsed: Double
        let rate: Float
        let shuffle: Bool
        let original: [UUID]
    }

    private func saveSession() {
        guard let accountID, queue.current != nil else { return }
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let value = Session(queue: queue, elapsed: safeElapsed, rate: rate, shuffle: shuffle, original: unshuffled)
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "music.session.v1.\(accountID)")
        }
        lastSaved = Date()
    }

    private func restoreSessionIfReady() {
        guard canAccess, let accountID, restoredAccount != accountID else { return }
        restoredAccount = accountID
        guard let data = UserDefaults.standard.data(forKey: "music.session.v1.\(accountID)"),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.elapsed.isFinite, session.rate.isFinite else { return }

        let available = Set(availableFiles.map(\.id))
        let current = session.queue.current
        queue = session.queue
        var seen = Set<UUID>()
        queue.ids = queue.ids.filter { available.contains($0) && seen.insert($0).inserted }
        queue.position = current.flatMap { queue.ids.firstIndex(of: $0) } ?? 0
        elapsed = current == queue.current ? max(0, session.elapsed) : 0
        rate = min(2, max(0.5, session.rate))
        shuffle = session.shuffle
        unshuffled = session.original
        duration = sanitizedDuration(currentInfo?.duration)
    }

    private func observeSystemAudio() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in self?.ended(notification.object as? AVPlayerItem) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    let resume = self.player.timeControlStatus != .paused
                    self.pause()
                    self.interruptedPlayback = resume
                } else {
                    let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let resume = self.interruptedPlayback
                        && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                    self.interruptedPlayback = false
                    if resume, self.player.timeControlStatus == .paused { self.togglePlayback() }
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.pause()
                self?.resource?.stop()
                self?.resource = nil
            }
        })
        notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.cancelMetadataScan()
                self?.saveSession()
            }
        })
        notifications.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cancelMetadataScan()
                self.coverLoadTasks.values.forEach { $0.cancel() }
                self.coverLoadTasks.removeAll()
                self.covers.removeAllObjects()
                if let current = self.artwork, let id = self.queue.current {
                    self.covers.setObject(current, forKey: id.uuidString as NSString, cost: self.imageCost(current))
                }
            }
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
        guard let file = currentFile else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let safeDuration = sanitizedDuration(duration)
        let safeElapsed = elapsed.isFinite ? min(max(0, elapsed), max(safeDuration, elapsed)) : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: String(title.prefix(1000)),
            MPMediaItemPropertyArtist: String(artist.prefix(1000)),
            MPMediaItemPropertyAlbumTitle: String((currentInfo?.album ?? "").prefix(1000)),
            MPMediaItemPropertyPlaybackDuration: safeDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyExternalContentIdentifier: file.id.uuidString,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: max(0, queue.position),
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.ids.count
        ]
        if let artwork, artwork.size.width > 0, artwork.size.height > 0 {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Metadata and covers

    func trackTitle(_ file: CloudFileEntry) -> String {
        cloud.musicLibrary.tracks[file.id]?.title ?? (file.name as NSString).deletingPathExtension
    }

    func matches(_ file: CloudFileEntry, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        let info = cloud.musicLibrary.tracks[file.id]
        return [file.name, info?.title ?? "", info?.artist ?? "", info?.album ?? ""]
            .contains { $0.localizedStandardContains(search) }
    }

    func cover(for id: UUID) -> UIImage? {
        if id == queue.current, let artwork { return artwork }
        return covers.object(forKey: id.uuidString as NSString)
    }

    /// Library rows deliberately do not trigger metadata or artwork I/O anymore.
    /// The currently playing track is hydrated by loadCurrent(...), which keeps
    /// Telegram/AVFoundation work bounded to one track at a time.
    func prefetchMetadata(_ files: [CloudFileEntry]) {
        // Intentionally disabled for stability.
    }

    private func startPrefetchWorker() {
        guard prefetchTask == nil, !pendingPrefetch.isEmpty,
              player.currentItem == nil, UIApplication.shared.applicationState == .active,
              network.isConnected, let accountID else { return }

        let worker = UUID()
        prefetchGeneration = worker
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.prefetchTask = nil
                if self.prefetchGeneration == worker, !self.pendingPrefetch.isEmpty { self.startPrefetchWorker() }
            }
            while !self.pendingPrefetch.isEmpty {
                guard !Task.isCancelled,
                      self.prefetchGeneration == worker,
                      self.player.currentItem == nil,
                      UIApplication.shared.applicationState == .active,
                      self.network.isConnected,
                      self.accountID == accountID else { return }

                let file = self.pendingPrefetch.removeFirst()
                defer { self.pendingPrefetchIDs.remove(file.id) }
                if let result = await self.fetchTelegramAudioMetadata(file: file, accountID: accountID, includeCover: true) {
                    guard !Task.isCancelled, self.prefetchGeneration == worker else { return }
                    self.applyMetadata(result, to: file, makeCurrentArtwork: false)
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.metadataStampKey(file))
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    func cancelMetadataScan() {
        prefetchGeneration = UUID()
        prefetchTask?.cancel()
        prefetchTask = nil
        pendingPrefetch.removeAll()
        pendingPrefetchIDs.removeAll()
        manualScanTask?.cancel()
        manualScanTask = nil
        if isScanningMetadata { metadataStatus = "Metadaten-Scan pausiert" }
        isScanningMetadata = false
    }

    func scanMetadata() {
        cancelMetadataScan()
        metadataStatus = "Cover & Tags werden aus Stabilitätsgründen erst beim Abspielen des jeweiligen Titels geladen."
    }

    private func fetchTelegramAudioMetadata(
        file: CloudFileEntry,
        accountID: Int64,
        includeCover: Bool
    ) async -> MusicMetadata.Result? {
        guard file.storageKind == "nativeAudio",
              let messageID = file.chunks.sorted(by: { $0.index < $1.index }).first?.telegramMessageID,
              messageID > 0 else { return nil }
        let chatID = file.telegramChatID ?? accountID
        guard let response = await telegramRequest(["@type": "getMessage", "chat_id": chatID, "message_id": messageID]),
              response["@type"] as? String != "error",
              let content = response["content"] as? [String: Any],
              content["@type"] as? String == "messageAudio",
              let audio = content["audio"] as? [String: Any] else { return nil }

        var info = MusicTrackInfo()
        let rawTitle = (audio["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawArtist = (audio["performer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawTitle, !rawTitle.isEmpty { info.title = String(rawTitle.prefix(1000)) }
        if let rawArtist, !rawArtist.isEmpty { info.artist = String(rawArtist.prefix(1000)) }
        if let seconds = TelegramClient.int(audio["duration"]), seconds > 0 { info.duration = Double(seconds) }
        info.updatedAt = Date().timeIntervalSince1970

        var cover: CGImage?
        if includeCover,
           let thumbnail = audio["album_cover_thumbnail"] as? [String: Any],
           let thumbnailFile = thumbnail["file"] as? [String: Any],
           let thumbnailID = TelegramClient.int(thumbnailFile["id"]), thumbnailID > 0,
           let download = await telegramRequest([
                "@type": "downloadFile", "file_id": thumbnailID, "priority": 1,
                "offset": 0, "limit": 0, "synchronous": true
           ]),
           download["@type"] as? String != "error",
           let local = download["local"] as? [String: Any],
           local["is_downloading_completed"] as? Bool == true,
           let path = local["path"] as? String, !path.isEmpty {
            cover = await Task.detached(priority: .utility) {
                MusicCoverCodec.thumbnail(at: URL(fileURLWithPath: path), maxPixel: 640)
            }.value
        }
        return MusicMetadata.Result(info: info, artwork: cover)
    }

    private func telegramRequest(_ body: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            telegram.send(body) { response in continuation.resume(returning: response) }
        }
    }

    private func applyMetadata(_ result: MusicMetadata.Result, to file: CloudFileEntry, makeCurrentArtwork: Bool) {
        if let seconds = result.info.duration, seconds.isFinite, seconds > 0, queue.current == file.id {
            duration = seconds
        }
        storeMetadata(result.info, id: file.id)
        if let cg = result.artwork {
            let image = UIImage(cgImage: cg)
            cacheCover(image, id: file.id)
            if makeCurrentArtwork, queue.current == file.id {
                artwork = image
                updateNowPlaying()
            }
        }
    }

    private func storeMetadata(_ value: MusicTrackInfo, id: UUID) {
        guard cloud.recoveryReady, !cloud.isRefreshing else { return }
        var info = sanitizedMetadata(value)
        if let old = cloud.musicLibrary.tracks[id] {
            let safeOld = sanitizedMetadata(old)
            info.title = info.title ?? safeOld.title
            info.artist = info.artist ?? safeOld.artist
            info.album = info.album ?? safeOld.album
            info.duration = info.duration ?? safeOld.duration
            info.details = safeOld.details.merging(info.details) { _, new in new }
            info.updatedAt = max(Date().timeIntervalSince1970, safeOld.updatedAt + 0.001)
            if safeOld.title == info.title,
               safeOld.artist == info.artist,
               safeOld.album == info.album,
               safeOld.duration == info.duration,
               safeOld.details == info.details,
               old.details == safeOld.details { return }
        }
        cloud.editMusic { $0.tracks[id] = info }
    }

    private func sanitizedMetadata(_ value: MusicTrackInfo) -> MusicTrackInfo {
        var result = MusicTrackInfo()
        if let title = value.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            result.title = String(title.prefix(1000))
        }
        if let artist = value.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            result.artist = String(artist.prefix(1000))
        }
        if let album = value.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            result.album = String(album.prefix(1000))
        }
        if let duration = value.duration, duration.isFinite, duration >= 0 { result.duration = duration }
        for key in value.details.keys.sorted().prefix(24) {
            let cleanKey = String(key.prefix(160))
            let cleanValue = String((value.details[key] ?? "").prefix(2048))
            if !cleanKey.isEmpty, !cleanValue.isEmpty { result.details[cleanKey] = cleanValue }
        }
        result.updatedAt = value.updatedAt.isFinite ? value.updatedAt : Date().timeIntervalSince1970
        return result
    }

    private func sanitizedDuration(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return min(value, 7 * 24 * 60 * 60)
    }

    private func coverURL(_ file: CloudFileEntry) -> URL? {
        guard let accountID else { return nil }
        return offlineDestination(file, account: accountID).appendingPathExtension("cover.jpg")
    }

    private func metadataStampKey(_ file: CloudFileEntry) -> String {
        "music.metadata.safe.v3." + file.id.uuidString
    }

    private func coverFileExists(for file: CloudFileEntry) -> Bool {
        guard let url = coverURL(file) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func loadCachedCoverIfNeeded(for file: CloudFileEntry) {
        guard covers.object(forKey: file.id.uuidString as NSString) == nil,
              coverLoadTasks[file.id] == nil,
              let url = coverURL(file), FileManager.default.fileExists(atPath: url.path) else { return }
        let account = accountID
        coverLoadTasks[file.id] = Task { [weak self] in
            let cg = await Task.detached(priority: .utility) {
                MusicCoverCodec.thumbnail(at: url, maxPixel: 640)
            }.value
            guard let self else { return }
            self.coverLoadTasks[file.id] = nil
            guard !Task.isCancelled, self.accountID == account, let cg else { return }
            let image = UIImage(cgImage: cg)
            self.covers.setObject(image, forKey: file.id.uuidString as NSString, cost: self.imageCost(image))
            if self.queue.current == file.id, self.artwork == nil { self.artwork = image }
            self.scheduleCoverChangeNotification()
        }
    }

    private func cacheCover(_ image: UIImage, id: UUID) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        covers.setObject(image, forKey: id.uuidString as NSString, cost: imageCost(image))
        guard let file = availableFiles.first(where: { $0.id == id }),
              let url = coverURL(file), let cg = image.cgImage else {
            scheduleCoverChangeNotification()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            MusicCoverCodec.writeJPEG(cg, to: url)
        }
        scheduleCoverChangeNotification()
    }

    private func imageCost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1_200_000 }
        let cost = cg.bytesPerRow.multipliedReportingOverflow(by: cg.height)
        return cost.overflow ? 1_200_000 : min(cost.partialValue, 8 * 1024 * 1024)
    }

    private func scheduleCoverChangeNotification() {
        guard coverNotifyTask == nil else { return }
        coverNotifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            self.coverNotifyTask = nil
            self.objectWillChange.send()
        }
    }

    // MARK: - Offline library

    func refreshOfflineLibrary() {
        guard let accountID else {
            offlineURLs.removeAll()
            offlineRevision += 1
            return
        }
        let files = availableFiles
        let token = UUID()
        offlineScanGeneration = token
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [UUID: URL] in
                var result: [UUID: URL] = [:]
                let fm = FileManager.default
                for file in files {
                    let url = Self.offlineDestination(file, account: accountID)
                    guard fm.fileExists(atPath: url.path), url.fileByteSize == file.totalSize else { continue }
                    result[file.id] = url
                }
                return result
            }.value
            guard let self, self.accountID == accountID, self.offlineScanGeneration == token else { return }
            if self.offlineURLs != found {
                self.offlineURLs = found
                self.offlineRevision += 1
            }
        }
    }

    private func offlineDestination(_ file: CloudFileEntry, account: Int64) -> URL {
        Self.offlineDestination(file, account: account)
    }

    nonisolated private static func offlineDestination(_ file: CloudFileEntry, account: Int64) -> URL {
        let identity = file.chunks.sorted { $0.index < $1.index }
            .map { "\($0.telegramMessageID ?? 0):\($0.size)" }
            .joined(separator: "|")
        let suffix = CatalogCodec.digest(Data(identity.utf8)).prefix(16)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TGSpeicher/Music/\(account)/\(file.id.uuidString)-\(suffix).\((file.name as NSString).pathExtension)")
    }

    func offlineURL(for file: CloudFileEntry) -> URL? {
        offlineURLs[file.id]
    }

    func downloadCurrentOffline() {
        guard let file = currentFile else { return }
        downloadOffline(file)
    }

    func downloadOffline(_ file: CloudFileEntry) {
        guard canAccess, cloud.recoveryReady, network.isConnected,
              !cloud.isDownloading, !offlineBusy, let accountID else { return }
        cancelMetadataScan()
        pause()
        generation = UUID()
        metadataTask?.cancel()
        metadataTask = nil
        resource?.stop()
        resource = nil
        player.replaceCurrentItem(with: nil)
        offlineGeneration = UUID()
        offlineBusy = true
        offlineRequest = (file, accountID)
        cloud.lastDownloadedFileID = nil
        cloud.downloadAndReassemble(file)
    }

    private func completeOfflineDownload() {
        guard !cloud.isDownloading, let request = offlineRequest else { return }
        offlineRequest = nil
        guard request.account == accountID,
              cloud.lastDownloadedFileID == request.file.id,
              let source = cloud.lastExportURL else {
            offlineBusy = false
            return
        }
        let destination = offlineDestination(request.file, account: request.account)
        let token = offlineGeneration
        Task { [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    guard source.fileByteSize == request.file.totalSize else {
                        throw RecoveryError.invalid("Die Offline-Datei ist unvollständig.")
                    }
                    let folder = destination.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let temporary = folder.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(at: source, to: temporary)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    } else {
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    }
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    var local = destination
                    try local.setResourceValues(values)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, self.accountID == request.account, self.offlineGeneration == token else { return }
            self.offlineBusy = false
            switch result {
            case .failure(let error):
                self.error = error.localizedDescription
            case .success:
                self.offlineURLs[request.file.id] = destination
                self.offlineRevision += 1
                // Do not inspect metadata or artwork here. The file may never be played,
                // and background/offline completion must stay lightweight.
            }
        }
    }

    func removeCurrentOffline() {
        guard let file = currentFile else { return }
        removeOffline(file)
    }

    func removeOffline(_ file: CloudFileEntry) {
        guard let url = offlineURLs[file.id], !offlineBusy else { return }
        if currentFile?.id == file.id {
            pause()
            player.replaceCurrentItem(with: nil)
        }
        do {
            try FileManager.default.removeItem(at: url)
            offlineURLs.removeValue(forKey: file.id)
            offlineRevision += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    deinit {
        metadataTask?.cancel()
        prefetchTask?.cancel()
        manualScanTask?.cancel()
        coverNotifyTask?.cancel()
        coverLoadTasks.values.forEach { $0.cancel() }
        resource?.stop()
        sleepTimer?.invalidate()
        if let periodic { player.removeTimeObserver(periodic) }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        commands.forEach { $0.0.removeTarget($0.1) }
    }
}

private enum MusicCoverCodec {
    static func thumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(128, min(1024, maxPixel)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func thumbnail(data: Data, maxPixel: Int) -> CGImage? {
        guard data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(128, min(1024, maxPixel)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
    }
}

enum MusicMetadata {
    struct Result {
        var info: MusicTrackInfo
        var artwork: CGImage?
    }

    /// Used only for a local/offline file. Remote playback deliberately does not invoke
    /// AVFoundation metadata probing because that can create many competing byte ranges.
    static func readLocal(_ asset: AVURLAsset) async -> Result {
        var info = MusicTrackInfo()
        var cover: CGImage?

        if let loaded = try? await asset.load(.duration), loaded.seconds.isFinite, loaded.seconds > 0 {
            info.duration = loaded.seconds
        }
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in metadata.prefix(64) {
            if Task.isCancelled { break }
            let key = item.identifier?.rawValue ?? item.commonKey?.rawValue ?? "Metadatum"
            let lower = key.lowercased()
            if item.commonKey == .commonKeyArtwork || lower.contains("apic") || lower.contains("covr") || lower.contains("picture") {
                if cover == nil, let data = try? await item.load(.dataValue) {
                    cover = MusicCoverCodec.thumbnail(data: data, maxPixel: 640)
                }
                continue
            }
            var value = try? await item.load(.stringValue)
            if value == nil, let number = try? await item.load(.numberValue) { value = number.stringValue }
            guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let text = String(raw.prefix(2048))
            if item.commonKey == .commonKeyTitle { info.title = String(text.prefix(1000)) }
            if item.commonKey == .commonKeyArtist { info.artist = String(text.prefix(1000)) }
            if item.commonKey == .commonKeyAlbumName { info.album = String(text.prefix(1000)) }
            if info.details.count < 24 { info.details[String(key.prefix(160))] = text }
        }
        info.updatedAt = Date().timeIntervalSince1970
        return Result(info: info, artwork: cover)
    }
}
