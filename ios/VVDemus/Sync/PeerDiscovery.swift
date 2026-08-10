import Foundation

/// A peer seen on the network, before any pairing has happened.
struct DiscoveredPeer: Identifiable, Equatable {
    var id: String { peerId }
    let peerId: String
    let name: String
    let isDesktop: Bool
    /// The peer's IPv4 address, from the A record Bonjour resolved.
    ///
    /// Deliberately not the `.local` hostname: that resolves to the IPv6 link-local address
    /// first, and the embedded server binds IPv4 only, so connections to it are refused
    /// outright. See `PeerDiscovery.ipv4Address(of:)`. Discovery re-runs whenever the address
    /// changes, so this staying an address rather than a name costs nothing.
    let host: String
    let port: Int

    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }
}

/// Publishes this device on `_vvdemus._tcp` and watches for the other one.
///
/// `NetService` rather than `NWListener` for the advertising half: Swifter already owns the
/// listening socket on 51825, and `NWListener` insists on opening its own. `NetServiceBrowser`
/// for the other half because it resolves straight to a hostname — `NWBrowser` hands back an
/// endpoint that still needs a connection opened against it before it will say where it is,
/// and a hostname is what the HTTP client actually wants.
@MainActor
final class PeerDiscovery: NSObject, ObservableObject {
    static let shared = PeerDiscovery()

    @Published private(set) var peers: [DiscoveredPeer] = []

    static let serviceType = "_vvdemus._tcp."

    private var service: NetService?
    private var browser: NetServiceBrowser?
    /// Resolution is asynchronous and the service object must outlive the call, so in-flight
    /// ones are held here rather than by the stack frame that started them.
    private var resolving: Set<NetService> = []

    private override init() { super.init() }

    // MARK: - Advertising

    func startAdvertising(port: Int) {
        stopAdvertising()
        let identity = PeerIdentity.shared
        let service = NetService(
            domain: "local.",
            type: Self.serviceType,
            // The visible name, not the id — this is what shows up in another device's list.
            // Bonjour makes it unique itself if two machines share a name.
            name: identity.name,
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "peerId": Data(identity.peerId.utf8),
            "name": Data(identity.name.utf8),
            "desktop": Data((identity.isDesktop ? "1" : "0").utf8),
            "v": Data("1".utf8),
        ]))
        service.publish()
        self.service = service
        PairLog.info("advertising \(identity.name) on \(Self.serviceType) port \(port) (peerId \(identity.peerId.prefix(8)))")
    }

    func stopAdvertising() {
        service?.stop()
        service = nil
    }

    // MARK: - Browsing

    func startBrowsing() {
        guard browser == nil else { return }
        peers = []
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        self.browser = browser
        PairLog.info("browsing for \(Self.serviceType)")
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }
}

extension PeerDiscovery: NetServiceDelegate, NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.insert(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        MainActor.assumeIsolated {
            resolving.remove(service)
            peers.removeAll { $0.name == service.name }
        }
    }

    /// The service's IPv4 address, in dotted form.
    ///
    /// Not the Bonjour hostname, and this is the whole reason pairing failed for a long time:
    /// the embedded server binds IPv4 only (`forceIPv4: true`), but a `.local` name resolves to
    /// both AAAA and A records, and the system tries the IPv6 link-local one first. Nothing is
    /// listening there, so the connection was refused before it began —
    /// `fe80::…%en0.51825 … flags=[R.] … state=SYN_SENT`. Handing the client the A record
    /// directly means it connects to the socket that actually exists.
    private static func ipv4Address(of service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        let candidates = addresses.compactMap { data -> String? in
            data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr>.size else { return nil }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                guard family == sa_family_t(AF_INET) else { return nil }
                var address = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
        }
        // Ranked, not "whichever came first". A device advertises every interface it has, and the
        // first A record is routinely one nothing can reach: a Mac with an unplugged Ethernet
        // port, a USB-tethered phone, or a Thunderbolt bridge self-assigns a 169.254 link-local
        // address and Bonjour advertises it alongside the real one. Taking it produced a peer
        // that resolved perfectly and then would not connect —
        // "discovered … at 169.254.231.149" followed by "Could not connect to the server", over
        // and over, with the routable address sitting in the same record unused.
        return preferredIPv4(from: candidates)
    }

    /// Picks the address most likely to actually accept a connection.
    ///
    /// Separated from the `NetService` parsing so it can be tested without one — the same reason
    /// `castLiveness` and `PlaybackMirror` are values. Lower rank wins. Loopback beats link-local
    /// because two copies of the app on one machine (a simulator beside the Mac app) genuinely are
    /// reachable that way; link-local is last because it is almost never the address anyone means,
    /// and taking it is what produced a peer that resolved perfectly and then refused every
    /// connection.
    nonisolated static func preferredIPv4(from candidates: [String]) -> String? {
        candidates.min { rank(of: $0) < rank(of: $1) }
    }

    nonisolated private static func rank(of address: String) -> Int {
        if address.hasPrefix("169.254.") { return 3 }   // self-assigned, routes nowhere
        if address.hasPrefix("127.") { return 2 }       // same machine only, but real
        return 1
    }

    nonisolated func netServiceDidResolveAddress(_ service: NetService) {
        MainActor.assumeIsolated {
            resolving.remove(service)
            guard let data = service.txtRecordData() else {
                PairLog.error("resolved \(service.name) but it carried no TXT record — ignoring")
                return
            }
            let record = NetService.dictionary(fromTXTRecord: data)
            guard let peerIdData = record["peerId"], let peerId = String(data: peerIdData, encoding: .utf8) else {
                PairLog.error("resolved \(service.name) but its TXT record had no peerId — ignoring")
                return
            }
            let addressCount = service.addresses?.count ?? 0
            guard let host = Self.ipv4Address(of: service) ?? service.hostName else {
                PairLog.error("resolved \(service.name) with \(addressCount) address(es) but no usable host")
                return
            }
            if Self.ipv4Address(of: service) == nil {
                PairLog.error("no IPv4 address for \(service.name) — falling back to hostname \(host), which may resolve to IPv6 first and be refused")
            }
            // Every device running this app advertises, including this one. Seeing yourself in
            // your own pairing list is confusing at best and pairable-with-yourself at worst.
            guard peerId != PeerIdentity.shared.peerId else { return }

            let name = record["name"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
            let isDesktop = record["desktop"].flatMap { String(data: $0, encoding: .utf8) } == "1"
            let peer = DiscoveredPeer(
                peerId: peerId,
                name: name,
                isDesktop: isDesktop,
                host: host,
                port: service.port
            )
            // Only publish a genuine change.
            //
            // Bonjour re-resolves a service repeatedly — once per interface, and again whenever
            // the record is refreshed — and unconditionally rewriting `peers` republished this
            // object every time. Anything observing it rebuilt on that cadence, which meant the
            // pairing controls were being replaced between finger-down and finger-up: the Pair
            // button silently did nothing, on both platforms, while the buttons in the *paired*
            // view (which don't observe discovery) worked fine.
            if peers.first(where: { $0.peerId == peerId }) == peer { return }
            peers.removeAll { $0.peerId == peerId }
            peers.append(peer)
            peers.sort { $0.name < $1.name }
            PairLog.info("discovered \(peer.name) at \(peer.host):\(peer.port) (peerId \(peerId.prefix(8)), desktop=\(isDesktop), \(addressCount) advertised address(es))")
        }
    }

    nonisolated func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated {
            resolving.remove(service)
            PairLog.error("failed to resolve \(service.name): \(errorDict)")
        }
    }
}
