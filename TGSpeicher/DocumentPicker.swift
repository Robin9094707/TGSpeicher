import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TGDocumentPicker: UIViewControllerRepresentable {
    let allowsMultipleSelection: Bool
    let onPicked: ([URL]) -> Void
    let onCancel: () -> Void

    init(
        allowsMultipleSelection: Bool = false,
        onPicked: @escaping ([URL]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onPicked = onPicked
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .pageSheet
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([URL]) -> Void
        let onCancel: () -> Void
        private var completed = false

        init(onPicked: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !completed else { return }
            completed = true
            DispatchQueue.main.async { self.onPicked(urls) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else { return }
            completed = true
            DispatchQueue.main.async { self.onCancel() }
        }
    }
}
