import SwiftUI
import AVKit
import MediaPlayer

struct MusicLibraryView: View {
    @ObservedObject var cloud: CloudStore
    @EnvironmentObject private var music: MusicPlayer
    @State private var search = ""
    @State private var section = 0
    @State private var folder: UUID?
    @State private var newPlaylist = false
    @State private var name = ""

    private var files: [CloudFileEntry] {
        music.availableFiles.filter { (folder == nil || $0.folderID == folder) && music.matches($0, search: search) }
            .sorted { music.trackTitle($0).localizedStandardCompare(music.trackTitle($1)) == .orderedAscending }
    }
    private var lists: [MusicPlaylist] {
        cloud.musicLibrary.playlists.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Deine Musik. Überall dabei.").font(.headline)
                            Text("\(music.availableFiles.count) Titel · \(cloud.musicLibrary.playlists.count) Playlists")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Musikansicht", selection: $section) {
                        Text("Titel").tag(0); Text("Playlists").tag(1)
                    }.pickerStyle(.segmented)
                }.padding(.vertical, 5)
            }
            if section == 0 {
                Section {
                    Picker("Ordner", selection: $folder) {
                        Text("Alle Musikordner").tag(UUID?.none)
                        ForEach(cloud.index.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { item in
                            Text(cloud.folderPath(for: item.id).map(\.name).joined(separator: " / ")).tag(Optional(item.id))
                        }
                    }
                    if !files.isEmpty {
                        HStack {
                            Button("Abspielen", systemImage: "play.fill") { music.play(files.map(\.id)) }
                            Spacer()
                            Button("Zufällig", systemImage: "shuffle") { music.play(files.map(\.id).shuffled()) }
                        }.buttonStyle(.borderless)
                    }
                }
                Section {
                    ForEach(files) { file in
                        MusicTrackRow(file: file).contentShape(Rectangle())
                            .onTapGesture { music.play(files.map(\.id), startingAt: file.id) }
                            .contextMenu { MusicTrackMenu(file: file, cloud: cloud) }
                    }
                    if files.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Deine Musik wartet auf dich" : "Keine passenden Titel", systemImage: "music.note",
                            description: Text("Lade Audiodateien im Bereich „Dateien“ in deine Telegram-Ordner. Sie erscheinen hier automatisch. Bereits hochgeladene Titel kannst du direkt zu Playlists hinzufügen."))
                    }
                } header: { Text("Musik aus deinen Dateien") } footer: {
                    Text("Cover und Tags werden beim Abspielen eingelesen. Mit „Metadaten einlesen“ kannst du deine Bibliothek vorab durchsuchen. Die verfügbaren Formate hängen von iOS ab.")
                }
            } else {
                Section {
                    Button("Playlist erstellen", systemImage: "plus.circle.fill") { name = ""; newPlaylist = true }
                    ForEach(lists) { playlist in
                        NavigationLink {
                            MusicPlaylistView(id: playlist.id, cloud: cloud)
                        } label: {
                            HStack(spacing: 14) {
                                MusicCover(image: nil, size: 48, symbol: "music.note.list")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlist.trackIDs.count) Titel").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                } footer: { Text("Playlists enthalten Verknüpfungen zu deinen Originaldateien. Sie werden automatisch im Telegram-Katalog gesichert.") }
            }
            Section {
                if music.isScanningMetadata {
                    HStack { ProgressView(); Text(music.metadataStatus).font(.caption); Spacer(); Button("Stoppen") { music.cancelMetadataScan() } }
                } else {
                    if !music.metadataStatus.isEmpty { Text(music.metadataStatus).font(.caption).foregroundStyle(.secondary) }
                    Button("Metadaten einlesen", systemImage: "sparkle.magnifyingglass") { music.scanMetadata() }
                        .disabled(music.availableFiles.isEmpty || !cloud.recoveryReady)
                }
                Button("Musikbibliothek jetzt in Telegram sichern", systemImage: "icloud.and.arrow.up") { cloud.syncCatalogNow() }
                    .disabled(!cloud.recoveryReady || cloud.isCatalogSyncing)
                Text(cloud.catalogStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Musik")
        .searchable(text: $search, prompt: "Titel, Künstler, Album oder Dateiname")
        .alert("Neue Playlist", isPresented: $newPlaylist) {
            TextField("Name", text: $name)
            Button("Erstellen") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { cloud.editMusic { $0.playlists.append(MusicPlaylist(name: String(trimmed.prefix(200)))) } }
            }
            Button("Abbrechen", role: .cancel) { }
        }
    }
}

struct MusicTrackRow: View {
    let file: CloudFileEntry
    @EnvironmentObject private var music: MusicPlayer
    var body: some View {
        HStack(spacing: 12) {
            MusicCover(image: music.cover(for: file.id), size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(music.trackTitle(file)).font(.body.weight(.medium)).lineLimit(1)
                Text(music.cloud.musicLibrary.tracks[file.id]?.artist ?? file.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if music.offlineURL(for: file) != nil { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Offline verfügbar") }
            if music.queue.current == file.id {
                Image(systemName: music.isPlaying ? "waveform" : "pause.fill").foregroundStyle(.cyan).accessibilityLabel("Aktueller Titel")
            } else if let duration = music.cloud.musicLibrary.tracks[file.id]?.duration {
                Text(musicTime(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

struct MusicTrackMenu: View {
    let file: CloudFileEntry
    @ObservedObject var cloud: CloudStore
    @EnvironmentObject private var music: MusicPlayer
    var body: some View {
        Button("Abspielen", systemImage: "play.fill") { music.play([file.id]) }
        Button("Als Nächstes abspielen", systemImage: "text.line.first.and.arrowtriangle.forward") { music.enqueue(file.id, next: true) }
        Button("An Warteschlange anhängen", systemImage: "text.badge.plus") { music.enqueue(file.id, next: false) }
        Menu("Zur Playlist hinzufügen", systemImage: "music.note.list") {
            if cloud.musicLibrary.playlists.isEmpty { Text("Zuerst im Musikbereich eine Playlist erstellen") }
            ForEach(cloud.musicLibrary.playlists) { list in
                Button(list.name) {
                    cloud.editMusic { library in
                        if let i = library.playlists.firstIndex(where: { $0.id == list.id }) {
                            library.playlists[i].edit(tracks: library.playlists[i].trackIDs + [file.id])
                        }
                    }
                }
            }
        }
    }
}

struct MusicPlaylistView: View {
    let id: UUID
    @ObservedObject var cloud: CloudStore
    @EnvironmentObject private var music: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""
    private var playlist: MusicPlaylist? { cloud.musicLibrary.playlists.first { $0.id == id } }
    var body: some View {
        List {
            if let playlist {
                Section {
                    HStack {
                        Button("Abspielen", systemImage: "play.fill") { music.play(playlist.trackIDs) }
                        Spacer()
                        Button("Zufällig", systemImage: "shuffle") { music.play(playlist.trackIDs.shuffled()) }
                    }.buttonStyle(.borderless).disabled(playlist.trackIDs.isEmpty)
                    Button("Titel aus Ordnern hinzufügen", systemImage: "plus") { adding = true }
                }
                Section {
                    ForEach(playlist.trackIDs, id: \.self) { trackID in
                        if let file = cloud.index.files.first(where: { $0.id == trackID }) {
                            MusicTrackRow(file: file).contentShape(Rectangle())
                                .onTapGesture { music.play(playlist.trackIDs, startingAt: file.id) }
                                .contextMenu { MusicTrackMenu(file: file, cloud: cloud) }
                        } else {
                            Label("Titel derzeit nicht im Katalog", systemImage: "exclamationmark.icloud")
                                .foregroundStyle(.secondary)
                                .accessibilityHint("Verknüpfung bleibt für eine spätere Wiederherstellung erhalten")
                        }
                    }
                    .onDelete { offsets in editTracks { $0.remove(atOffsets: offsets) } }
                    .onMove { from, to in editTracks { $0.move(fromOffsets: from, toOffset: to) } }
                    if playlist.trackIDs.isEmpty { Text("Füge Musik aus deinen bereits hochgeladenen Ordnern hinzu.").foregroundStyle(.secondary) }
                } footer: { Text("Das Entfernen eines Titels aus dieser Playlist löscht keine Datei in Telegram.") }
            } else {
                ContentUnavailableView("Playlist nicht vorhanden", systemImage: "music.note.list")
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            EditButton()
            Menu {
                Button("Umbenennen", systemImage: "pencil") { name = playlist?.name ?? ""; renaming = true }
                Button("Playlist löschen", systemImage: "trash", role: .destructive) { deleting = true }
            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Playlist-Aktionen") }
        }
        .sheet(isPresented: $adding) { MusicTrackPicker(playlistID: id, cloud: cloud).environmentObject(music) }
        .alert("Playlist umbenennen", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Speichern") {
                if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cloud.editMusic { library in if let i = library.playlists.firstIndex(where: { $0.id == id }) { library.playlists[i].edit(name: name) } }
                }
            }
            Button("Abbrechen", role: .cancel) { }
        }
        .confirmationDialog("Playlist löschen? Deine Musikdateien bleiben erhalten.", isPresented: $deleting, titleVisibility: .visible) {
            Button("Playlist löschen", role: .destructive) {
                if cloud.editMusic({ $0.playlists.removeAll { $0.id == id }; $0.deletedPlaylists[id] = Date().timeIntervalSince1970 }) { dismiss() }
            }
        }
    }
    private func editTracks(_ change: (inout [UUID]) -> Void) {
        cloud.editMusic { library in
            if let i = library.playlists.firstIndex(where: { $0.id == id }) {
                var tracks = library.playlists[i].trackIDs; change(&tracks); library.playlists[i].edit(tracks: tracks)
            }
        }
    }
}

private struct MusicTrackPicker: View {
    let playlistID: UUID
    @ObservedObject var cloud: CloudStore
    @EnvironmentObject private var music: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var folder: UUID?
    @State private var selected = Set<UUID>()
    private var existing: Set<UUID> { Set(cloud.musicLibrary.playlists.first { $0.id == playlistID }?.trackIDs ?? []) }
    private var files: [CloudFileEntry] {
        music.availableFiles.filter { (folder == nil || $0.folderID == folder) && music.matches($0, search: search) }
            .sorted { music.trackTitle($0).localizedStandardCompare(music.trackTitle($1)) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Picker("Ordner", selection: $folder) {
                    Text("Alle Ordner").tag(UUID?.none)
                    ForEach(cloud.index.folders) { folder in Text(cloud.folderPath(for: folder.id).map(\.name).joined(separator: " / ")).tag(Optional(folder.id)) }
                }
                Button("Sichtbare Titel auswählen") { selected.formUnion(files.map(\.id).filter { !existing.contains($0) }) }
                ForEach(files) { file in
                    Button {
                        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                    } label: {
                        HStack {
                            MusicTrackRow(file: file)
                            Image(systemName: existing.contains(file.id) || selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        }.foregroundStyle(.primary)
                    }.disabled(existing.contains(file.id))
                }
            }
            .navigationTitle("Titel hinzufügen")
            .searchable(text: $search, prompt: "Titel oder Künstler")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen (\(selected.count))") {
                        let ids = music.availableFiles.filter { selected.contains($0.id) }.sorted { music.trackTitle($0) < music.trackTitle($1) }.map(\.id)
                        if cloud.editMusic({ library in
                            if let i = library.playlists.firstIndex(where: { $0.id == playlistID }) { library.playlists[i].edit(tracks: library.playlists[i].trackIDs + ids) }
                        }) { dismiss() }
                    }.disabled(selected.isEmpty)
                }
            }
        }
    }
}

struct MusicMiniPlayer: View {
    @EnvironmentObject private var music: MusicPlayer
    var body: some View {
        HStack(spacing: 12) {
            Button { music.showingPlayer = true } label: {
                HStack(spacing: 12) {
                    MusicCover(image: music.artwork, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(music.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(music.offlineBusy ? "Offline-Datei wird geladen …" : music.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).foregroundStyle(.primary)
            }.buttonStyle(.plain).accessibilityLabel("Player öffnen: \(music.title)")
            if music.isBuffering { ProgressView().controlSize(.small) }
            Button { music.togglePlayback() } label: {
                Image(systemName: music.isPlaying || music.isBuffering ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 44)
            }.disabled(music.offlineBusy).accessibilityLabel(music.isPlaying || music.isBuffering ? "Pausieren" : "Abspielen")
            Button { music.next() } label: { Image(systemName: "forward.end.fill").frame(width: 32, height: 44) }
                .disabled(music.offlineBusy).accessibilityLabel("Nächster Titel")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .musicGlass(corner: 22)
        .overlay(alignment: .bottom) {
            if music.duration > 0 { ProgressView(value: min(1, music.elapsed / music.duration)).tint(.cyan).padding(.horizontal, 22).offset(y: -3) }
        }
        .frame(maxWidth: 600)
    }
}

struct MusicPlayerSheet: View {
    @EnvironmentObject private var music: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var seekValue = 0.0
    @State private var seeking = false
    @State private var panel = 0
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [.cyan.opacity(0.2), .blue.opacity(0.08), Color(uiColor: .systemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        MusicCover(image: music.artwork, size: 270)
                            .shadow(color: .blue.opacity(0.16), radius: 28, y: 16).padding(.top, 12)
                            .accessibilityLabel("Albumcover")
                        VStack(spacing: 6) {
                            Text(music.title).font(.title2.bold()).multilineTextAlignment(.center).textSelection(.enabled)
                            Text(music.artist).font(.title3).foregroundStyle(.secondary)
                            if let album = music.currentInfo?.album { Text(album).font(.subheadline).foregroundStyle(.secondary) }
                            if music.isBuffering { HStack { ProgressView().controlSize(.small); Text("Wird von Telegram geladen …").font(.caption) } }
                            if music.offlineBusy { HStack { ProgressView().controlSize(.small); Text("Offline-Datei wird geladen und geprüft …").font(.caption) } }
                        }
                        VStack(spacing: 2) {
                            Slider(value: Binding(get: { seeking ? seekValue : min(music.elapsed, max(1, music.duration)) }, set: { seekValue = $0 }),
                                   in: 0...max(1, music.duration), onEditingChanged: { editing in
                                if editing { seekValue = music.elapsed; seeking = true }
                                else { seeking = false; music.seek(seekValue) }
                            }).disabled(music.duration <= 0 || music.offlineBusy).tint(.cyan).accessibilityLabel("Wiedergabeposition")
                            HStack { Text(musicTime(seeking ? seekValue : music.elapsed)); Spacer(); Text("−" + musicTime(max(0, music.duration - (seeking ? seekValue : music.elapsed)))) }
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 20) {
                            Button { music.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(music.shuffle ? Color.cyan : .secondary) }
                                .accessibilityLabel("Zufallswiedergabe: \(music.shuffle ? "Ein" : "Aus")")
                            Button { music.previous() } label: { Image(systemName: "backward.end.fill").font(.title) }.accessibilityLabel("Vorheriger Titel")
                            Button { music.togglePlayback() } label: {
                                Image(systemName: music.isPlaying || music.isBuffering ? "pause.fill" : "play.fill")
                                    .font(.system(size: 30, weight: .semibold)).frame(width: 76, height: 76).musicGlass(corner: 38)
                            }.accessibilityLabel(music.isPlaying || music.isBuffering ? "Pausieren" : "Abspielen")
                            Button { music.next() } label: { Image(systemName: "forward.end.fill").font(.title) }.accessibilityLabel("Nächster Titel")
                            Button { music.cycleRepeat() } label: {
                                Image(systemName: music.queue.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(music.queue.repeatMode == .off ? Color.secondary : .cyan)
                            }.accessibilityLabel("Wiederholung: \(music.queue.repeatMode.label)")
                        }.buttonStyle(.plain).disabled(music.offlineBusy)
                        HStack(spacing: 16) {
                            MusicVolumeControl().frame(height: 32).accessibilityLabel("Lautstärke")
                            MusicRouteControl().frame(width: 44, height: 44).accessibilityLabel("AirPlay und Audioausgabe")
                        }
                        HStack {
                            Menu {
                                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in Button("\(speed.formatted())×") { music.setRate(Float(speed)) } }
                            } label: { Label("\(Double(music.rate).formatted())×", systemImage: "speedometer") }
                            Spacer()
                            Menu {
                                Button("Aus") { music.setSleep(minutes: nil) }
                                ForEach([5, 15, 30, 45, 60, 90], id: \.self) { minutes in Button("\(minutes) Minuten") { music.setSleep(minutes: minutes) } }
                            } label: {
                                if let date = music.sleepUntil { Label("Bis \(date.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz.fill") }
                                else { Label("Sleeptimer", systemImage: "moon") }
                            }
                        }.font(.subheadline).padding(15).musicGlass(corner: 18)
                        Picker("Playerdetails", selection: $panel) { Text("Warteschlange").tag(0); Text("Titelinfo").tag(1) }.pickerStyle(.segmented)
                        if panel == 0 { queuePanel } else { metadataPanel }
                    }.padding(.horizontal, 24).padding(.bottom, 30).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Jetzt läuft").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "chevron.down").accessibilityLabel("Player schließen") } }
                ToolbarItem(placement: .primaryAction) { Menu {
                    if let file = music.currentFile {
                        MusicTrackMenu(file: file, cloud: music.cloud)
                        if music.offlineURL(for: file) != nil {
                            Button("Offline-Kopie entfernen", systemImage: "arrow.down.circle", role: .destructive) { music.removeCurrentOffline() }
                        } else {
                            Button("Titel offline speichern", systemImage: "arrow.down.circle") { music.downloadCurrentOffline() }.disabled(music.cloud.isDownloading || music.offlineBusy)
                        }
                        Button("Metadaten aktualisieren", systemImage: "arrow.clockwise") { music.refreshMetadata() }.disabled(music.offlineBusy)
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Titel-Aktionen") } }
            }
        }
        .alert("Musikwiedergabe", isPresented: Binding(get: { music.error != nil }, set: { if !$0 { music.error = nil } })) {
            Button("Erneut versuchen") { music.togglePlayback() }
            Button("Schließen", role: .cancel) { music.error = nil }
        } message: { Text(music.error ?? "") }
    }
    private var queuePanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(music.queue.ids.enumerated()), id: \.element) { index, id in
                HStack {
                    Button { music.jumpTo(id) } label: {
                        if let file = music.cloud.index.files.first(where: { $0.id == id }) { MusicTrackRow(file: file) }
                        else { Label("Titel nicht verfügbar", systemImage: "exclamationmark.icloud") }
                    }.buttonStyle(.plain)
                    Menu {
                        if index > 0 { Button("Nach oben") { music.moveQueue(from: IndexSet(integer: index), to: index - 1) } }
                        if index + 1 < music.queue.ids.count { Button("Nach unten") { music.moveQueue(from: IndexSet(integer: index), to: index + 2) } }
                        if id != music.queue.current { Button("Aus Warteschlange entfernen", role: .destructive) { music.removeQueued(id) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44).accessibilityLabel("Titel in Warteschlange verwalten") }
                }.padding(.vertical, 5)
                if index + 1 < music.queue.ids.count { Divider() }
            }
        }.padding(14).musicGlass(corner: 22)
    }
    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let file = music.currentFile {
                LabeledContent("Dateiname", value: file.name)
                LabeledContent("Dateigröße", value: file.totalSize.byteCountString)
                LabeledContent("Format", value: (file.name as NSString).pathExtension.uppercased())
                LabeledContent("Quelle", value: music.offlineURL(for: file) != nil ? "Offline-Datei" : "Telegram")
                LabeledContent("Ordner", value: music.cloud.folderPath(for: file.folderID).map(\.name).joined(separator: " / ").isEmpty ? "Meine Dateien" : music.cloud.folderPath(for: file.folderID).map(\.name).joined(separator: " / "))
            }
            ForEach((music.currentInfo?.details ?? [:]).keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(metadataLabel(key)).font(.caption).foregroundStyle(.secondary)
                    Text(music.currentInfo?.details[key] ?? "").font(.subheadline).textSelection(.enabled)
                }
            }
            if music.currentInfo?.details.isEmpty != false { Text("In dieser Datei wurden noch keine eingebetteten Text-Metadaten erkannt.").font(.caption).foregroundStyle(.secondary) }
        }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(18).musicGlass(corner: 22)
    }
}

struct MusicCover: View {
    let image: UIImage?
    let size: CGFloat
    var symbol = "music.note"
    var body: some View {
        ZStack {
            LinearGradient(colors: [.cyan.opacity(0.65), .blue.opacity(0.7), .indigo.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                Circle().fill(.white.opacity(0.12)).frame(width: size * 0.8).offset(x: size * 0.3, y: -size * 0.3)
                Image(systemName: symbol).font(.system(size: size * 0.36, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.15).strokeBorder(.white.opacity(0.22), lineWidth: 0.7))
    }
}
private struct MusicGlass: ViewModifier {
    let corner: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular, in: .rect(cornerRadius: corner)) }
        else { content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner)).overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.18), lineWidth: 0.5)) }
    }
}
private extension View { func musicGlass(corner: CGFloat) -> some View { modifier(MusicGlass(corner: corner)) } }
private struct MusicRouteControl: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.prioritizesVideoDevices = false; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
private struct MusicVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { let view = MPVolumeView(); view.showsRouteButton = false; return view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) { }
}
func musicTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "0:00" }
    let total = Int(seconds)
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
}
private func metadataLabel(_ key: String) -> String {
    let lower = key.lowercased()
    let labels = [("tit2", "Titel"), ("tpe1", "Künstler"), ("tpe2", "Albumkünstler"), ("talb", "Album"), ("trck", "Titelnummer"), ("tpos", "CD-Nummer"), ("tcon", "Genre"), ("tdrc", "Veröffentlichung"), ("tyer", "Jahr"), ("uslt", "Liedtext"), ("comm", "Kommentar"), ("tcom", "Komponist"), ("copyright", "Urheberrecht"), ("albumartist", "Albumkünstler"), ("albumname", "Album"), ("artist", "Künstler"), ("title", "Titel"), ("creationdate", "Datum"), ("description", "Beschreibung"), ("genre", "Genre"), ("lyrics", "Liedtext")]
    return labels.first { lower.contains($0.0) }?.1 ?? key
}
