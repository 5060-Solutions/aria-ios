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
    /// Who is being waited on: the business name, else its number.
    var displayName: String {
        for candidate in [remote.name, remote.number] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return ""
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

    init(facade: ActivityFacade) {
        self.facade = facade
    }

    /// Make the activities match `waits`: start one for each open wait that
    /// has none, update a changed state, and end every other activity,
    /// whether it belongs to an ended wait or to one this app no longer
    /// knows (it was killed while waiting).
    ///
    /// `endUnknown` false keeps activities this controller has not itself
    /// started or updated: right after a launch they may be a live wait's.
    func sync(_ waits: [HoldWait], endUnknown: Bool = true) {
        let open = waits.filter(\.isOpen)
        let openIds = Set(open.map(\.holdWaitId))
        let existing = Set(facade.existingIds())

        for id in existing.union(sent.keys) where !openIds.contains(id) {
            if existing.contains(id) && (endUnknown || sent[id] != nil) { facade.end(id: id) }
            sent[id] = nil
        }
        for wait in open {
            let state = HoldWaitAttributes.ContentState(
                state: wait.state == "requested" ? "waiting" : wait.state, stateSince: wait.stateSince)
            let stale = wait.startedAt.addingTimeInterval(TimeInterval(wait.maxWaitSecs) + Self.staleGraceSecs)
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
