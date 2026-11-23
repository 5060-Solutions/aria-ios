import SwiftUI
import UIKit

/// App-wide notices about calls, shown over whatever screen is up: today,
/// "Call dropped — connection lost" when the core ended a connected call
/// because its gateway instance went away.
struct CallNotices: ViewModifier {
    @ObservedObject private var callManager = CallManager.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = callManager.droppedCallNotice {
                    Banner(message: .error(notice.message)) {
                        callManager.droppedCallNotice = nil
                    }
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.top, Space.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("notice.callDropped")
                    .task(id: notice.id) {
                        UIAccessibility.post(notification: .announcement, argument: notice.message)
                        try? await Task.sleep(for: .seconds(6))
                        if callManager.droppedCallNotice?.id == notice.id {
                            callManager.droppedCallNotice = nil
                        }
                    }
                }
            }
            .animation(.smooth, value: callManager.droppedCallNotice)
    }
}
