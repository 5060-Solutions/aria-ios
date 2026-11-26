import SwiftUI

/// The address book (DESIGN.md §5 Contacts): search at the top, favorites
/// as a carousel, then A–Z with an index.
struct ContactsView: View {
    @EnvironmentObject var callManager: CallManager
    @ObservedObject private var favorites = FavoriteContacts.shared
    @State private var contacts: [ContactEntry] = []
    @State private var searchText = ""
    @State private var access = Access.unknown
    @State private var banner: BannerMessage?
    @State private var path: [String] = []
    @Namespace private var zoom

    enum Access { case unknown, granted, denied }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch access {
                case .unknown:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .denied:
                    EmptyState(systemImage: "person.2.slash",
                               title: Text("Contacts Are Off"),
                               message: Text("Allow access to search and call the people in your address book."),
                               actionTitle: "Allow Access") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                case .granted where contacts.isEmpty:
                    EmptyState(systemImage: "person.2", title: Text("No Contacts"),
                               message: Text("People in your address book with a phone number appear here."))
                case .granted:
                    list
                }
            }
            .background(AriaColor.background)
            .navigationTitle("Contacts")
            .toolbarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { name in
                if let contact = contacts.first(where: { $0.name == name }) {
                    ContactDetailView(contact: contact, onCall: call)
                        .navigationTransition(.zoom(sourceID: name, in: zoom))
                }
            }
            .banner($banner)
            .task { await loadContacts() }
        }
    }

    // MARK: List

    private var filtered: [ContactEntry] {
        guard !searchText.isEmpty else { return contacts }
        let digits = searchText.filter(\.isNumber)
        return contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(searchText)
                || (!digits.isEmpty && contact.phoneNumbers.contains { $0.filter(\.isNumber).contains(digits) })
        }
    }

    private var favoriteContacts: [ContactEntry] {
        contacts.filter { favorites.contains($0) }
    }

    private var list: some View {
        List {
            if searchText.isEmpty, !favoriteContacts.isEmpty {
                Section {
                    favoritesCarousel
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    sectionHeader(Text("Favorites"))
                }
            }
            ForEach(ContactIndex.sections(filtered), id: \.letter) { section in
                Section {
                    ForEach(section.contacts) { contact in
                        // Pushed by tap rather than a NavigationLink, whose
                        // disclosure chevron would sit outside the row card.
                        ContactRow(contact: contact) { number in call(number) }
                            .contentShape(.rect)
                            .onTapGesture { path.append(contact.name) }
                            .accessibilityAction(named: Text("Show contact")) { path.append(contact.name) }
                            .matchedTransitionSource(id: contact.name, in: zoom)
                            .ariaListRow()
                    }
                } header: {
                    sectionHeader(Text(section.letter))
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .ariaListStyle()
        .listSectionIndexVisibility(.visible)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Name or number"))
        .overlay {
            if filtered.isEmpty, !searchText.isEmpty {
                EmptyState(systemImage: "magnifyingglass", title: Text("No Results"),
                           message: Text("No one matches “\(searchText)”."))
            }
        }
    }

    private func sectionHeader(_ text: Text) -> some View {
        text
            .ariaFont(.label)
            .textCase(.uppercase)
            .foregroundStyle(AriaColor.onSurfaceVariant)
            .accessibilityAddTraits(.isHeader)
    }

    private var favoritesCarousel: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Space.m) {
                ForEach(favoriteContacts) { contact in
                    Button { path.append(contact.name) } label: {
                        VStack(spacing: Space.xs) {
                            Avatar(name: contact.name, imageData: contact.thumbnailData,
                                   size: ComponentSize.avatarFavorite)
                            Text(contact.name.split(separator: " ").first.map(String.init) ?? contact.name)
                                .ariaFont(.label)
                                .foregroundStyle(AriaColor.onSurface)
                                .lineLimit(1)
                        }
                        .frame(width: ComponentSize.avatarFavorite + Space.m)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: contact.name, in: zoom)
                    .accessibilityLabel(Text(contact.name))
                    .accessibilityHint(Text("Shows contact"))
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .padding(.vertical, Space.xs)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Actions

    private func call(_ number: String) {
        switch callManager.startOutgoingCall(uri: number) {
        case .placed: break
        case .emergencyHandoff:
            banner = .info(String(localized: "Emergency calls are placed by your phone, not over Aria."))
        case .refused:
            banner = .error(String(localized: "Can't place another call right now."))
        }
    }

    private func loadContacts() async {
        let source = ContactsSources.current
        do {
            let granted = try await source.requestAccess()
            guard granted else {
                access = .denied
                return
            }
            let fetched = try source.fetchContacts()
            contacts = fetched
            access = .granted
            favorites.seed(from: fetched)
            ContactDirectory.shared.update(fetched)
        } catch {
            print("Failed to load contacts: \(error)")
            access = .denied
        }
    }
}

// MARK: - Index

enum ContactIndex {
    struct Section: Equatable {
        let letter: String
        let contacts: [ContactEntry]

        static func == (a: Section, b: Section) -> Bool {
            a.letter == b.letter && a.contacts.map(\.name) == b.contacts.map(\.name)
        }
    }

    /// Contacts grouped by the first letter of their name, A–Z (accents
    /// folded), with everything else under "#" at the end.
    static func sections(_ contacts: [ContactEntry]) -> [Section] {
        var groups: [String: [ContactEntry]] = [:]
        for contact in contacts {
            groups[letter(for: contact.name), default: []].append(contact)
        }
        return groups.keys
            .sorted { ($0 == "#" ? 1 : 0, $0) < ($1 == "#" ? 1 : 0, $1) }
            .map { key in
                Section(letter: key, contacts: groups[key]!.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                })
            }
    }

    static func letter(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        guard let scalar = folded.unicodeScalars.first, ("A"..."Z").contains(Character(scalar)) else { return "#" }
        return folded
    }
}

// MARK: - Favorites

/// Favorites, kept on this iPhone: the Contacts framework does not expose
/// the system's. Stored by name.
@MainActor
final class FavoriteContacts: ObservableObject {
    static let shared = FavoriteContacts()
    private static let key = "favoriteContactNames"

    @Published private(set) var names: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ contact: ContactEntry) -> Bool {
        names.contains(contact.name)
    }

    func toggle(_ contact: ContactEntry) {
        if names.contains(contact.name) { names.remove(contact.name) } else { names.insert(contact.name) }
        defaults.set(Array(names).sorted(), forKey: Self.key)
    }

    /// Adopt favorites a source already marks (fixture data).
    func seed(from contacts: [ContactEntry]) {
        let marked = contacts.filter(\.isFavorite).map(\.name)
        guard !marked.isEmpty, !marked.allSatisfy(names.contains) else { return }
        names.formUnion(marked)
    }
}

// MARK: - Row

struct ContactRow: View {
    let contact: ContactEntry
    let onCall: (String) -> Void
    @ObservedObject private var defaultCountry = DefaultCountry.shared

    var body: some View {
        AriaListRow(
            title: Text(contact.name),
            subtitle: contact.phoneNumbers.first.map { Text(DialFormatter.format($0, country: defaultCountry.country)) }
        ) {
            Avatar(name: contact.name, imageData: contact.thumbnailData)
        } trailing: {
            if let number = contact.phoneNumbers.first {
                Button { onCall(number) } label: {
                    Image(systemName: "phone.fill")
                        .font(.body)
                        .foregroundStyle(AriaColor.answer)
                        .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Call \(contact.name)"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Detail

struct ContactDetailView: View {
    @ObservedObject private var defaultCountry = DefaultCountry.shared
    let contact: ContactEntry
    let onCall: (String) -> Void
    @ObservedObject private var favorites = FavoriteContacts.shared

    var body: some View {
        ScrollView {
            VStack(spacing: Space.sectionGap) {
                VStack(spacing: Space.s) {
                    Avatar(name: contact.name, imageData: contact.thumbnailData, size: ComponentSize.avatarCall)
                    Text(contact.name)
                        .ariaFont(.headline)
                        .foregroundStyle(AriaColor.onSurface)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, Space.l)

                SectionCard(title: Text("Numbers")) {
                    ForEach(Array(contact.phoneNumbers.enumerated()), id: \.offset) { index, number in
                        HStack(spacing: Space.s) {
                            Text(DialFormatter.format(number, country: defaultCountry.country))
                                .ariaFont(.body)
                                .foregroundStyle(AriaColor.onSurface)
                                .textSelection(.enabled)
                            Spacer(minLength: Space.xs)
                            Button { onCall(number) } label: {
                                Image(systemName: "phone.fill")
                                    .foregroundStyle(AriaColor.onPrimary)
                                    .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                                    .glassEffect(.regular.tint(AriaColor.answer).interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Call \(number)"))
                        }
                        .frame(minHeight: ComponentSize.row)
                        if index < contact.phoneNumbers.count - 1 {
                            Divider().overlay(AriaColor.outlineVariant.opacity(0.6))
                        }
                    }
                }

                AriaButton(favorites.contains(contact) ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: favorites.contains(contact) ? "star.slash" : "star",
                           kind: .standard, fullWidth: true) {
                    favorites.toggle(contact)
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .padding(.bottom, Space.xl)
        }
        .background(AriaColor.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}
