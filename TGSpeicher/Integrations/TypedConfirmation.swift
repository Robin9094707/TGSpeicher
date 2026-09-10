import SwiftUI

struct TypedConfirmationSheet: View {
    let title: String
    let message: String
    let phrase: String
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    var body: some View {
        NavigationStack {
            Form {
                Section { Label(title, systemImage: "exclamationmark.shield.fill").foregroundStyle(.red); Text(message) }
                Section("Zur Bestätigung genau eingeben") {
                    Text(phrase).font(.callout.weight(.semibold))
                    TextField("Bestätigung", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Bestätigungstext eingeben")
                }
                Section {
                    Button(title, role: .destructive) {
                        guard DestructiveConfirmation.matches(input, phrase: phrase) else { return }
                        dismiss(); action()
                    }.disabled(!DestructiveConfirmation.matches(input, phrase: phrase))
                }
            }.navigationTitle("Sicher bestätigen")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}
