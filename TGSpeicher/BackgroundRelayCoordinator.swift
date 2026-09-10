import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class BackgroundRelayCoordinator: ObservableObject {
    static let shared = BackgroundRelayCoordinator()

    @Published private(set) var enabled = BackgroundRelayShared.enabled
    @Published private(set) var paired = BackgroundRelayShared.deviceToken != nil
    @Published private(set) var serverReachable = false
    @Published private(set) var statusText = "Bereit"
    @Published private(set) var lastContact = BackgroundRelayShared.lastServerContact
    @Published private(set) var lastError = BackgroundRelayShared.lastServerError
    @Published var allowCellular = BackgroundRelayShared.allowCellular {
        didSet {
            BackgroundRelayShared.allowCellular = allowCellular
            if enabled { Task { await updateSystemOptions() } }
        }
    }
    @Published var chargingOnly = BackgroundRelayShared.chargingOnly {
        didSet { BackgroundRelayShared.chargingOnly = chargingOnly }
    }
    @Published var needsFallbackDecision = false

    let baseURL = URL(string: BackgroundRelayShared.baseURLString)!
    private var checking = false
    private init() {}

    var deviceName: String { BackgroundRelayShared.deviceName }
    var lastExtensionRun: Date? { BackgroundRelayShared.lastExtensionRun }
    var lastSuccessfulDelivery: Date? { BackgroundRelayShared.lastSuccessfulDelivery }
    var extensionStatus: String { BackgroundRelayShared.extensionStatus }

    func pair(code: String, deviceName: String) async -> Bool {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { record(error: "Bitte den Einmal-Code aus dem Web-Dashboard eingeben."); return false }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/pair"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": clean, "device_name": deviceName])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["device_token"] as? String,
                  let id = json["device_id"] as? String else { throw URLError(.userAuthenticationRequired) }
            BackgroundRelayShared.deviceToken = token
            BackgroundRelayShared.deviceID = id
            BackgroundRelayShared.deviceName = deviceName
            paired = true
            BackgroundRelayShared.lastServerError = nil
            lastError = nil
            statusText = "iPhone sicher gekoppelt"
            _ = await ping(showFallback: false)
            return true
        } catch {
            record(error: "Kopplung fehlgeschlagen: \(error.localizedDescription)")
            return false
        }
    }

    func disconnect() async {
        await setEnabled(false, existingSourceKeys: [])
        BackgroundRelayShared.clearPairing()
        paired = false
        serverReachable = false
        needsFallbackDecision = false
        statusText = "Nicht gekoppelt"
    }

    @discardableResult
    func ping(showFallback: Bool = true) async -> Bool {
        guard let token = BackgroundRelayShared.deviceToken else { paired = false; serverReachable = false; return false }
        guard !checking else { return serverReachable }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/device/status"))
            request.timeoutInterval = 12
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            serverReachable = true
            paired = true
            lastContact = Date()
            BackgroundRelayShared.lastServerContact = lastContact
            BackgroundRelayShared.lastServerError = nil
            lastError = nil
            needsFallbackDecision = false
            statusText = enabled ? "Hintergrundserver erreichbar" : "Server erreichbar"
            objectWillChange.send()
            return true
        } catch {
            serverReachable = false
            record(error: "Background-Server nicht erreichbar: \(error.localizedDescription)")
            if enabled && showFallback { needsFallbackDecision = true }
            return false
        }
    }

    func setEnabled(_ value: Bool, existingSourceKeys: [String]) async {
        guard #available(iOS 27.0, *) else { record(error: "Die echte PhotoKit-Hintergrundsicherung benötigt iOS 27 oder neuer."); return }
        if value {
            guard paired else { record(error: "Kopple zuerst dieses iPhone mit dem Background-Server."); return }
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                record(error: "Für die Hintergrundsicherung ist vollständiger Zugriff auf deine Fotomediathek erforderlich.")
                return
            }
            guard await ping(showFallback: false) else { needsFallbackDecision = true; return }
            BackgroundRelayIndexStore.seedCompleted(existingSourceKeys)
            do {
                let options = PHAssetResourceUploadJobOptions()
                options.preventsExpensiveNetworkAccess = !allowCellular
                try PHPhotoLibrary.shared().enableUploadJobExtension(with: options)
                BackgroundRelayShared.enabled = true
                enabled = true
                needsFallbackDecision = false
                statusText = "Hintergrundsicherung aktiviert"
            } catch { record(error: "Hintergrundsicherung konnte nicht aktiviert werden: \(error.localizedDescription)") }
        } else {
            do { try PHPhotoLibrary.shared().disableUploadJobExtension() } catch { }
            BackgroundRelayShared.enabled = false
            enabled = false
            needsFallbackDecision = false
            statusText = "Hintergrundsicherung aus"
        }
    }

    func useDirectFallback() async {
        await setEnabled(false, existingSourceKeys: [])
        statusText = "Servermodus aus – TGSpeicher lädt wieder direkt zu Telegram"
        needsFallbackDecision = false
    }

    func appBecameActive() {
        enabled = BackgroundRelayShared.enabled
        paired = BackgroundRelayShared.deviceToken != nil
        lastContact = BackgroundRelayShared.lastServerContact
        lastError = BackgroundRelayShared.lastServerError
        objectWillChange.send()
        if enabled { Task { _ = await ping(showFallback: true) } }
    }

    func updateSystemOptions() async {
        guard #available(iOS 27.0, *), enabled else { return }
        do {
            let options = PHAssetResourceUploadJobOptions()
            options.preventsExpensiveNetworkAccess = !allowCellular
            try PHPhotoLibrary.shared().setUploadJobExtensionOptions(options)
        } catch { record(error: "Netzwerkoption konnte nicht aktualisiert werden: \(error.localizedDescription)") }
    }

    func clearError() { lastError = nil; BackgroundRelayShared.lastServerError = nil }
    private func record(error message: String) { lastError = message; BackgroundRelayShared.lastServerError = message; statusText = message }
}

