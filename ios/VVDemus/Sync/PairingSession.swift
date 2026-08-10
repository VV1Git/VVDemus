import CryptoKit
import Foundation

/// The six digits shown on screen, and the proof built from them.
///
/// The code is never sent. It is the key to an HMAC over the public keys being exchanged, so a
/// device that cannot see the other's screen cannot produce a proof that verifies — which is
/// what stops anything else on the WiFi from pairing itself in, and what stops a man in the
/// middle from swapping its own key into the exchange.
enum PairingProof {
    static let context = "vvdemus-pair-v1"

    static func make(code: String, publicKey: Data, peerId: String, responding: Bool) -> String {
        let key = SymmetricKey(data: Data(code.utf8))
        var message = Data("\(context)\(responding ? "-response" : "-request")".utf8)
        message.append(publicKey)
        message.append(Data(peerId.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).base64EncodedString()
    }

    /// Constant-time comparison, via CryptoKit's own verifier rather than `==` on the strings.
    static func verify(
        _ candidate: String,
        code: String,
        publicKey: Data,
        peerId: String,
        responding: Bool
    ) -> Bool {
        guard let provided = Data(base64Encoded: candidate) else { return false }
        let key = SymmetricKey(data: Data(code.utf8))
        var message = Data("\(context)\(responding ? "-response" : "-request")".utf8)
        message.append(publicKey)
        message.append(Data(peerId.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(provided, authenticating: message, using: key)
    }
}

/// This device's side of pairing: the code it is currently displaying, and how many wrong
/// guesses it has taken.
@MainActor
final class PairingSession: ObservableObject {
    static let shared = PairingSession()

    /// Six digits, regenerated when it expires or after too many failures.
    @Published private(set) var code: String = ""
    @Published private(set) var expiresAt: Date = .distantPast

    /// Short enough that a code left on screen doesn't stay usable all evening, long enough to
    /// walk between two rooms.
    static let lifetime: TimeInterval = 180
    /// Six digits is a million guesses, but an attacker on the LAN can try quickly — so the
    /// code is retired well before brute force is interesting.
    static let maximumAttempts = 3

    private var failedAttempts = 0
    private var tick: Timer?

    /// Seconds until the shown code stops being accepted. Published so the pairing screen can
    /// count down rather than displaying a number whose validity is invisible.
    @Published private(set) var secondsRemaining: Int = Int(PairingSession.lifetime)

    private init() { rotate() }

    /// The code as it should be treated by a verifier: expired is the same as absent.
    var activeCode: String? {
        guard Date() < expiresAt, !code.isEmpty else { return nil }
        return code
    }

    func rotate() {
        code = Self.pinnedCode ?? String(format: "%06d", Int.random(in: 0..<1_000_000))
        expiresAt = Date().addingTimeInterval(Self.lifetime)
        secondsRemaining = Int(Self.lifetime)
        failedAttempts = 0
    }

    /// A fixed code, for driving the real pairing exchange from a test.
    ///
    /// Pairing is the one part of this feature that cannot be exercised from outside the app: the
    /// six digits exist only in memory, are never persisted and are deliberately never logged —
    /// they are the secret. So an end-to-end check of the handshake (the HMAC proof, the key
    /// exchange, the derived bearer token) had no way in, and the whole peer link could only be
    /// tested from the far side of a pairing someone had done by hand.
    ///
    /// `#if DEBUG` and an environment variable, so it cannot exist in a shipping build and cannot
    /// be reached by anything on the network — only by whoever launched the process. The same
    /// shape as `BackgroundTaskVending`: a seam that exists because the alternative is leaving a
    /// security-critical path untested.
    private static var pinnedCode: String? {
        #if DEBUG
        guard let pinned = ProcessInfo.processInfo.environment["VVDEMUS_PAIRING_CODE"],
              pinned.count == 6, pinned.allSatisfy(\.isNumber) else { return nil }
        return pinned
        #else
        return nil
        #endif
    }

    /// Keeps the number on screen and the number the verifier accepts in step.
    ///
    /// They used to diverge, and it made pairing look completely broken: the code was rotated
    /// once when the screen appeared and then left alone, so three minutes later the device was
    /// still displaying digits it would itself reject — with nothing on screen saying so. The
    /// other device typed exactly what it could see and was told the code didn't match.
    func beginDisplaying() {
        if Date() >= expiresAt { rotate() }
        guard tick == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let remaining = self.expiresAt.timeIntervalSinceNow
                if remaining <= 0 {
                    // Rotated rather than blanked: a pairing screen someone walked away from
                    // and came back to should show a usable code, not a dead one.
                    self.rotate()
                } else {
                    self.secondsRemaining = Int(remaining.rounded(.up))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    func stopDisplaying() {
        tick?.invalidate()
        tick = nil
    }

    /// Called when an incoming pairing attempt fails its proof. Rotating after a few wrong
    /// guesses is what keeps the six digits honest.
    func recordFailure() {
        failedAttempts += 1
        if failedAttempts >= Self.maximumAttempts { rotate() }
    }

    func recordSuccess() {
        failedAttempts = 0
        // A code that has been used is spent — leaving it live would let a second device pair
        // with digits it happened to overhear.
        rotate()
    }

}
