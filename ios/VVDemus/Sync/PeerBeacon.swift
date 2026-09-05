import CoreBluetooth
import CryptoKit
import Foundation

/// Bluetooth as the address book of last resort.
///
/// Shaped after `PeerDiscovery` deliberately — a singleton that advertises one half of itself and
/// looks for the other — because it does the same job for the same reason, one layer down. Where
/// Bonjour asks the network who is around, this asks the room, and the room does not have subnets.
///
/// It carries an address and stops. Nothing here touches the library, playback or the session;
/// the answer goes straight into `PeerClient.resolveBase`, which then uses the ordinary HTTP link.
///
/// **What this cannot do.** A backgrounded iOS app's service UUIDs move into Apple's proprietary
/// overflow area, which only another iOS device can read — so a Mac scanning for a phone finds it
/// while the phone's app is in front, and not reliably otherwise. That is the right way round for
/// the case this exists to fix: you open the app on the phone, and the Mac can then find it. The
/// Mac's own advertisement has no such limit, macOS not suspending apps the way iOS does.
@MainActor
final class PeerBeacon: NSObject, ObservableObject {
    static let shared = PeerBeacon()

    static let serviceUUID = CBUUID(string: "6A4E5C1B-9F27-4D83-B0A6-2E7C51D9F408")
    static let addressCharacteristicUUID = CBUUID(string: "6A4E5C1C-9F27-4D83-B0A6-2E7C51D9F408")

    /// Long enough for a scan, a connect and a read; short enough that a peer which simply is not
    /// there does not hold up the sync round that asked.
    private static let resolveTimeout: TimeInterval = 6

    private var peripheralManager: CBPeripheralManager?
    private var centralManager: CBCentralManager?

    /// Sealed ahead of the read rather than on demand.
    ///
    /// This is also why the characteristic is built with a static `value:`. Given one,
    /// CoreBluetooth answers reads out of its own cache and never calls the delegate — which
    /// matters because that delegate callback is synchronous and must respond before it returns,
    /// leaving nowhere to hop to the main actor for the key. Rebuilding the service whenever the
    /// address changes is the price, and it is a cheaper price than the alternative.
    private var sealedPayload: Data?
    private var advertisedPort: Int?
    private var advertisedHost: String?

    /// Retained explicitly. `CBCentralManager` holds a discovered peripheral weakly, so one left
    /// only in a local goes away mid-connect and no delegate method ever fires again — the single
    /// most common way this framework fails silently. `PeerDiscovery.resolving` exists for the
    /// same reason one layer up.
    private var connecting: [UUID: CBPeripheral] = [:]

    private var pending: CheckedContinuation<PeerBeaconPayload?, Never>?
    private var expectedPeer: PairedPeer?
    private var beaconKey: SymmetricKey?
    private var timeoutTask: Task<Void, Never>?
    private var wantsScan = false
    private var wantsAdvertise = false

    private override init() { super.init() }

    // MARK: - Advertising

    /// Publishes this device's address for the paired peer to read.
    ///
    /// Does nothing at all when there is no paired peer — which is what keeps an unpaired install
    /// from ever seeing a Bluetooth permission prompt. The managers are allocated lazily below,
    /// and allocating one is what triggers the prompt.
    func startAdvertising(port: Int) {
        advertisedPort = port
        wantsAdvertise = true
        refreshPayload()
        beginAdvertising()
    }

    func stopAdvertising() {
        wantsAdvertise = false
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        sealedPayload = nil
        advertisedHost = nil
    }

    /// Re-seals if this device's address has moved since it last advertised.
    ///
    /// Called from `PeerLink`'s existing sync round rather than on a timer of its own: a device
    /// whose address changed has nothing useful to say until it says the new one, and the sync
    /// round is already the heartbeat that notices everything else about the link.
    func refreshAdvertisedAddress() {
        guard wantsAdvertise else { return }
        let previous = advertisedHost
        refreshPayload()
        // `peripheralManager == nil` is not redundant with the address having changed: a device
        // that launched unpaired has no manager, and pairing does not change its address. Without
        // it, a pairing made in this session would not be advertised until the app was relaunched
        // — which is exactly the session in which the two devices most need to find each other.
        guard advertisedHost != previous || peripheralManager == nil else { return }
        guard sealedPayload != nil else { return }
        PairLog.info("beacon: address is \(advertisedHost ?? "—") — advertising")
        beginAdvertising()
    }

    private func refreshPayload() {
        // Not `LocalControlServer.localAddress`: that is captured once when the server starts
        // and only ever looks at en0, so it cannot notice this device moving network — which is
        // the one event the beacon exists to survive — and is empty outright on a Mac using
        // Ethernet. Ranked with the same rule Bonjour's addresses go through.
        let live = LocalControlServer.currentIPv4Addresses().values.filter(PeerDiscovery.isWorthRemembering)
        guard let peer = PairedPeerStore.shared.peer,
              let port = advertisedPort,
              let host = PeerDiscovery.preferredIPv4(from: Array(live)),
              let key = try? PeerIdentity.shared.sharedSecret(
                  with: peer.publicKey,
                  peerId: peer.peerId,
                  info: PeerBeaconPayload.keyInfo
              )
        else {
            sealedPayload = nil
            advertisedHost = nil
            return
        }
        let payload = PeerBeaconPayload(
            peerId: PeerIdentity.shared.peerId,
            host: host,
            port: port,
            sentAt: Date()
        )
        sealedPayload = try? payload.sealed(using: key)
        advertisedHost = sealedPayload == nil ? nil : host
    }

