import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Channel selection is additive. File entries always retain their original chat IDs.
@MainActor
final class MusicChannelManager: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var status = "Optionaler Musikkanal"
    let cloud: CloudStore
    let telegram: TelegramClient
    let queue: UploadQueueManager
    private let network: TGNetworkMonitor
    private var subscriptions = Set<AnyCancellable>()
    private var work: DispatchWorkItem?
    private var lastSync = Date.distantPast
    private var importedIDs = Set<Int64>()

    init(cloud: CloudStore, telegram: TelegramClient, queue: UploadQueueManager, network: TGNetworkMonitor) {
        self.cloud = cloud; self.telegram = telegram; self.queue = queue; self.network = network
        cloud.$index.debounce(for: .seconds(8), scheduler: RunLoop.main).sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        network.$isConnected.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] online in
            if online { self?.scheduleSync() }
        }.store(in: &subscriptions)
        cloud.$recoveryReady.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] ready in
            if ready { self?.scheduleSync() }
        }.store(in: &subscriptions)
    }
    var choice: MusicChannelChoice? { cloud.musicLibrary.channel }
    var files: [CloudFileEntry] {
        guard let chat = choice?.chatID else { return [] }
        return cloud.musicFiles.filter { $0.isMusic && $0.isComplete && $0.telegramChatID == chat }
    }
    func select(_ channel: TelegramBackupDestination?) {
        let editedAt = max(Date().timeIntervalSince1970, (choice?.updatedAt ?? 0).nextUp)
        guard cloud.editMusic({ $0.channel = MusicChannelChoice(chatID: channel?.id,
            title: String((channel?.title ?? "Kein Musikkanal").prefix(200)), updatedAt: editedAt) }) else { return }
        status = channel == nil ? "Musikkanal deaktiviert · vorhandene Titel bleiben erhalten" : "Musikkanal ausgewählt"
        scheduleSync()
    }
    func createChannel(title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        guard !title.isEmpty, !isWorking, cloud.recoveryReady, let account = telegram.savedMessagesChatID else { return }
        isWorking = true; status = "Privater Musikkanal wird erstellt …"
        telegram.send(["@type": "createNewSupergroupChat", "title": title, "is_forum": false, "is_channel": true,
            "description": "Meine Musik mit TGSpeicher", "location": NSNull(), "for_import": false]) { [weak self] response in
            guard let self else { return }; self.isWorking = false
            guard self.telegram.savedMessagesChatID == account else { return }
            guard response["@type"] as? String != "error", let id = TelegramClient.int64(response["id"]) else {
                self.status = response["message"] as? String ?? "Kanal konnte nicht erstellt werden"; return
            }
            self.select(TelegramBackupDestination(id: id, title: title, isSavedMessages: false))
            self.telegram.refreshWritableBackupChannels()
        }
    }
    func upload(_ urls: [URL]) {
        guard let chat = choice?.chatID else { return }
        let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true || ["mp3", "flac", "ogg", "opus"].contains($0.pathExtension.lowercased()) }
        if audio.count != urls.count { status = "Es werden nur Audiodateien hinzugefügt." }
        queue.enqueue(urls: audio, folderID: nil, musicDestinationChatID: chat)
    }
    private func scheduleSync() {
        work?.cancel()
        guard choice?.chatID != nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.syncIndex() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(8, 60 - Date().timeIntervalSince(lastSync)), execute: item)
    }
    func syncIndex() {
        guard let chat = choice?.chatID, let account = telegram.savedMessagesChatID, network.isConnected,
              cloud.recoveryReady, cloud.index.recovery?.accountID == account else { return }
        guard !isWorking, cloud.upload == nil, !cloud.isRefreshing, !cloud.isCatalogSyncing else { scheduleSync(); return }
        isWorking = true
        // Same codec as recovery exports: the channel index can be imported by the recovery center.
        var recovery = RecoveryMetadata(accountID: account)
        recovery.music = cloud.musicLibrary
        recovery.deletedFiles = cloud.index.recovery?.deletedFiles ?? [:]
        let snapshot = CatalogSnapshot(revision: 0, createdAt: Date(timeIntervalSince1970: 0),
            folders: cloud.index.folders, files: cloud.index.files.filter { $0.isMusic && $0.isComplete },
            tags: cloud.index.tags, recovery: recovery)
        Task {
            do {
                let data = try await Task.detached(priority: .utility) { try CatalogCodec.encode(snapshot) }.value
                guard telegram.savedMessagesChatID == account, choice?.chatID == chat else { isWorking = false; return }
                let digest = CatalogCodec.digest(data)
                let key = "music.channel.index.\(account).\(chat)"
                if UserDefaults.standard.string(forKey: key) == digest { isWorking = false; return }
                let operation = "TGSMUSIC" + CatalogCodec.digest(Data("\(account)|\(chat)|\(digest)".utf8))
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("TGSpeicher-Musik-\(digest.prefix(16)).tgscatalog")
                try data.write(to: url, options: [.atomic])
                status = "Musikindex wird im Kanal gesichert …"
                telegram.sendDurably(["@type": "sendMessage", "chat_id": chat,
                    "input_message_content": ["@type": "inputMessageDocument", "document": ["@type": "inputFileLocal", "path": url.path],
                        "disable_content_type_detection": true, "thumbnail": NSNull(),
                        "caption": ["@type": "formattedText", "text": operation + "\n#TGSpeicherMusicIndexV1", "entities": []]]], operation: operation) { [weak self] response in
                    try? FileManager.default.removeItem(at: url)
                    guard let self else { return }; self.isWorking = false; self.lastSync = Date()
                    guard self.telegram.savedMessagesChatID == account else { return }
                    if response["@type"] as? String == "error" {
                        self.status = "Musikindex: " + (response["message"] as? String ?? "Bitte erneut versuchen")
                        self.scheduleSync()
                    } else {
                        UserDefaults.standard.set(digest, forKey: key)
                        self.status = "Musikindex im Kanal gesichert"
                        self.scheduleSync()
                    }
                }
            } catch { isWorking = false; status = error.localizedDescription }
        }
    }
    func importExistingMusic() {
        guard !isWorking, let chat = choice?.chatID, let account = telegram.savedMessagesChatID,
              cloud.recoveryReady, !cloud.isRefreshing else { return }
        isWorking = true; importedIDs.removeAll(); status = "Vorhandene Musik wird eingelesen …"
        importPage(chat: chat, account: account, cursor: 0, count: 0)
    }
    private func importPage(chat: Int64, account: Int64, cursor: Int64, count: Int) {
        telegram.send(["@type": "searchChatMessages", "chat_id": chat, "query": "", "sender_id": NSNull(),
            "from_message_id": cursor, "offset": 0, "limit": 100, "filter": ["@type": "searchMessagesFilterAudio"],
            "topic_id": NSNull()]) { [weak self] response in
            guard let self else { return }
            guard self.telegram.savedMessagesChatID == account, self.choice?.chatID == chat, self.cloud.recoveryReady, !self.cloud.isRefreshing else {
                self.isWorking = false; self.status = "Einlesen unterbrochen; bisherige Titel bleiben erhalten"; return
            }
            if response["@type"] as? String == "error" {
                self.isWorking = false; self.status = response["message"] as? String ?? "Kanal nicht erreichbar"; return
            }
            let messages = response["messages"] as? [[String: Any]] ?? []
            let previousIndex = self.cloud.index
            var added = 0
            var library = self.cloud.musicLibrary
            var references = library.channelFiles ?? []
            var knownIDs = Set(self.cloud.musicFiles.map(\.id))
            let knownMessages = Set(self.cloud.musicFiles.filter { $0.telegramChatID == chat }.flatMap { $0.chunks.compactMap(\.telegramMessageID) })
            for message in messages {
                guard let messageID = TelegramClient.int64(message["id"]), self.importedIDs.insert(messageID).inserted,
                      let content = message["content"] as? [String: Any], let audio = content["audio"] as? [String: Any],
                      let media = audio["audio"] as? [String: Any], let size = TelegramClient.int64(media["size"]), size > 0 else { continue }
                let manifest = self.cloud.decodeManifest(from: DurableOutbox.caption(message))
                let id = manifest?.fileID ?? CatalogCodec.stableMediaID(hash: "telegram-audio:\(messageID)", chatID: chat)
                guard self.cloud.index.recovery?.deletedFiles[id] == nil,
                      library.removedChannelFiles?[id] == nil,
                      !knownIDs.contains(id), !knownMessages.contains(messageID) else { continue }
                let name = audio["file_name"] as? String ?? "Musik-\(messageID).mp3"
                let file = CloudFileEntry(id: id, name: manifest?.name ?? name, totalSize: size,
                    chunks: [CloudChunk(index: 1, count: 1, telegramMessageID: messageID, telegramFileID: nil,
                        remoteUniqueID: (media["remote"] as? [String: Any])?["unique_id"] as? String, size: size, storedName: name)],
                    mimeType: audio["mime_type"] as? String ?? "audio/mpeg", telegramChatID: chat, storageKind: "nativeAudio")
                references.append(file)
                knownIDs.insert(id)
                library.tracks[id] = MusicTrackInfo(title: (audio["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    artist: (audio["performer"] as? String).flatMap { $0.isEmpty ? nil : $0 }, duration: (audio["duration"] as? NSNumber)?.doubleValue)
                added += 1
            }
            if added > 0 {
                library.channelFiles = references
                do { try library.validate() }
                catch { self.isWorking = false; self.status = error.localizedDescription; return }
                self.cloud.index.recovery?.music = library
            }
            guard added == 0 || self.cloud.persist() else { self.cloud.index = previousIndex; self.isWorking = false; self.status = "Lokales Speichern fehlgeschlagen"; return }
            if added > 0 { self.cloud.catalogMutation += 1; self.cloud.forceNextCatalog = true; self.cloud.scheduleCatalogSync(delay: 3) }
            let total = count + added
            self.status = "\(total) Titel eingepflegt"
            let next = TelegramClient.int64(response["next_from_message_id"]) ?? 0
            if next > 0, next != cursor, self.importedIDs.count < 100_000 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.importPage(chat: chat, account: account, cursor: next, count: total) }
            } else {
                self.isWorking = false
                if next > 0 { self.status += " · weitere Titel mit erneutem Einlesen" }
                self.scheduleSync()
            }
        }
    }
}

