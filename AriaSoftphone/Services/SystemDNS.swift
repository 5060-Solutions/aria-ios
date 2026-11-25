import Foundation

/// The DNS servers the system resolver uses now, for the core's SRV lookups.
///
/// iOS has no usable `/etc/resolv.conf` for a Rust resolver, so the core is
/// told: libresolv's `res_ninit` / `res_getservers` (in SystemDNSC.c, as
/// Swift cannot import them) report the servers of the active network.
/// Link-local IPv6 servers keep their scope ("fe80::1%en0"). Encrypted DNS
/// profiles are not covered: the servers reported are the network's.
enum SystemDNS {
    static func servers() -> [String] {
        var out: [String] = []
        for i in 0..<8 {
            var buf = [CChar](repeating: 0, count: 64)
            guard aria_system_dns_server(Int32(i), &buf, UInt(buf.count)) == 1 else { break }
            out.append(String(cString: buf))
        }
        return out
    }

    static func normalized(_ servers: [String]) -> [String] { servers.filter { !$0.isEmpty } }
}
