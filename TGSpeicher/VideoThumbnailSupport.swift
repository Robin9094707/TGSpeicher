import Foundation
import AVFoundation
import UIKit

struct TelegramVideoThumbnail {
    let url: URL
    let width: Int
    let height: Int

    var input: [String: Any] {
        [
            "@type": "inputThumbnail",
            "thumbnail": ["@type": "inputFileLocal", "path": url.path],
            "width": width,
            "height": height
        ]
    }
}

enum TelegramVideoThumbnailGenerator {
    static func generate(for videoURL: URL) -> TelegramVideoThumbnail? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        let times = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            CMTime(seconds: 0.1, preferredTimescale: 600),
            .zero
        ]

        var frame: CGImage?
        for time in times where frame == nil {
            frame = try? generator.copyCGImage(at: time, actualTime: nil)
        }
        guard let frame else { return nil }

        let image = UIImage(cgImage: frame)
        var jpeg: Data?
        for quality in [0.72, 0.60, 0.48, 0.36, 0.25] as [CGFloat] {
            guard let candidate = image.jpegData(compressionQuality: quality) else { continue }
            jpeg = candidate
            if candidate.count <= 195_000 { break }
        }
        guard let jpeg, jpeg.count <= 200_000 else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TGSpeicher-video-thumb-\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: url, options: [.atomic])
            return TelegramVideoThumbnail(
                url: url,
                width: max(1, frame.width),
                height: max(1, frame.height)
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
