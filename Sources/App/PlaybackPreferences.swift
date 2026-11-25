import Foundation

/// Requested stream quality. Kept as a preference even though playback is now native:
/// the resolver can use it to pick a lower-quality progressive format on slow links.
enum PlaybackAudioQuality: String, CaseIterable, Identifiable {
    case auto, low, normal, high

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    static let storageKey = "settings.playbackAudioQuality"

    static var current: PlaybackAudioQuality {
        UserDefaults.standard.string(forKey: self.storageKey).flatMap(Self.init(rawValue:)) ?? .auto
    }
}

/// Playback buffering preferences (retained for the settings UI).
enum BufferPolicy {
    static let extendedStorageKey = "settings.extendedBuffer"
    static let adaptiveQualityStorageKey = "settings.adaptiveQuality"
    static let extendedReadaheadSeconds = 240

    static var isExtended: Bool {
        UserDefaults.standard.bool(forKey: self.extendedStorageKey)
    }

    static var adaptsQuality: Bool {
        UserDefaults.standard.object(forKey: self.adaptiveQualityStorageKey) as? Bool ?? true
    }
}

/// "Skip ads automatically" preference. Native playback has no ads to skip, but the
/// preference is kept so existing settings and saved values still load.
enum AdSkip {
    static let storageKey = "settings.adAutoSkip"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: self.storageKey)
    }
}

/// "Save data on music videos" preference.
enum DataSaver {
    static let storageKey = "settings.dataSaver"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: self.storageKey) as? Bool ?? true
    }
}
