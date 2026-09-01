import Foundation
import CryptoKit

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
    let sha256: String
}

struct PreparedFile {
    let chunks: [PreparedChunk]
    let totalSize: Int64
    let sha256: String
    let temporaryDirectory: URL?
}

enum FileChunker {
    static func prepare(
        source: URL,
        maxChunkBytes: Int64,
        progress: @escaping (Int64, Int64) -> Void
    ) throws -> PreparedFile {
        guard maxChunkBytes > 0 else { throw ChunkerError.invalidFile }
        let totalSize = source.fileByteSize
        guard totalSize >= 0 else { throw ChunkerError.invalidFile }

        let count = max(1, Int(ceil(Double(max(totalSize, 1)) / Double(maxChunkBytes))))

        // Most camera files fit into a single Telegram document. Hashing the durable
        // queue copy in place avoids creating and writing a second full-size copy.
        if count == 1 {
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close() }
            var hasher = SHA256()
            var completed: Int64 = 0
            while let data = try reader.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
                completed += Int64(data.count)
                progress(completed, totalSize)
            }
            let digest = hex(hasher.finalize())
            return PreparedFile(
                chunks: [PreparedChunk(url: source, index: 1, count: 1, size: totalSize, sha256: digest)],
                totalSize: totalSize,
                sha256: digest,
                temporaryDirectory: nil
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicherChunks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var shouldRemoveRootOnExit = true
        defer {
            if shouldRemoveRootOnExit { try? FileManager.default.removeItem(at: root) }
        }

        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        var completed: Int64 = 0
        var output: [PreparedChunk] = []
        var fileHasher = SHA256()
        let bufferSize = 4 * 1024 * 1024

        for part in 0..<count {
            let suffix = count == 1 ? "" : String(format: ".tgs.part%04d-of-%04d", part + 1, count)
            let destination = root.appendingPathComponent(source.lastPathComponent + suffix)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ChunkerError.cannotCreateOutput
            }

            let writer = try FileHandle(forWritingTo: destination)
            var chunkHasher = SHA256()
            var written: Int64 = 0
            let target = min(maxChunkBytes, max(0, totalSize - Int64(part) * maxChunkBytes))

            while written < target {
                let remaining = target - written
                let request = Int(min(Int64(bufferSize), remaining))
                guard let data = try reader.read(upToCount: request), !data.isEmpty else { break }
                try writer.write(contentsOf: data)
                chunkHasher.update(data: data)
                fileHasher.update(data: data)
                written += Int64(data.count)
                completed += Int64(data.count)
                progress(completed, totalSize)
            }
            try writer.close()

            output.append(
                PreparedChunk(
                    url: destination,
                    index: part + 1,
                    count: count,
                    size: written,
                    sha256: hex(chunkHasher.finalize())
                )
            )
        }

        shouldRemoveRootOnExit = false
        return PreparedFile(
            chunks: output,
            totalSize: totalSize,
            sha256: hex(fileHasher.finalize()),
            temporaryDirectory: root
        )
    }

    static func cleanup(_ prepared: PreparedFile) {
        guard let temporaryDirectory = prepared.temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
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

    static func sha256(of url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hasher = SHA256()
        while let data = try reader.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
