import SwiftUI

/// Which audio codecs to offer, and in what order. Drag to reorder.
struct CodecSettingsView: View {
    @State private var preferences = CodecPreferences.load()

    var body: some View {
        List {
            Section {
                ForEach($preferences.entries) { $entry in
                    Toggle(isOn: $entry.enabled) {
                        Text(CodecPreferences.name(entry.codec))
                            .ariaFont(.body)
                            .foregroundStyle(AriaColor.onSurface)
                    }
                    .tint(AriaColor.primary)
                    .frame(minHeight: ComponentSize.row)
                    .listRowBackground(AriaColor.surface)
                    .accessibilityIdentifier("codec.\(entry.id)")
                }
                .onMove { from, to in
                    preferences.entries.move(fromOffsets: from, toOffset: to)
                }
            } header: {
                Text("Preferred order")
                    .ariaFont(.label)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
            } footer: {
                Text("Calls offer the codecs that are on, first to last. Opus sounds best on a good connection; G.711 works with every phone system.")
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
            }

            Section {
                AriaButton("Restore Defaults", kind: .plain) { preferences = .standard }
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AriaColor.background)
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Codecs")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: preferences) { _, updated in
            updated.save()
            SipEngineManager.shared.applyCodecPreferences(updated)
        }
    }
}