struct MusicChannelSection: View {
    @ObservedObject var cloud: CloudStore
    @EnvironmentObject private var channel: MusicChannelManager
    @EnvironmentObject private var music: MusicPlayer
    @State private var picking = false
    @State private var creating = false
    @State private var title = "Meine Musik"
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    private var importedFiles: [CloudFileEntry] {
        (cloud.musicLibrary.channelFiles ?? []).filter { $0.telegramChatID == channel.choice?.chatID }
    }
    var body: some View {
        Section {
            NavigationLink {
                MusicChannelPicker(telegram: channel.telegram)
            } label: { Label(channel.choice?.title ?? "Musikkanal auswählen", systemImage: "antenna.radiowaves.left.and.right") }
            Button("Privaten Musikkanal erstellen", systemImage: "plus.circle") { creating = true }.disabled(channel.isWorking)
            if channel.choice?.chatID != nil {
                Button("Musik in diesen Kanal hochladen", systemImage: "square.and.arrow.up") { picking = true }
                Button("Vorhandene Kanal-Musik einpflegen", systemImage: "arrow.triangle.2.circlepath") { channel.importExistingMusic() }.disabled(channel.isWorking)
                Button("Musikindex jetzt sichern", systemImage: "icloud.and.arrow.up") { channel.syncIndex() }.disabled(channel.isWorking)
                Button("Kanal als Upload-Ziel deaktivieren") { channel.select(nil) }.disabled(channel.isWorking)
            }
            Text(channel.status).font(.caption).foregroundStyle(.secondary)
        } header: { Text("Dein Musikkanal") } footer: {
            Text("Neue Uploads werden als Telegram-Audio gesendet. Nicht unterstützte oder zu große Dateien werden verlustfrei als Dokument gesichert. Ein Kanalwechsel verschiebt und löscht keine vorhandenen Titel. Importierte Kanal-Titel bleiben getrennt von „Meine Dateien“ unter „Titel“ und in deinen Playlists. Beim Entfernen aus der Mediathek bleibt das Kanal-Original erhalten.")
        }
        Section("Musik in diesem Kanal") {
            if !channel.files.isEmpty {
                Button("Kanal abspielen", systemImage: "play.fill") { music.play(channel.files.map(\.id)) }
            }
            if !importedFiles.isEmpty {
                Button(selecting ? "Auswahl beenden" : "Importierte Titel auswählen", systemImage: "checkmark.circle") {
                    selecting.toggle(); selected.removeAll()
                }
                if selecting {
                    Button("Alle importierten Titel auswählen") { selected = Set(importedFiles.map(\.id)) }
                    Button("Aus Mediathek entfernen (\(selected.count))", systemImage: "trash", role: .destructive) {
                        music.pendingChannelRemovals = importedFiles.filter { selected.contains($0.id) }
                        selecting = false; selected.removeAll()
                    }.disabled(selected.isEmpty)
                }
            }
            ForEach(channel.files) { file in
                if selecting {
                    Button {
                        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                            MusicTrackRow(file: file)
                        }
                    }.buttonStyle(.plain)
                        .disabled(!importedFiles.contains(where: { $0.id == file.id }))
                } else {
                    MusicTrackRow(file: file).contentShape(Rectangle())
                        .onTapGesture { music.play(channel.files.map(\.id), startingAt: file.id) }
                        .contextMenu { MusicTrackMenu(file: file, cloud: cloud) }
                }
            }
        }
        .sheet(isPresented: $picking) { TGDocumentPicker(allowsMultipleSelection: true, onPicked: { urls in picking = false; channel.upload(urls) }, onCancel: { picking = false }) }
        .alert("Privater Musikkanal", isPresented: $creating) {
            TextField("Kanalname", text: $title)
            Button("Erstellen") { channel.createChannel(title: title) }
            Button("Abbrechen", role: .cancel) { }
        }
    }
}

private struct MusicChannelPicker: View {
    @ObservedObject var telegram: TelegramClient
    @EnvironmentObject private var channel: MusicChannelManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(telegram.writableBackupChannels) { item in
            Button { channel.select(item); dismiss() } label: {
                HStack { Text(item.title); Spacer(); if channel.choice?.chatID == item.id { Image(systemName: "checkmark") } }
            }.disabled(channel.isWorking)
        }
        .navigationTitle("Musikkanal wählen")
        .onAppear { telegram.refreshWritableBackupChannels() }
        .toolbar { Button("Aktualisieren", systemImage: "arrow.clockwise") { telegram.refreshWritableBackupChannels() } }
        .overlay { if telegram.writableBackupChannels.isEmpty { ContentUnavailableView("Keine Kanäle geladen", systemImage: "antenna.radiowaves.left.and.right", description: Text("Erstelle einen privaten Musikkanal oder aktualisiere die Liste. Du benötigst Schreibrechte.")) } }
    }
}

