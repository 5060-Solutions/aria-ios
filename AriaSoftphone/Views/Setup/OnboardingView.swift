import SwiftUI
import AVFoundation
import Contacts
import UserNotifications

/// First run (DESIGN.md §5 Onboarding): the brand, then how to set up, then
/// what Aria will ask permission for. Choosing a setup method shows the
/// primer first, so every system prompt has been explained before it
/// appears; Continue then asks and opens the chosen setup.
struct OnboardingView: View {
    enum Page: Hashable { case welcome, method, permissions }

    enum Method: Equatable { case qr, link, manual }

    @State private var page = Page.welcome
    @State private var method: Method?
    @State private var showQR = FixtureMode.opensScanner
    @State private var showLink = false
    @State private var showManual = false
    @State private var isRequesting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $page) {
            welcome.tag(Page.welcome)
            methods.tag(Page.method)
            permissions.tag(Page.permissions)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            PageDots(pages: [.welcome, .method, .permissions], current: page)
                .padding(.bottom, Space.m)
        }
        .background { OnboardingBackground() }
        .animation(Motion.standard(reduceMotion: reduceMotion), value: page)
        .sheet(isPresented: $showQR) {
            ProvisioningFlowView { credentials in
                AccountSession.shared.applyProvisioning(credentials)
                AccountSession.shared.login()
                showQR = false
            }
        }
        .sheet(isPresented: $showLink) { SetupLinkEntryView() }
        .sheet(isPresented: $showManual) { ManualSetupView() }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: Space.xl) {
            Spacer()
            Image("AriaLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: ComponentSize.avatarCall, height: ComponentSize.avatarCall)
                .clipShape(.rect(cornerRadius: Radius.sheet, style: .continuous))
                .shadow(color: Color.ariaIndigo.opacity(0.35), radius: 24, y: 10)
                .accessibilityHidden(true)
            VStack(spacing: Space.s) {
                Text("Aria")
                    .ariaFont(.display)
                    .foregroundStyle(AriaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Text("Your business phone line, on your iPhone.")
                    .ariaFont(.body)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            AriaButton("Get Started", kind: .prominent, size: .primary, fullWidth: true) {
                page = .method
            }
            .padding(.bottom, Space.xxxl + Space.xl)
        }
        .padding(.horizontal, Space.xxl)
    }

    // MARK: Setup method

    private var methods: some View {
        VStack(spacing: Space.xl) {
            Spacer()
            pageHeader(systemImage: "qrcode.viewfinder", title: "Set up Aria",
                       message: "Your phone system admin gives you a setup code or link. You can also enter your details by hand.")
            Spacer()
            VStack(spacing: Space.s) {
                AriaButton("Scan QR Code", systemImage: "qrcode.viewfinder", kind: .prominent,
                           size: .primary, fullWidth: true) { choose(.qr) }
                AriaButton("Open Setup Link", systemImage: "link", kind: .standard,
                           size: .primary, fullWidth: true) { choose(.link) }
                AriaButton("Enter Manually", systemImage: "keyboard", kind: .standard,
                           size: .primary, fullWidth: true) { choose(.manual) }
            }
            .padding(.bottom, Space.xxxl + Space.xl)
        }
        .padding(.horizontal, Space.xxl)
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(spacing: Space.xl) {
            Spacer(minLength: Space.xl)
            pageHeader(systemImage: "hand.raised.fill", title: "Before you start",
                       message: "Aria will ask for these next. Each one stays on this iPhone.")
            VStack(spacing: Space.s) {
                PermissionRow(systemImage: "mic.fill", title: "Microphone",
                              detail: "So the other person can hear you on calls.")
                PermissionRow(systemImage: "bell.badge.fill", title: "Notifications",
                              detail: "Missed calls and new voicemail.")
                PermissionRow(systemImage: "person.2.fill", title: "Contacts",
                              detail: "Names for numbers, and calling people you know.")
                if method == .qr {
                    PermissionRow(systemImage: "camera.fill", title: "Camera",
                                  detail: "Only to scan your setup code.")
                }
            }
            Spacer(minLength: Space.xl)
            VStack(spacing: Space.s) {
                AriaButton("Continue", kind: .prominent, size: .primary, fullWidth: true,
                           isLoading: isRequesting) {
                    Task { await requestThenSetUp() }
                }
                AriaButton("Not Now", kind: .plain) { openSetup() }
            }
            .padding(.bottom, Space.xxxl)
        }
        .padding(.horizontal, Space.xxl)
    }

    private func pageHeader(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(spacing: Space.m) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(AriaColor.primary)
                .frame(width: ComponentSize.emptyStateIcon, height: ComponentSize.emptyStateIcon)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)
            Text(title)
                .ariaFont(.headline)
                .foregroundStyle(AriaColor.onSurface)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .ariaFont(.body)
                .foregroundStyle(AriaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Actions

    private func choose(_ chosen: Method) {
        method = chosen
        page = .permissions
    }

    private func requestThenSetUp() async {
        isRequesting = true
        await OnboardingPermissions.requestAll()
        isRequesting = false
        openSetup()
    }

    private func openSetup() {
        switch method ?? .qr {
        case .qr: showQR = true
        case .link: showLink = true
        case .manual: showManual = true
        }
    }
}

/// The page indicator, in primary: the system dots are white and vanish
/// on the light background.
private struct PageDots: View {
    let pages: [OnboardingView.Page]
    let current: OnboardingView.Page

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(pages, id: \.self) { page in
                Capsule()
                    .fill(page == current ? AriaColor.primary : AriaColor.outlineVariant)
                    .frame(width: page == current ? Space.l : Space.xs, height: Space.xs)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Page \((pages.firstIndex(of: current) ?? 0) + 1) of \(pages.count)"))
    }
}

/// One permission in the primer.
private struct PermissionRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(AriaColor.primary)
                .frame(width: ComponentSize.avatarList, height: ComponentSize.avatarList)
                .background(AriaColor.primaryContainer.opacity(0.6), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ariaFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(AriaColor.onSurface)
                Text(detail)
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.s)
        .background(AriaColor.surface, in: .rect(cornerRadius: Radius.contentRow, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The system prompts the primer explained, asked in order. Each is a no-op
/// once answered. The camera is asked by the scanner itself.
enum OnboardingPermissions {
    static func requestAll() async {
        _ = await AVAudioApplication.requestRecordPermission()
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
    }
}

/// A soft wash of the brand behind onboarding.
private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            AriaColor.background
            LinearGradient(
                colors: [AriaColor.primaryContainer.opacity(0.55), AriaColor.background.opacity(0)],
                startPoint: .top, endPoint: .center
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
