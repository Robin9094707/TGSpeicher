import SwiftUI
import UniformTypeIdentifiers

struct RecoveryCenterView: View {
    @ObservedObject var cloud: CloudStore
    @State private var importing = false
    @State private var messageID = ""

    private var busy: Bool { cloud.isRefreshing || cloud.isCatalogSyncing || cloud.upload != nil || cloud.isDeleting }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: cloud.recoveryReady ? "checkmark.shield.fill" : "arrow.triangle.2.circlepath")
                        .font(.largeTitle).foregroundStyle(cloud.recoveryReady ? .green : .blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(cloud.recoveryReady ? "Katalog bereit" : "Wiederherstellung").font(.headline)
                        Text(cloud.recoveryProgress).font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                LabeledContent("Dateien", value: "\(cloud.index.files.count)")
                LabeledContent("Ordner", value: "\(cloud.index.folders.count)")
                if let date = cloud.index.lastSyncedAt {
                    LabeledContent("Letzte Telegram-Sicherung", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if cloud.lastCatalogBytes > 0 { LabeledContent("Kataloggröße", value: Int64(cloud.lastCatalogBytes).byteCountString) }
                if let count = cloud.index.recovery?.partialFiles.count, count > 0 {
                    LabeledContent("Unvollständige Übertragungen", value: "\(count)")
                }
            }
            Section {
                Button("Jetzt in Telegram sichern", systemImage: "arrow.up.doc") { cloud.syncCatalogNow() }
                    .disabled(!cloud.recoveryReady || busy)
                Button("Katalog als Datei exportieren", systemImage: "square.and.arrow.up") { cloud.exportRecoveryCatalog() }
                    .disabled(!cloud.recoveryReady || busy)
                if let url = cloud.lastExportURL, url.pathExtension == "tgscatalog" {
                    ShareLink(item: url) { Label("Katalogdatei teilen oder speichern", systemImage: "doc.zipper") }
                }
            } header: { Text("Sichern") } footer: {
                Text("Der komprimierte Katalog enthält Ordner, Tags, Kanäle und Nachrichten-IDs. Fotos und Videos bleiben im gewählten Telegram-Kanal. Ältere Katalogsicherungen bleiben erhalten.")
            }
            Section {
                Button("Mit Telegram abgleichen", systemImage: "arrow.clockwise") { cloud.bootstrapFromTelegram() }
                    .disabled(busy)
                Button("Alle Nachrichten erneut prüfen", systemImage: "magnifyingglass") { cloud.fullRebuildFromTelegram() }
                    .disabled(busy)
                Button("Katalogdatei importieren", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(busy)
                TextField("Katalog- oder Verweis-Nachrichten-ID", text: $messageID).keyboardType(.numberPad)
                Button("Aus Nachrichten-ID wiederherstellen", systemImage: "arrow.down.doc") { cloud.restoreFromCatalogPointer(messageID) }
                    .disabled(messageID.isEmpty || busy)
            } header: { Text("Wiederherstellen") } footer: {
                Text("Importierte Kataloge werden geprüft und mit vorhandenen Einträgen zusammengeführt. Vor dem Import wird eine lokale Rückfallkopie angelegt. Bei unklaren Sendevorgängen bleibt der Upload angehalten, bis Telegram abgeglichen ist.")
            }
            Section {
                Text(cloud.keychainStatus).font(.subheadline)
                Button("Wiederherstellungsverweise aktualisieren", systemImage: "key.icloud") { cloud.refreshRecoveryAnchor() }
                    .disabled(busy)
            } header: { Text("iCloud-Schlüsselbund") } footer: {
                Text("Gespeichert werden nur kleine Verweise auf Konto, Kanal und Katalog. Die Synchronisierung hängt von iCloud-Schlüsselbund und der App-Signierung ab. Der Telegram-Abgleich funktioniert auch ohne diese Verweise; den Kanal bei Bedarf erneut auswählen.")
            }
        }
        .navigationTitle("Sichern & Wiederherstellen")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { cloud.importRecoveryCatalog(from: url) }
            case .failure(let error): cloud.lastError = error.localizedDescription
            }
        }
    }
}

struct RecoveryStatusBanner: View {
    @ObservedObject var cloud: CloudStore
    var body: some View {
        if !cloud.recoveryReady {
            HStack(spacing: 12) {
                if cloud.isRefreshing { ProgressView() }
                else { Image(systemName: "arrow.clockwise.icloud").foregroundStyle(.blue) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Katalog zuerst abgleichen").font(.subheadline.weight(.semibold))
                    Text(cloud.recoveryProgress).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if !cloud.isRefreshing {
                    Button("Prüfen") { cloud.bootstrapFromTelegram() }.buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal).padding(.top, 4)
        }
    }
}
