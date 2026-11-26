import ActivityKit
import Foundation

/// What the controller needs of ActivityKit, so tests never touch it.
@MainActor
protocol ActivityFacade {
    /// The `hold_wait_id` of every activity ActivityKit still has, including
    /// ones from before the app was killed.
    func existingIds() -> [String]
    func start(_ attributes: HoldWaitAttributes, state: HoldWaitAttributes.ContentState, staleDate: Date)
    func update(id: String, state: HoldWaitAttributes.ContentState, staleDate: Date)
    func end(id: String)
}

extension HoldWait {
    /// Who is being waited on: the business name, else its number as the
    /// app shows numbers.
    var displayName: String {
        if let name = remote.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let number = remote.number?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty {
            return PhoneFormat(country: DefaultCountry.cached).listed(number)
        }
        return ""
    }

    /// What the card and the activity show for it: nil when not shown.
    var shownState: HoldWaitAttributes.ContentState? {
        HoldWaitPresentation.shownState(state).map { .init(state: $0, stateSince: stateSince) }
    }
}

/// Keeps one Live Activity per open Hold for me wait.
@MainActor
final class HoldActivityController {
    private let facade: ActivityFacade
    /// The state last sent for each activity, so an unchanged wait is not
    /// updated again.
    private var sent: [String: HoldWaitAttributes.ContentState] = [:]

    /// How long past the maximum wait an activity may stay before the system
    /// marks it out of date.
    static let staleGraceSecs: TimeInterval = 300
    /// How long "Someone answered" or "Ringing you…" can be true: the PBX
    /// rings 3 rounds of 30 s, plus a margin. A ring that is missed while
    /// the app is away is then shown as out of date, not counted for hours.
    static let ringBudgetSecs: TimeInterval = 3 * 30 + 60

    /// When the activity for `wait` goes out of date.
    static func staleDate(for wait: HoldWait) -> Date {
        switch wait.state {
        case "ringing", "human_detected":
            return wait.stateSince.addingTimeInterval(ringBudgetSecs)
        default:
            return wait.startedAt.addingTimeInterval(TimeInterval(wait.maxWaitSecs) + staleGraceSecs)
        }
    }

    init(facade: ActivityFacade) {
        self.facade = facade
    }

    /// Make the activities match `waits`: start one for each shown wait
    /// (`HoldWaitPresentation`: open and not joined) that has none, update a changed state, and end every other activity,
    /// whether it belongs to an ended wait or to one this app no longer
    /// knows (it was killed while waiting).
    ///
    /// `endUnknown` false keeps activities this controller has not itself
    /// started or updated: right after a launch they may be a live wait's.
    func sync(_ waits: [HoldWait], endUnknown: Bool = true) {
        let open = waits.filter(\.isShown)
        let openIds = Set(open.map(\.holdWaitId))
        let existing = Set(facade.existingIds())

        for id in existing.union(sent.keys) where !openIds.contains(id) {
            if existing.contains(id) && (endUnknown || sent[id] != nil) { facade.end(id: id) }
            sent[id] = nil
        }
        for wait in open {
            guard let state = wait.shownState else { continue }
            let stale = Self.staleDate(for: wait)
            if !existing.contains(wait.holdWaitId) {
                facade.start(
                    HoldWaitAttributes(holdWaitId: wait.holdWaitId, callId: wait.callId, startedAt: wait.startedAt,
                                       remoteName: wait.displayName),
                    state: state, staleDate: stale)
                sent[wait.holdWaitId] = state
            } else if sent[wait.holdWaitId] != state {
                facade.update(id: wait.holdWaitId, state: state, staleDate: stale)
                sent[wait.holdWaitId] = state
            }
        }
    }
}

/// ActivityKit itself. Local updates only (`pushType: nil`).
@MainActor
struct LiveActivityFacade: ActivityFacade {
    func existingIds() -> [String] {
        Activity<HoldWaitAttributes>.activities.map(\.attributes.holdWaitId)
    }

    func start(_ attributes: HoldWaitAttributes, state: HoldWaitAttributes.ContentState, staleDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: nil
        )
    }

    func update(id: String, state: HoldWaitAttributes.ContentState, staleDate: Date) {
        for activity in Activity<HoldWaitAttributes>.activities where activity.attributes.holdWaitId == id {
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        }
    }

    func end(id: String) {
        for activity in Activity<HoldWaitAttributes>.activities where activity.attributes.holdWaitId == id {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
