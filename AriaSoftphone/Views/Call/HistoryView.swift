import SwiftUI

/// Recent calls (DESIGN.md §5 History): All / Missed, grouped by day, with
/// call-back and delete swipes and an info button that zooms into the call.
struct HistoryView: View {
    @EnvironmentObject var callManager: CallManager
    @ObservedObject private var history = CallHistoryStore.shared
    @State private var filter = HistoryFilter.all
    @State private var showClearConfirmation = false
    @State private var path: [UUID] = []
    @State private var banner: BannerMessage?
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            let sections = HistoryGrouping.sections(filter.apply(history.records))
            Group {
                if sections.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.records) { record in
                                    row(record)
                                }
                            } header: {
                                Text(section.title)
                                    .ariaFont(.label)
                                    .textCase(.uppercase)
                                    .foregroundStyle(AriaColor.onSurfaceVariant)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .ariaListStyle()
                }
            }
            .background(AriaColor.background)
            .navigationTitle("History")
            .safeAreaBar(edge: .top) {
                Picker("Show", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Space.screenMargin)
                .padding(.bottom, Space.xs)
            }
            .toolbar {
                if !history.records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Clear History", systemImage: "trash", role: .destructive) {
                                showClearConfirmation = true
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                    }
                }
            }
            .confirmationDialog("Clear all call history?", isPresented: $showClearConfirmation,
                                titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { history.clear() }
            }
            .navigationDestination(for: UUID.self) { id in
                if let record = history.records.first(where: { $0.id == id }) {
                    CallDetailView(record: record) { call(record) }
                        .navigationTransition(.zoom(sourceID: id, in: zoom))
                }
            }
            .banner($banner)
            .onAppear { LocalNotifications.clearMissedCalls() }
        }
    }

    private func row(_ record: CallRecord) -> some View {
        CallHistoryRow(record: record, onCall: { call(record) }, onInfo: { path.append(record.id) })
            .matchedTransitionSource(id: record.id, in: zoom)
            .ariaListRow()
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { call(record) } label: {
                    Label("Call Back", systemImage: "phone.fill")
                }
                .tint(AriaColor.answer)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { history.remove(id: record.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch filter {
        case .all:
            EmptyState(systemImage: "clock", title: Text("No Recent Calls"),
                       message: Text("Calls you make and receive appear here."))
        case .missed:
            EmptyState(systemImage: "phone.badge.checkmark", title: Text("No Missed Calls"),
                       message: Text("You're all caught up."))
        }
    }

    private func call(_ record: CallRecord) {
        switch callManager.startOutgoingCall(uri: record.remoteUri) {
        case .placed: break
        case .emergencyHandoff:
            banner = .info(String(localized: "Emergency calls are placed by your phone, not over Aria."))
        case .refused:
            banner = .error(String(localized: "Can't place another call right now."))
        }
    }
}

extension CallHistoryStore {
    /// Remove one record (a swipe-to-delete).
    func remove(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        remove(atOffsets: IndexSet(integer: index))
    }
}

// MARK: - Filter and grouping

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, missed

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .missed: return "Missed"
        }
    }

    func apply(_ records: [CallRecord]) -> [CallRecord] {
        switch self {
        case .all: return records
        case .missed: return records.filter(\.isMissed)
        }
    }
}

enum HistoryGrouping {
    struct Section: Identifiable, Equatable {
        var id: Date { day }
        let day: Date
        let title: String
        let records: [CallRecord]
    }

