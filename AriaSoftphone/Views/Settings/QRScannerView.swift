import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Provisioning URI Parser

struct ProvisioningCredentials {
    let server: String
    let port: Int
    let username: String
    let password: String
    let displayName: String
    let transport: String
    let voicemail: String
    let apiUrl: String
    let tenantDomain: String
}

func parseProvisioningURI(_ urlString: String) -> ProvisioningCredentials? {
    guard let components = URLComponents(string: urlString),
          components.scheme == "aria",
          components.host == "provision" else {
        return nil
    }

    let params = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }
    )

    guard let server = params["server"],
          let user = params["user"],
          let passB64 = params["pass"] else {
        return nil
    }

    // Base64-decode the password
    guard let passData = Data(base64Encoded: passB64),
          let password = String(data: passData, encoding: .utf8) else {
        return nil
    }

    let port = Int(params["port"] ?? "5060") ?? 5060
    let displayName = params["name"] ?? user
    // Normalised; an unrecognised value is refused below rather than falling
    // through to the weakest option.
    let transport = (params["transport"] ?? "udp").lowercased()
    let voicemail = params["vm"] ?? ""
    let apiUrl = params["api"] ?? ""
    let tenantDomain = params["tenant"] ?? ""

    return ProvisioningCredentials(
        server: server,
        port: port,
        username: user,
        password: password,
        displayName: displayName,
        transport: transport,
        voicemail: voicemail,
        apiUrl: apiUrl,
        tenantDomain: tenantDomain
    )
}

// MARK: - Provisioning Destination Validation

/// Validates that a scanned provisioning payload points at a safe destination
/// before any credentials are stored or sent.
///
/// The extension password is POSTed to `apiUrl` during login and SIP
/// registration is directed at `server`, so a hostile QR code could otherwise
/// redirect credentials to an attacker-controlled host. We require:
/// - `apiUrl` to be a well-formed `https://` URL with a non-empty, valid host, and
/// - `server` to be a non-empty, valid host.
///
/// Cleartext (`http://`) or malformed destinations are rejected.
/// The transports this client implements. Anything else is a provisioning
/// error, not a reason to fall back.
let allowedTransports: Set<String> = ["udp", "tcp", "tls"]

/// Whether a provisioned SIP transport is one we support.
///
/// This was the one provisioning field taken verbatim: an unrecognised value
/// fell through to "udp", so a QR could quietly downgrade signalling to
/// cleartext.
func isValidTransport(_ transport: String) -> Bool {
    allowedTransports.contains(transport.lowercased())
}

func isValidProvisioningDestination(apiUrl: String, server: String) -> Bool {
    // API endpoint must be an HTTPS URL with a valid host.
    guard let components = URLComponents(string: apiUrl),
          components.scheme?.lowercased() == "https",
          let apiHost = components.host,
          isValidHost(apiHost) else {
        return false
    }

    // SIP server (used as the registration/SIP host) must be a valid bare host.
    guard isValidHost(server) else {
        return false
    }

    return true
}

/// Returns true if `host` is a plausible, non-empty hostname or IP literal:
/// contains no whitespace, path, or scheme separators, only host-legal
/// characters, and at least one alphanumeric.
private func isValidHost(_ host: String) -> Bool {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == host else { return false }

    // Allowed: hostnames (letters, digits, dot, hyphen) and IPv6 literals (colon).
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        return false
    }

    // Must contain at least one alphanumeric character.
    guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
        return false
    }

    return true
}

// MARK: - QR Scanner View

struct QRScannerView: View {
    let onScanned: (ProvisioningCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraPermission: CameraPermission = .unknown
    @State private var errorMessage: String?
    @State private var scannedCode: String?

    enum CameraPermission {
        case unknown, granted, denied
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch cameraPermission {
                case .unknown:
                    ProgressView("Requesting camera access...")
                        .onAppear { checkCameraPermission() }

                case .denied:
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Camera Access Required")
                            .font(.headline)
                        Text("Open Settings and enable Camera access for Aria to scan QR codes.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                case .granted:
                    CameraPreviewView(onCodeScanned: handleScannedCode)
                        .ignoresSafeArea()

                    // Targeting reticle overlay
                    VStack {
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.8), lineWidth: 3)
                                .frame(width: 250, height: 250)

                            // Corner accents
                            ReticleCorners()
                                .stroke(Color.accentColor, lineWidth: 4)
                                .frame(width: 250, height: 250)
                        }
                        Spacer()
                        Text("Point camera at provisioning QR code")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 40)
                    }
                }

                if let error = errorMessage {
                    VStack {
                        Spacer()
                        Text(error)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                            .padding()
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermission = .granted
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraPermission = granted ? .granted : .denied
                }
            }
        default:
            cameraPermission = .denied
        }
    }

    private func handleScannedCode(_ code: String) {
        // Prevent double-processing
        guard scannedCode == nil else { return }
        scannedCode = code

        guard let credentials = parseProvisioningURI(code) else {
            rejectScan("Invalid QR code. Expected an Aria provisioning code.")
            return
        }

        // Do not store or send credentials to an untrusted or cleartext host.
        guard isValidProvisioningDestination(
            apiUrl: credentials.apiUrl,
            server: credentials.server
        ) else {
            rejectScan("This provisioning code points to an insecure or invalid server and was rejected. The API endpoint must use HTTPS.")
            return
        }

        guard isValidTransport(credentials.transport) else {
            rejectScan("This provisioning code requests an unsupported SIP transport and was rejected.")
            return
        }

        // Haptic feedback on success
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        onScanned(credentials)
    }

    /// Show an error, buzz, and allow re-scanning after a brief delay.
    private func rejectScan(_ message: String) {
        errorMessage = message
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            scannedCode = nil
            errorMessage = nil
        }
    }
}

// MARK: - Reticle Corner Shape

struct ReticleCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerLength: CGFloat = 30
        var path = Path()

        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerLength))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + cornerLength, y: rect.minY))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - cornerLength, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerLength))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerLength, y: rect.maxY))

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + cornerLength, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerLength))

        return path
    }
}

// MARK: - AVFoundation Camera Preview (UIViewRepresentable)

struct CameraPreviewView: UIViewRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black

        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return view
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.session?.stopRunning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var session: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?
        let onCodeScanned: (String) -> Void
        private var hasScanned = false

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasScanned,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else {
                return
            }
            hasScanned = true
            onCodeScanned(value)

            // Allow re-scanning after a delay (in case of error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.hasScanned = false
            }
        }
    }
}
