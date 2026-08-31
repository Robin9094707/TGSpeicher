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
        .accessibilityLabel("Open TGSpeicher Debug Console")
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
            .navigationTitle("TGSpeicher Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog(
            "Erase local Telegram data?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Erase Local Telegram Data", role: .destructive) {
                telegram.resetAPICredentials()
                isPresented = false
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes TGSpeicher's API ID/hash, TDLib encryption key, local Telegram database and temporary chunks from this iPhone. It does not delete messages or files stored in Telegram.")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection status", systemImage: "waveform.path.ecg")
                .font(.headline)

            debugRow("Authorization", telegram.lastAuthorizationStateName)
            debugRow("Client", telegram.clientDescription)
            debugRow("Credentials", telegram.hasAPICredentials ? "Stored locally" : "Not stored")

            if let activity = telegram.lastActivityAt {
                debugRow("Last activity", activity.formatted(date: .omitted, time: .standard))
            }

            Text("The debug log intentionally records TDLib states and request types only. Phone numbers, login codes, passwords and API hashes are not written to it.")
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
                Label("Retry Telegram Connection", systemImage: "arrow.clockwise.circle.fill")
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
                Label("Erase Local Telegram Data", systemImage: "trash.fill")
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
                Label("Live debug log", systemImage: "terminal.fill")
                    .font(.headline)
                Spacer()
                Text("\(telegram.debugLines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if telegram.debugLines.isEmpty {
                Text("No debug entries yet.")
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
