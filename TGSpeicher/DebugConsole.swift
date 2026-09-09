import SwiftUI
import UIKit

// Emergency controls are mounted at the app root so recovery stays available on every screen.
struct EmergencyDebugOverlay: View {
    @ObservedObject var telegram: TelegramClient
    @State private var showConsole = false

    var body: some View {
        Button {
            showConsole = true
        } label: {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 0.7)
                }
                .shadow(radius: 10, y: 5)
        }
        .accessibilityLabel("TGSpeicher-Diagnose öffnen")
        .sheet(isPresented: $showConsole) {
            DebugConsoleView(telegram: telegram, isPresented: $showConsole)
        }
    }
}

struct DebugConsoleView: View {
    @ObservedObject var telegram: TelegramClient
    @Binding var isPresented: Bool
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    actionsCard
                    logCard
                }
                .padding()
            }
            .navigationTitle("TGSpeicher-Diagnose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog(
            "Lokale Telegram-Daten löschen?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Lokale Telegram-Daten löschen", role: .destructive) {
                telegram.resetAPICredentials()
                isPresented = false
            }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("API-Zugangsdaten, lokaler Telegram-Schlüssel, Sitzungsdaten und temporäre Dateiteile werden vom iPhone entfernt. Nachrichten und Dateien in Telegram bleiben erhalten.")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Verbindungsstatus", systemImage: "waveform.path.ecg")
                .font(.headline)

            debugRow("Anmeldung", telegram.lastAuthorizationStateName)
            debugRow("Client", telegram.clientDescription)
            debugRow("Credentials", telegram.hasAPICredentials ? "Stored locally" : "Not stored")

            if let activity = telegram.lastActivityAt {
                debugRow("Letzte Aktivität", activity.formatted(date: .omitted, time: .standard))
            }

            Text("Das Diagnoseprotokoll enthält Zustände und Anfragetypen. Telefonnummern, Anmeldecodes, Passwörter und API-Hashes werden nicht protokolliert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                telegram.retryConnection()
                isPresented = false
            } label: {
                Label("Telegram-Verbindung erneut versuchen", systemImage: "arrow.clockwise.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!telegram.hasAPICredentials)

            Button {
                UIPasteboard.general.string = telegram.debugText
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Debug Log", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("Lokale Telegram-Daten löschen", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live-Diagnoseprotokoll", systemImage: "terminal.fill")
                    .font(.headline)
                Spacer()
                Text("\(telegram.debugLines.count) Einträge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if telegram.debugLines.isEmpty {
                Text("Noch keine Diagnoseeinträge.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(telegram.debugText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
    }

    private func debugRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

