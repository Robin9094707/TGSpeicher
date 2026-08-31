import SwiftUI
import QuickLook
import AVKit

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

enum TGLocalDownloads {
    static var folderURL: URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func allFiles() -> [URL] {
        guard let folderURL else { return [] }
        let values: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: values,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }

    static func matching(_ file: CloudFileEntry, preferred: URL? = nil) -> URL? {
        if let preferred,
           FileManager.default.fileExists(atPath: preferred.path),
           preferred.lastPathComponent == file.name {
            return preferred
        }
        return allFiles().first { $0.lastPathComponent == file.name }
    }

    static func totalBytes() -> Int64 {
        allFiles().reduce(Int64(0)) { total, url in total + url.fileByteSize }
    }

    static func clear() throws {
        guard let folderURL else { return }
        for url in allFiles() { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }
}

struct LocalDownloadsView: View {
    @State private var files = TGLocalDownloads.allFiles()
    @State private var previewURL: URL?
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                LabeledContent("Offline files", value: "\(files.count)")
                LabeledContent("Disk usage", value: TGLocalDownloads.totalBytes().byteCountString)
            }

            Section("Downloaded files") {
                if files.isEmpty {
                    ContentUnavailableView(
                        "No offline downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Downloaded Telegram files appear here and in the Files app.")
                    )
                } else {
                    ForEach(files, id: \.self) { url in
                        Button {
                            previewURL = url
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.fill").foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.lastPathComponent).foregroundStyle(.primary).lineLimit(1)
                                    Text(url.fileByteSize.byteCountString).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                try? FileManager.default.removeItem(at: url)
                                reload()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !files.isEmpty {
                Section {
                    Button("Clear offline downloads", systemImage: "trash", role: .destructive) {
                        confirmClear = true
                    }
                }
            }
        }
        .navigationTitle("Offline Files")
        .onAppear(perform: reload)
        .refreshable { reload() }
        .sheet(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let previewURL {
                NavigationStack {
                    QuickLookPreview(url: previewURL)
                        .ignoresSafeArea()
                        .navigationTitle(previewURL.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .confirmationDialog("Delete every offline download?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Downloads", role: .destructive) {
                try? TGLocalDownloads.clear()
                reload()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func reload() { files = TGLocalDownloads.allFiles() }
}

