import Foundation

/// The audio codecs to offer, in order, as the user arranged them. Stored in
/// UserDefaults; handed to the core with `set_codec_preferences` and on every
/// call.
struct CodecPreferences: Equatable {
    struct Entry: Equatable, Identifiable {
        let codec: AudioCodec
        var enabled: Bool
        var id: String { CodecPreferences.key(codec) }
    }

    var entries: [Entry]

    static let storageKey = "codecPreferences"

    /// The core's own default: Opus, then G.711 µ-law and A-law. G.729 is
    /// listed but off: few PBX routes carry it.
    static let standard = CodecPreferences(entries: [
        Entry(codec: .opus, enabled: true),
        Entry(codec: .pcmu, enabled: true),
        Entry(codec: .pcma, enabled: true),
        Entry(codec: .g729, enabled: false),
    ])

    /// The enabled codecs in order; never empty (falls back to G.711 µ-law,
    /// which every SIP endpoint has).
    var ordered: [AudioCodec] {
        let enabled = entries.filter(\.enabled).map(\.codec)
        return enabled.isEmpty ? [.pcmu] : enabled
    }

    static func key(_ codec: AudioCodec) -> String {
        switch codec {
        case .opus: return "opus"
        case .pcmu: return "pcmu"
        case .pcma: return "pcma"
        case .g729: return "g729"
        }
    }

    static func name(_ codec: AudioCodec) -> String {
        switch codec {
        case .opus: return "Opus"
        case .pcmu: return "G.711 µ-law (PCMU)"
        case .pcma: return "G.711 A-law (PCMA)"
        case .g729: return "G.729"
        }
    }

    private static func codec(forKey key: String) -> AudioCodec? {
        [AudioCodec.opus, .pcmu, .pcma, .g729].first { Self.key($0) == key }
    }

    /// Stored as `["opus:1", "pcmu:1", ...]`. Unknown entries are dropped and
    /// codecs missing from the stored list are appended, disabled, so a newly
    /// supported codec appears without turning itself on.
    static func load(from defaults: UserDefaults = .standard) -> CodecPreferences {
        guard let stored = defaults.stringArray(forKey: storageKey) else { return .standard }
        var entries: [Entry] = []
        for item in stored {
            let parts = item.split(separator: ":")
            guard parts.count == 2, let codec = codec(forKey: String(parts[0])),
                  !entries.contains(where: { $0.codec == codec }) else { continue }
            entries.append(Entry(codec: codec, enabled: parts[1] == "1"))
        }
        for entry in standard.entries where !entries.contains(where: { $0.codec == entry.codec }) {
            entries.append(Entry(codec: entry.codec, enabled: false))
        }
        return CodecPreferences(entries: entries)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(entries.map { "\(Self.key($0.codec)):\($0.enabled ? 1 : 0)" }, forKey: Self.storageKey)
    }
}
