import Foundation
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case vertical, horizontal

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@MainActor
@Observable
final class AppSettings {
    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }
    var readingMode: ReadingMode {
        didSet { defaults.set(readingMode.rawValue, forKey: Self.readingModeKey) }
    }
    var showsPageNumber: Bool {
        didSet { defaults.set(showsPageNumber, forKey: Self.showsPageNumberKey) }
    }

    static let appearanceKey = "appearance"
    static let readingModeKey = "readingMode"
    static let showsPageNumberKey = "showsPageNumber"
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        readingMode = ReadingMode(rawValue: defaults.string(forKey: Self.readingModeKey) ?? "") ?? .vertical
        showsPageNumber = defaults.object(forKey: Self.showsPageNumberKey) as? Bool ?? true
    }
}
