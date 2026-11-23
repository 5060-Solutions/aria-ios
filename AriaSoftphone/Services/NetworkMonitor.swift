import Foundation
import Network

/// What the app cares about in a network path: whether it is usable, over
/// which interfaces, and with which local addresses. Two snapshots differing
/// in any of these is a network change the core must hear about.
struct NetworkPath: Equatable {
    var isSatisfied: Bool
    /// Interface names in preference order, e.g. `["en0"]`, `["pdp_ip0"]`.
    var interfaces: [String]
    /// Local IP addresses on those interfaces. A new address on the same
    /// interface (DHCP renewal, a different Wi-Fi network on en0, a cellular
    /// re-attach) changes this.
    var addresses: Set<String>

    static let unsatisfied = NetworkPath(isSatisfied: false, interfaces: [], addresses: [])
}

/// How the path changed.
enum NetworkChange: Equatable {
    case becameReachable
    case becameUnreachable
    /// Still reachable, over a different interface (Wi-Fi ↔ cellular).
    case interfaceChanged
    /// Same interfaces, different local address.
    case addressChanged

    /// The change from `old` to `new`, or nil when nothing the app cares
    /// about differs.
    static func between(_ old: NetworkPath, _ new: NetworkPath) -> NetworkChange? {
        guard old != new else { return nil }
        if old.isSatisfied != new.isSatisfied {
            return new.isSatisfied ? .becameReachable : .becameUnreachable
        }
        if old.interfaces != new.interfaces { return .interfaceChanged }
        if old.addresses != new.addresses { return .addressChanged }
        return nil
    }
}

/// The source of path updates. `NWPathMonitor` in the app; a fake in tests.
protocol PathMonitoring: AnyObject {
    var pathUpdateHandler: ((NetworkPath) -> Void)? { get set }
    func start()
    func cancel()
}

/// Watches the network and reports every change to `onChange`: an interface
/// switch, a new local address, or the network coming or going.
///
/// The first path after `start` is the baseline, not a change. Updates that
/// change nothing the app cares about (NWPathMonitor also reports, e.g.,
/// cost or constraint flips) are dropped.
final class NetworkMonitor {
    private let monitor: PathMonitoring
    private let onChange: (NetworkChange, NetworkPath) -> Void
    private let lock = NSLock()
    private var _current: NetworkPath?
    private var started = false

    init(monitor: PathMonitoring, onChange: @escaping (NetworkChange, NetworkPath) -> Void) {
        self.monitor = monitor
        self.onChange = onChange
    }

    /// The last path seen; nil before the first update.
    var current: NetworkPath? {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in self?.handle(path) }
        monitor.start()
    }

    func stop() {
        lock.lock()
        started = false
        _current = nil
        lock.unlock()
        monitor.cancel()
        monitor.pathUpdateHandler = nil
    }

    func handle(_ path: NetworkPath) {
        lock.lock()
        let previous = _current
        _current = path
        lock.unlock()
        guard let previous = previous, let change = NetworkChange.between(previous, path) else { return }
        onChange(change, path)
    }
}

// MARK: - System monitor

/// `NWPathMonitor`, reporting `NetworkPath`s on its own queue.
final class SystemPathMonitor: PathMonitoring {
    var pathUpdateHandler: ((NetworkPath) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.5060.aria.network-monitor")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathUpdateHandler?(Self.snapshot(path))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    static func snapshot(_ path: NWPath) -> NetworkPath {
        let satisfied = path.status == .satisfied
        let names = path.availableInterfaces.map(\.name)
        return NetworkPath(
            isSatisfied: satisfied,
            interfaces: satisfied ? names : [],
            addresses: satisfied ? localAddresses(on: Set(names)) : []
        )
    }

    /// IPv4 and IPv6 addresses (link-local IPv6 excluded) on `interfaces`.
    static func localAddresses(on interfaces: Set<String>) -> Set<String> {
        var result: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            guard interfaces.contains(name) else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text.lowercased().hasPrefix("fe80") { continue }
            result.insert(text)
        }
        return result
    }
}
