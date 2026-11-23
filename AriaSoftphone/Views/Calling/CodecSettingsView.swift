import SwiftUI

/// Which audio codecs to offer, and in what order. Drag to reorder.
struct CodecSettingsView: View {
    @State private var preferences = CodecPreferences.load()

    var body: some View {
        List {
            Section {
                ForEach($preferences.entries) { $entry in
                    Toggle(CodecPreferences.name(entry.codec), isOn: $entry.enabled)
                        .accessibilityIdentifier("codec.\(entry.id)")
                }
                .onMove { from, to in
                    preferences.entries.move(fromOffsets: from, toOffset: to)
                }
            } header: {
                Text("Preferred order")
            } footer: {
                Text("Calls offer the codecs that are on, first to last. Opus sounds best on a good connection; G.711 works with every phone system.")
            }

            Section {
                Button("Restore Defaults") { preferences = .standard }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Codecs")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: preferences) { updated in
            updated.save()
            SipEngineManager.shared.applyCodecPreferences(updated)
        }
    }
}
