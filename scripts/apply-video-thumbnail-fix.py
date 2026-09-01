from pathlib import Path

cloud_path = Path("TGSpeicher/CloudStore.swift")
text = cloud_path.read_text()

anchor = '        let caption: [String: Any] = ["@type": "formattedText", "text": readableCaption, "entities": []]\n        let content: [String: Any]\n'
replacement = '''        let caption: [String: Any] = ["@type": "formattedText", "text": readableCaption, "entities": []]
        let generatedVideoThumbnail = descriptor.kind == "video"
            ? TelegramVideoThumbnailGenerator.generate(for: url)
            : nil
        let videoThumbnail: Any
        if let generatedVideoThumbnail {
            videoThumbnail = generatedVideoThumbnail.input
        } else {
            videoThumbnail = NSNull()
        }
        let content: [String: Any]
'''
if anchor in text:
    text = text.replace(anchor, replacement, 1)
elif 'let generatedVideoThumbnail = descriptor.kind == "video"' not in text:
    raise SystemExit("Could not locate native-media caption anchor in CloudStore.swift")

old_thumb = '                "thumbnail": NSNull(), "cover": NSNull(), "start_timestamp": 0,\n'
new_thumb = '                "thumbnail": videoThumbnail, "cover": NSNull(), "start_timestamp": 0,\n'
if old_thumb in text:
    text = text.replace(old_thumb, new_thumb, 1)
elif '"thumbnail": videoThumbnail, "cover": NSNull()' not in text:
    raise SystemExit("Could not locate inputMessageVideo thumbnail field")

callback_anchor = '''        telegram.sendMessageAwaitingFinal(request) { [weak self] response in
            guard let self else { return }
'''
callback_replacement = '''        telegram.sendMessageAwaitingFinal(request) { [weak self] response in
            if let thumbnailURL = generatedVideoThumbnail?.url {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                    try? FileManager.default.removeItem(at: thumbnailURL)
                }
            }
            guard let self else { return }
'''
if callback_anchor in text:
    text = text.replace(callback_anchor, callback_replacement, 1)
elif "if let thumbnailURL = generatedVideoThumbnail?.url" not in text:
    raise SystemExit("Could not locate native-media send callback")

cloud_path.write_text(text)

helper = '''import Foundation
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
            .appendingPathComponent("TGSpeicher-video-thumb-\\(UUID().uuidString).jpg")
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
'''
Path("TGSpeicher/VideoThumbnailSupport.swift").write_text(helper)

project_path = Path("project.yml")
project = project_path.read_text()
project = project.replace("CURRENT_PROJECT_VERSION: 28", "CURRENT_PROJECT_VERSION: 29")
project = project.replace("MARKETING_VERSION: 2.4.0", "MARKETING_VERSION: 2.4.1")
project_path.write_text(project)
