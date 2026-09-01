import Foundation

@MainActor
final class RemoteURLImporter: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published var lastError: String?

    func start(
        urlString: String,
        folderID: UUID?,
        tagIDs: [UUID] = [],
        queue: UploadQueueManager
    ) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            lastError = "Enter a valid http:// or https:// URL."
            return
        }
        guard !isRunning else { return }

        isRunning = true
        status = "Downloading remote file…"
        lastError = nil

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 120
                request.setValue("TGSpeicher-iOS/2.3", forHTTPHeaderField: "User-Agent")
                let (temporaryURL, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                let proposed = response.suggestedFilename
                    ?? url.lastPathComponent.removingPercentEncoding
                    ?? "Remote-Upload.bin"
                let safeName = proposed.isEmpty ? "Remote-Upload.bin" : proposed
                let stagingFolder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TGSpeicherRemote", isDirectory: true)
                try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
                let destination = stagingFolder
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(safeName)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)

                status = "Adding to durable upload queue…"
                queue.enqueuePreparedFile(destination, folderID: folderID, tagIDs: tagIDs)
                isRunning = false
                status = "Remote file queued"

            } catch {
                isRunning = false
                status = ""
                lastError = error.localizedDescription
            }
        }
    }
}