    private func beginAdvertising() {
        guard wantsAdvertise, let payload = sealedPayload else { return }
        guard let manager = peripheralManager else {
            // First moment there is anything to say. Allocating the manager is what raises the
            // Bluetooth permission prompt, so it waits until a pairing exists rather than asking
            // every install on first launch for a radio it may never use. The rest of this runs
            // again from `peripheralManagerDidUpdateState` once the radio reports in.
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
            return
        }
        guard manager.state == .poweredOn else { return }
        // Torn down first: `add(service:)` errors on a UUID already published, so a re-advertise
        // after the address moved would otherwise keep serving the old one forever.
        manager.stopAdvertising()
        manager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: Self.addressCharacteristicUUID,
            properties: [.read],
            value: payload,
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        manager.add(service)
        // The service UUID and nothing else. The local name would carry the device's name in the
        // clear to every scanner in range, and the peer does not need it — it knows who it is
        // looking for, and the sealed payload proves it.
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
        PairLog.info("beacon: advertising \(advertisedHost ?? "—"):\(advertisedPort ?? 0)")
    }

    // MARK: - Listening

    /// Asks the room where `peer` is. `nil` if nothing answered in time.
    ///
    /// One at a time: a second caller while a scan is in flight gets `nil` rather than a second
    /// radio session, which matters because `resolveBase` can be entered from the sync timer and
    /// a playback poll at once.
    func resolveAddress(for peer: PairedPeer) async -> (host: String, port: Int)? {
        guard pending == nil else { return nil }
        guard let key = try? PeerIdentity.shared.sharedSecret(
            with: peer.publicKey,
            peerId: peer.peerId,
            info: PeerBeaconPayload.keyInfo
        ) else { return nil }
        // Answered before the timeout rather than through it. `centralManagerDidUpdateState`
        // reports an unusable radio only when the state *changes*, so a manager that settled on
        // .poweredOff long ago says nothing more — and every resolve then paid the full six
        // seconds to learn what was already known. Bluetooth being off is an ordinary state of
        // this world, not a rare one.
        if let state = centralManager?.state, ![.poweredOn, .unknown, .resetting].contains(state) {
            PairLog.info("beacon: Bluetooth is unavailable (state \(state.rawValue)) — not scanning")
            return nil
        }
        expectedPeer = peer
        beaconKey = key
        wantsScan = true
        PairLog.info("beacon: looking for \(peer.name) over Bluetooth")
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else {
            beginScan()
        }
        let payload = await withCheckedContinuation { (continuation: CheckedContinuation<PeerBeaconPayload?, Never>) in
            pending = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.resolveTimeout * 1_000_000_000))
                self?.finish(nil)
            }
        }
        return payload.map { ($0.host, $0.port) }
    }

    private func beginScan() {
        guard wantsScan, let manager = centralManager, manager.state == .poweredOn else { return }
        // Always with an explicit service UUID. A nil filter is not allowed to run in the
        // background at all, and returns every device in range in the foreground.
        manager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    /// Resumes the waiting caller exactly once and puts the radio down.
    private func finish(_ payload: PeerBeaconPayload?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        wantsScan = false
        centralManager?.stopScan()
        for peripheral in connecting.values {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connecting.removeAll()
        expectedPeer = nil
        beaconKey = nil
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: payload)
    }

    /// Drops a peripheral that turned out not to be the peer, without ending the scan — there may
    /// be another VVDemus device in range, and the one that answers is the one that matters.
    private func giveUp(on peripheral: CBPeripheral) {
        centralManager?.cancelPeripheralConnection(peripheral)
        connecting.removeValue(forKey: peripheral.identifier)
    }
}

// MARK: - Central

extension PeerBeacon: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                beginScan()
            case .poweredOff, .unauthorized, .unsupported:
                // Not an error worth surfacing. Bluetooth off is an ordinary state of the world,
                // and the caller has Bonjour and a cached address either side of this.
                PairLog.info("beacon: Bluetooth unavailable for scanning (state \(central.state.rawValue))")
                finish(nil)
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            guard connecting[peripheral.identifier] == nil else { return }
            peripheral.delegate = self
            connecting[peripheral.identifier] = peripheral
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            _ = connecting.removeValue(forKey: peripheral.identifier)
        }
    }
}

// MARK: - Peripheral being read

extension PeerBeacon: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                giveUp(on: peripheral)
                return
            }
            peripheral.discoverCharacteristics([Self.addressCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let characteristic = service.characteristics?
                .first(where: { $0.uuid == Self.addressCharacteristicUUID }) else {
                giveUp(on: peripheral)
                return
            }
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            // `readValue(for:)` has no completion handler, so this is the only place the answer
            // can arrive.
            guard let data = characteristic.value,
                  let key = beaconKey,
                  let peer = expectedPeer,
                  let payload = PeerBeaconPayload.open(data, using: key, expecting: peer.peerId)
            else {
                giveUp(on: peripheral)
                return
            }
            PairLog.info("beacon: \(peer.name) answered — it is at \(payload.host):\(payload.port)")
            finish(payload)
        }
    }
}

// MARK: - Advertising this device

extension PeerBeacon: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            if peripheral.state == .poweredOn {
                beginAdvertising()
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                PairLog.error("beacon: couldn't publish the address service — \(error.localizedDescription)")
            }
        }
    }
}
