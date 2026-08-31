import Foundation

enum ChunkerError: LocalizedError {
    case invalidFile
    case cannotCreateOutput

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "The selected file could not be read."
        case .cannotCreateOutput: return "TGSpeicher could not create a temporary upload file."
        }
    }
}

struct PreparedChunk {
    let url: URL
    let index: Int
    let count: Int
    let size: Int64
}

enum FileChunker {
    static func prepare(
        source: URL,
        maxChunkBytes: Int64,
        progress: @escaping (Int64, Int64) -> Void
    ) throws -> [PreparedChunk] {
        guard maxChunkBytes > 0 else { throw ChunkerError.invalidFile }
        let totalSize = source.fileByteSize
        guard totalSize >= 0 else { throw ChunkerError.invalidFile }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicherChunks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let count = max(1, Int(ceil(Double(max(totalSize, 1)) / Double(maxChunkBytes))))
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        var completed: Int64 = 0
        var output: [PreparedChunk] = []
        let bufferSize = 4 * 1024 * 1024

        for part in 0..<count {
            let suffix = count == 1 ? "" : String(format: ".tgs.part%04d-of-%04d", part + 1, count)
            let destination = root.appendingPathComponent(source.lastPathComponent + suffix)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ChunkerError.cannotCreateOutput
            }
            let writer = try FileHandle(forWritingTo: destination)
            var written: Int64 = 0
            let target = min(maxChunkBytes, max(0, totalSize - Int64(part) * maxChunkBytes))

            while written < target {
                let remaining = target - written
                let request = Int(min(Int64(bufferSize), remaining))
                guard let data = try reader.read(upToCount: request), !data.isEmpty else { break }
                try writer.write(contentsOf: data)
                written += Int64(data.count)
                completed += Int64(data.count)
                progress(completed, totalSize)
            }
            try writer.close()
            output.append(PreparedChunk(url: destination, index: part + 1, count: count, size: written))
        }

        return output
    }

    static func cleanup(_ chunks: [PreparedChunk]) {
        guard let parent = chunks.first?.url.deletingLastPathComponent() else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    static func join(chunks: [URL], destination: URL, progress: @escaping (Int64) -> Void) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ChunkerError.cannotCreateOutput
        }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        var completed: Int64 = 0

        for url in chunks {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            while let data = try reader.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                try writer.write(contentsOf: data)
                completed += Int64(data.count)
                progress(completed)
            }
        }
    }
}
