import ActivityKit
import Foundation

struct TransferActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var fileName: String
        var fraction: Double
        var detail: String
        var speed: String
        var pending: Int
        var backupCompleted: Int
        var backupTotal: Int
        var nightMode: Bool
        var paused: Bool
    }
    var startedAt: Date
}
