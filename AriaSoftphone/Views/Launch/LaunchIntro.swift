import SwiftUI

/// The cold-start intro: the brand mark from the static launch screen picks up
/// a glass shimmer and a soft waveform ripple, then glides into the dialer's
/// header (`matchedGeometryEffect`). At most `LaunchIntro.total` long.
///
/// The launch screen itself stays static (`UILaunchScreen`: the same
/// background colour and mark, light and dark). The intro is an overlay on
/// top of the app, which is already built underneath: nothing waits for it,
/// it takes no touches, and an incoming call removes it at once.
enum LaunchIntro {
    /// The ripple and shimmer, then the glide into the header.
    static var play: TimeInterval { 0.2 * slowMo }
    static var settle: TimeInterval { 0.3 * slowMo }

    /// DEBUG only: `-LaunchIntroSlowMo` plays it six times slower, for review
    /// recordings. Always 1 in Release.
    static var slowMo: Double {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-LaunchIntroSlowMo") ? 6 : 1
        #else
        return 1
        #endif
    }
    /// The whole intro; the spec's ceiling is 600 ms.
    static var total: TimeInterval { play + settle }

    /// The launch image, drawn by the system at its point size
    /// (432 px at 3x).
    static let launchMarkSize: CGFloat = 144
    static let headerMarkSize: CGFloat = 28

    /// Plays once per process (a cold start), never over fixtures unless
    /// asked, and never when a call is already there.
    static var hasPlayed = false
    static let fixtureArgument = "-LaunchIntro"

    static func shouldPlay(
        hasPlayed: Bool, isFixture: Bool, fixtureAsked: Bool, hasCall: Bool
    ) -> Bool {
        if hasPlayed || hasCall { return false }
        return !isFixture || fixtureAsked
    }

    static var fixtureAsked: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(fixtureArgument)
        #else
        return false
        #endif
    }
}

/// Where the intro's mark is: big and centered, or settled in the header.
enum LaunchIntroPhase: Equatable {
    case playing, settled
}

/// What the dialer needs to receive the mark.
struct LaunchIntroContext {
    var namespace: Namespace.ID
    var phase: LaunchIntroPhase
}

private struct LaunchIntroKey: EnvironmentKey {
    static let defaultValue: LaunchIntroContext? = nil
}

extension EnvironmentValues {
    var launchIntro: LaunchIntroContext? {
        get { self[LaunchIntroKey.self] }
        set { self[LaunchIntroKey.self] = newValue }
    }
}

let launchIntroMarkID = "launch-intro-mark"

// MARK: - The header's mark

/// The small mark at the dialer's leading edge: the intro's destination, and
/// a quiet brand anchor afterwards. Decorative.
struct HeaderMark: View {
    @Environment(\.launchIntro) private var intro

    var body: some View {
        ZStack {
            Color.clear
            if let intro {
                if intro.phase == .settled {
                    mark.matchedGeometryEffect(id: launchIntroMarkID, in: intro.namespace)
                }
            } else {
                mark
            }
        }
        .frame(width: LaunchIntro.headerMarkSize, height: LaunchIntro.headerMarkSize)
        .accessibilityHidden(true)
    }

    private var mark: some View {
        Image("AriaLogo")
            .resizable()
            .scaledToFit()
            .frame(width: LaunchIntro.headerMarkSize, height: LaunchIntro.headerMarkSize)
    }
}

// MARK: - The overlay

/// The mark at the launch screen's size and place, with a shimmer swept over
/// its glass and a ripple of rings behind it. Reduce Motion: no shimmer, no
/// ripple, no glide, only the cross-fade.
struct LaunchIntroOverlay: View {
    let namespace: Namespace.ID
    let phase: LaunchIntroPhase
    let reduceMotion: Bool

    @State private var shimmer: CGFloat = -1
    @State private var ripple = false

    var body: some View {
        ZStack {
            if phase == .playing {
                // The launch screen's own colour, so the hand-off is seamless.
                Color("LaunchBackground")
                    .ignoresSafeArea()
                    .transition(.opacity)
                if !reduceMotion { ripples }
                mark
                    .matchedGeometryEffect(id: launchIntroMarkID, in: namespace)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: LaunchIntro.play)) {
                shimmer = 1.4
                ripple = true
            }
        }
    }

    private var mark: some View {
        let size = LaunchIntro.launchMarkSize
        return Image("AriaLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .overlay {
                // The shimmer: a soft diagonal band, clipped to the mark's own
                // silhouette so it only lights the glass.
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.5)
                    .rotationEffect(.degrees(20))
                    .offset(x: proxy.size.width * shimmer - proxy.size.width * 0.5)
                }
                .mask { Image("AriaLogo").resizable().scaledToFit() }
                .blendMode(.plusLighter)
            }
    }

    /// Waveform ripple: rings in the brand accent that widen and thin out.
    private var ripples: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .stroke(AriaColor.tertiary.opacity(ripple ? 0 : 0.45), lineWidth: 2)
                    .frame(width: LaunchIntro.launchMarkSize * 0.88, height: LaunchIntro.launchMarkSize * 0.88)
                    .scaleEffect(ripple ? 1.5 + CGFloat(i) * 0.45 : 1)
            }
        }
    }
}

// MARK: - The modifier

/// Lays the intro over the app. The app underneath is live from the first
/// frame; a call that arrives during the intro ends it without animation.
struct LaunchIntroModifier: ViewModifier {
    let hasCall: Bool

    @Namespace private var namespace
    @State private var phase: LaunchIntroPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(hasCall: Bool) {
        self.hasCall = hasCall
        let play = LaunchIntro.shouldPlay(
            hasPlayed: LaunchIntro.hasPlayed,
            isFixture: FixtureMode.isActive,
            fixtureAsked: LaunchIntro.fixtureAsked,
            hasCall: hasCall
        )
        LaunchIntro.hasPlayed = true
        _phase = State(initialValue: play ? .playing : .settled)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.launchIntro, LaunchIntroContext(namespace: namespace, phase: phase))
            .overlay {
                LaunchIntroOverlay(namespace: namespace, phase: phase, reduceMotion: reduceMotion)
            }
            .task {
                guard phase == .playing else { return }
                try? await Task.sleep(for: .seconds(LaunchIntro.play))
                guard phase == .playing else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: LaunchIntro.settle) : .smooth(duration: LaunchIntro.settle)) {
                    phase = .settled
                }
            }
            .onChange(of: hasCall) { _, nowHasCall in
                guard nowHasCall, phase == .playing else { return }
                // A call never waits for the intro.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { phase = .settled }
            }
    }
}

extension View {
    func launchIntro(hasCall: Bool) -> some View {
        modifier(LaunchIntroModifier(hasCall: hasCall))
    }
}
