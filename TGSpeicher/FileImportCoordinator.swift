import Foundation

extension CloudStore {
    /// Stages a document-picker result into TGSpeicher's own Documents/Upload Inbox
    /// before hashing or uploading it. This avoids keeping a fragile File Provider /
    /// security-scoped URL alive during a long Telegram upload.
    func importPickedFileAndUpload(_ sourceURL: URL, folderID: UUID?) {
        guard upload == nil else {
            lastError = "Es läuft bereits ein Upload."
            return
        }
        guard let inbox = inboxFolderURL else {
            lastError = "Der Datei-Eingang konnte nicht geöffnet werden."
            return
        }

        let originalName = sourceURL.lastPathComponent.isEmpty ? "Importierte Datei" : sourceURL.lastPathComponent
        let accessed = sourceURL.startAccessingSecurityScopedResource()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

            do {
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                let destination = Self.tgUniqueImportDestination(in: inbox, preferredName: originalName)

                var coordinationError: NSError?
                var copyError: Error?
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(readingItemAt: sourceURL, options: [.withoutChanges], error: &coordinationError) { coordinatedURL in
                    do {
                        try FileManager.default.copyItem(at: coordinatedURL, to: destination)
                    } catch {
                        copyError = error
                    }
                }

                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }

                DispatchQueue.main.async {
                    self.refreshLocalInbox()
                    self.uploadFile(destination, folderID: folderID)
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Die Datei konnte nicht importiert werden: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func tgUniqueImportDestination(in folder: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (preferredName as NSString).pathExtension
        let base = (preferredName as NSString).deletingPathExtension
        var index = 2
        repeat {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