struct BackgroundRelaySettingsView: View {
    @ObservedObject var cloud: CloudStore
    @StateObject private var relay = BackgroundRelayCoordinator.shared
    @State private var pairingCode = ""
    @State private var deviceName = UIDevice.current.name
    @State private var working = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: "backup.rjuhas.eu")
                HStack {
                    Label(relay.serverReachable ? "Erreichbar" : "Nicht geprüft / offline", systemImage: relay.serverReachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(relay.serverReachable ? .green : .secondary)
                    Spacer(); if working { ProgressView() }
                }
                Button("Server prüfen", systemImage: "network") { Task { working = true; _ = await relay.ping(showFallback: false); working = false } }
                if let date = relay.lastContact { LabeledContent("Letzter Kontakt", value: date.formatted(date: .abbreviated, time: .standard)) }
                if let date = relay.lastExtensionRun { LabeledContent("Letzter iOS-Lauf", value: date.formatted(date: .abbreviated, time: .standard)) }
                if let date = relay.lastSuccessfulDelivery { LabeledContent("Letzte Übergabe", value: date.formatted(date: .abbreviated, time: .standard)) }
                Text(relay.extensionStatus).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Background Relay") } footer: {
                Text("Der Server ist nur ein optionaler Hintergrundweg. Deine bisherige direkte Telegram-Sicherung bleibt vollständig erhalten.")
            }

            if !relay.paired {
                Section("iPhone koppeln") {
                    TextField("Gerätename", text: $deviceName)
                    TextField("Einmal-Code aus dem Web-Dashboard", text: $pairingCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Sicher koppeln", systemImage: "link.badge.plus") {
                        Task { working = true; _ = await relay.pair(code: pairingCode, deviceName: deviceName); pairingCode = ""; working = false }
                    }.disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
            } else {
                Section {
                    Toggle("Hintergrundsicherung", isOn: Binding(get: { relay.enabled }, set: { value in
                        Task { working = true; await relay.setEnabled(value, existingSourceKeys: cloud.index.files.compactMap(\.sourceKey)); working = false }
                    }))
                    Toggle("Mobile Daten erlauben", isOn: $relay.allowCellular).disabled(!relay.enabled)
                    Toggle("Nur beim Laden", isOn: $relay.chargingOnly).disabled(!relay.enabled)
                    Text("„Nur beim Laden“ ist eine zusätzliche TGSpeicher-Regel. iOS entscheidet weiterhin selbst, wann die Background-Extension aufgerufen wird.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Automatische Fotosicherung") } footer: {
                    Text("Mit ausgeschalteten mobilen Daten setzt iOS diese Upload-Konfiguration auf nicht-teure Netzwerke wie WLAN oder Ethernet.")
                }
                Section("Kopplung") {
                    LabeledContent("Gerät", value: relay.deviceName)
                    Button("Kopplung dieses iPhones entfernen", systemImage: "link.badge.minus", role: .destructive) {
                        Task { working = true; await relay.disconnect(); working = false }
                    }
                }
            }

            if let error = relay.lastError {
                Section("Hinweis") {
                    Text(error).foregroundStyle(.secondary)
                    if relay.enabled {
                        Button("Vorläufig direkt zu Telegram weiterarbeiten", systemImage: "paperplane.fill") { Task { await relay.useDirectFallback() } }
                    }
                    Button("Hinweis ausblenden") { relay.clearError() }
                }
            }
        }
        .navigationTitle("Hintergrundsicherung")
        .onAppear { relay.appBecameActive() }
    }
}
