import SwiftUI
import Combine
import UIKit

enum TGAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum TGDriveViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var label: String { self == .list ? "List" : "Grid" }
    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

enum TGDriveSortMode: String, CaseIterable, Identifiable {
    case modifiedNewest
    case modifiedOldest
    case nameAZ
    case nameZA
    case sizeLargest
    case sizeSmallest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modifiedNewest: return "Newest"
        case .modifiedOldest: return "Oldest"
        case .nameAZ: return "Name A–Z"
        case .nameZA: return "Name Z–A"
        case .sizeLargest: return "Largest"
        case .sizeSmallest: return "Smallest"
        }
    }

    func sort(_ files: [CloudFileEntry]) -> [CloudFileEntry] {
        switch self {
        case .modifiedNewest:
            return files.sorted { $0.modifiedAt > $1.modifiedAt }
        case .modifiedOldest:
            return files.sorted { $0.modifiedAt < $1.modifiedAt }
        case .nameAZ:
            return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameZA:
            return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeLargest:
            return files.sorted { $0.totalSize > $1.totalSize }
        case .sizeSmallest:
            return files.sorted { $0.totalSize < $1.totalSize }
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let appearance = "ui.appearance"
        static let viewMode = "ui.drive-view-mode"
        static let sortMode = "ui.drive-sort-mode"
        static let gridScale = "ui.grid-scale"
        static let showFileExtensions = "ui.show-file-extensions"
        static let haptics = "ui.haptics"
        static let notifyTransfers = "ui.notify-transfers"
        static let keepScreenAwake = "transfer.keep-screen-awake"
        static let wifiOnly = "transfer.wifi-only"
    }

    private let defaults: UserDefaults

    @Published var appearance: TGAppearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    @Published var driveViewMode: TGDriveViewMode { didSet { defaults.set(driveViewMode.rawValue, forKey: Keys.viewMode) } }
    @Published var sortMode: TGDriveSortMode { didSet { defaults.set(sortMode.rawValue, forKey: Keys.sortMode) } }
    @Published var gridScale: Double { didSet { defaults.set(gridScale, forKey: Keys.gridScale) } }
    @Published var showFileExtensions: Bool { didSet { defaults.set(showFileExtensions, forKey: Keys.showFileExtensions) } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Keys.haptics) } }
    @Published var transferNotifications: Bool { didSet { defaults.set(transferNotifications, forKey: Keys.notifyTransfers) } }
    @Published var keepScreenAwakeDuringTransfers: Bool { didSet { defaults.set(keepScreenAwakeDuringTransfers, forKey: Keys.keepScreenAwake) } }
    @Published var wifiOnlyUploads: Bool { didSet { defaults.set(wifiOnlyUploads, forKey: Keys.wifiOnly) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = TGAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "system") ?? .system
        driveViewMode = TGDriveViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "list") ?? .list
        sortMode = TGDriveSortMode(rawValue: defaults.string(forKey: Keys.sortMode) ?? "modifiedNewest") ?? .modifiedNewest
        let storedScale = defaults.double(forKey: Keys.gridScale)
        gridScale = storedScale == 0 ? 1.0 : min(2.0, max(0.5, storedScale))
        showFileExtensions = defaults.object(forKey: Keys.showFileExtensions) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        transferNotifications = defaults.object(forKey: Keys.notifyTransfers) as? Bool ?? true
        keepScreenAwakeDuringTransfers = defaults.object(forKey: Keys.keepScreenAwake) as? Bool ?? true
        wifiOnlyUploads = defaults.object(forKey: Keys.wifiOnly) as? Bool ?? false
    }

    func performHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .soft) {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