    /// Records (newest first) grouped by calendar day: "Today",
    /// "Yesterday", the weekday within the last week, then the date.
    static func sections(_ records: [CallRecord], now: Date = Date(),
                         calendar: Calendar = .current) -> [Section] {
        var order: [Date] = []
        var byDay: [Date: [CallRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.startedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(record)
        }
        return order.map { day in
            Section(day: day, title: title(for: day, now: now, calendar: calendar), records: byDay[day] ?? [])
        }
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let today = calendar.startOfDay(for: now)
        if let days = calendar.dateComponents([.day], from: day, to: today).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}

// MARK: - Row

struct CallHistoryRow: View {
    let record: CallRecord
    let onCall: () -> Void
    let onInfo: () -> Void

    var body: some View {
        AriaListRow(
            title: Text(record.remoteName.flatMap { $0.isEmpty ? nil : $0 } ?? DialFormatter.format(record.remoteUri)),
            subtitle: subtitle,
            titleColor: record.isMissed ? AriaColor.error : AriaColor.onSurface
        ) {
            Avatar(name: record.remoteName ?? "")
        } trailing: {
            HStack(spacing: Space.xxs) {
                Text(record.startedAt, format: .dateTime.hour().minute())
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .monospacedDigit()
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(AriaColor.primary)
                        .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Details for \(record.displayName)"))
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onCall)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Calls \(record.displayName)"))
        .accessibilityAction(named: Text("Details"), onInfo)
    }

    private var subtitle: Text {
        Text("\(Image(systemName: record.directionSymbol)) \(record.summary)")
            .foregroundStyle(record.isMissed ? AriaColor.error : AriaColor.onSurfaceVariant)
    }
}

extension CallRecord {
    var directionSymbol: String {
        switch direction {
        case .inbound:
            return outcome == .answered || outcome == .transferred || outcome == .answeredElsewhere
                ? "phone.arrow.down.left" : "phone.down"
        case .outbound:
            return "phone.arrow.up.right"
        }
    }

    /// "Outgoing · 12:34", "Missed", "Declined".
    var summary: String {
        let length = CallClock.format(duration)
        switch outcome {
        case .answered:
            let label = direction == .inbound ? String(localized: "Incoming") : String(localized: "Outgoing")
            return "\(label) · \(length)"
        case .transferred: return String(localized: "Transferred") + " · \(length)"
        case .answeredElsewhere: return String(localized: "Answered elsewhere")
        case .missed: return String(localized: "Missed")
        case .rejected: return String(localized: "Declined")
        case .cancelled: return String(localized: "Cancelled")
        case .failed: return direction == .inbound ? String(localized: "Missed") : String(localized: "Failed")
        }
    }
}

// MARK: - Detail

/// One call: who, when, how it went, and Call back.
struct CallDetailView: View {
    let record: CallRecord
    let onCall: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Space.sectionGap) {
                VStack(spacing: Space.s) {
                    Avatar(name: record.remoteName ?? "", size: ComponentSize.avatarCall)
                    Text(record.displayName)
                        .ariaFont(.headline)
                        .foregroundStyle(AriaColor.onSurface)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if record.remoteName != nil {
                        Text(DialFormatter.format(record.remoteUri))
                            .ariaFont(.bodySmall)
                            .foregroundStyle(AriaColor.onSurfaceVariant)
                    }
                }
                .padding(.top, Space.l)

                AriaButton("Call", systemImage: "phone.fill", kind: .prominent, size: .primary,
                           fullWidth: true, action: onCall)

                SectionCard(title: Text("Call")) {
                    SectionRow(title: Text("Date"), systemImage: "calendar") {
                        Text(record.startedAt, format: .dateTime.month().day().year().hour().minute())
                    }
                    SectionRow(title: Text("Type"), systemImage: record.directionSymbol) {
                        Text(record.direction == .inbound ? "Incoming" : "Outgoing")
                    }
                    SectionRow(title: Text("Result"), systemImage: "info.circle",
                               showsDivider: record.duration > 0) {
                        Text(record.summary.components(separatedBy: " · ").first ?? record.summary)
                            .foregroundStyle(record.isMissed ? AriaColor.error : AriaColor.onSurfaceVariant)
                    }
                    if record.duration > 0 {
                        SectionRow(title: Text("Duration"), systemImage: "timer", showsDivider: false) {
                            Text(CallClock.format(record.duration)).monospacedDigit()
                        }
                    }
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .padding(.bottom, Space.xl)
        }
        .background(AriaColor.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}
