import XCTest
@testable import VVDemus

/// The listening log across three devices, where a single "newest play" date loses plays.
///
/// Driven through a small model of the round `PeerClient.sync` and `/api/sync` run between them —
/// push what the other side last said it lacked, merge, answer with what the asker says it lacks
/// — using the real `EventMarks.select` and `EventMarks.advance` on both ends. No stores, no
/// network: the rules are the whole of it, and three devices in an awkward order are a list.
final class EventMarksTests: XCTestCase {
    private struct Device {
        let id: String
        var log: [PlayEvent] = []
        /// How far each *other* device's plays are held without a gap.
        var marks: EventMarks.Marks = [:]
        /// What each peer last said it held — what pushes to it are chosen after.
        var confirmed: [String: EventMarks.Marks] = [:]

        init(_ id: String) { self.id = id }

        /// As `ListeningStatsStore.eventMarks`: this device's own entry is its newest play.
        var currentMarks: EventMarks.Marks {
            var result = marks
            result[id] = log.filter { $0.origin == id }.map(\.playedAt).max().map(EventMarks.second)
            return result
        }

        mutating func play(_ videoId: String, at seconds: TimeInterval) {
            log.append(PlayEvent(
                track: PeerFixtures.track(videoId),
                playedAt: Date(timeIntervalSince1970: seconds),
                secondsPlayed: 30,
                origin: id
            ))
        }

        mutating func receive(_ events: [PlayEvent], senderMarks: EventMarks.Marks, base: EventMarks.Marks?, from sender: String) {
            var seen = Set(log.map { ListeningStatsStore.dedupeKey(videoId: $0.track.videoId, playedAt: $0.playedAt) })
            for event in events where seen.insert(ListeningStatsStore.dedupeKey(videoId: event.track.videoId, playedAt: event.playedAt)).inserted {
                // Through the wire's second resolution, as every play that leaves a device is.
                log.append(PlayEvent(
                    track: event.track,
                    playedAt: EventMarks.second(event.playedAt),
                    secondsPlayed: event.secondsPlayed,
                    origin: event.origin
                ))
            }
            marks = EventMarks.advance(marks, senderMarks: senderMarks, base: base, localPeerId: id)
            confirmed[sender] = senderMarks
        }

        var heldVideoIds: Set<String> { Set(log.map(\.track.videoId)) }
    }

    /// One round, `client` asking `server`, the way `SyncEngine.EventSelection` chooses.
    private func round(_ client: inout Device, _ server: inout Device) {
        let pushBase = client.confirmed[server.id] ?? [:]
        let pushed = EventMarks.select(client.log, after: pushBase, legacySince: nil)
        let request = client.currentMarks
        server.receive(pushed, senderMarks: request, base: pushBase, from: client.id)
        let reply = EventMarks.select(server.log, after: request, legacySince: nil)
        client.receive(reply, senderMarks: server.currentMarks, base: request, from: server.id)
    }

    // MARK: - The case that lost plays

    /// Phone at 8:00, iPad at 8:30, iPad syncs with the Mac first. Asking by one date, the Mac
    /// then wants everything after 8:30 from the phone — and the 8:00 play never moves again.
    func testAPlayOlderThanOneRelayedFromAThirdDeviceStillArrives() {
        var phone = Device("phone")
        var ipad = Device("ipad")
        var mac = Device("mac")
        phone.play("commute", at: 8 * 3600)
        ipad.play("sofa", at: 8.5 * 3600)

        round(&ipad, &mac)
        round(&mac, &phone)
        round(&ipad, &mac)

        for device in [phone, ipad, mac] {
            XCTAssertEqual(device.heldVideoIds, ["commute", "sofa"], "\(device.id) is missing a play")
        }
    }

    // MARK: - Choosing what to send

    /// A device the asker has never heard from is sent in full, whatever its dates.
    func testEverythingFromAnUnknownDeviceIsSent() {
        var ipad = Device("ipad")
        ipad.play("old", at: 100)
        ipad.play("new", at: 200)
        let chosen = EventMarks.select(ipad.log, after: ["phone": Date(timeIntervalSince1970: 10_000)], legacySince: nil)
        XCTAssertEqual(chosen.map(\.track.videoId), ["old", "new"])
    }

    /// A play held here at 10:00:00.7 is 10:00:00 on every other device. Compared below the
    /// second, the asker's mark would always look older and the play would go back every round.
    func testAPlayIsNotResentForItsFractionOfASecond() {
        let event = PlayEvent(track: PeerFixtures.track("a"), playedAt: Date(timeIntervalSince1970: 1_000.7), secondsPlayed: 30, origin: "phone")
        XCTAssertTrue(EventMarks.select([event], after: ["phone": Date(timeIntervalSince1970: 1_000)], legacySince: nil).isEmpty)
    }

    /// Plays logged before origins existed have nothing to file them under, so they keep the
    /// old single date — on or after it, exactly as every round chose before.
    func testPlaysWithNoOriginGoByTheOldDate() {
        let old = PlayEvent(track: PeerFixtures.track("old"), playedAt: Date(timeIntervalSince1970: 100), secondsPlayed: 30)
        let edge = PlayEvent(track: PeerFixtures.track("edge"), playedAt: Date(timeIntervalSince1970: 200), secondsPlayed: 30)
        let chosen = EventMarks.select([old, edge], after: [:], legacySince: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(chosen.map(\.track.videoId), ["edge"])
        XCTAssertEqual(EventMarks.select([old, edge], after: [:], legacySince: nil).count, 2)
    }

    // MARK: - Moving the marks

    /// Plays that start beyond what is held leave a hole. Moving the mark past it would mean
    /// never asking for what is in it, since asking is done by mark.
    func testAMarkDoesNotJumpAGap() {
        let held = ["phone": Date(timeIntervalSince1970: 100)]
        let advanced = EventMarks.advance(
            held,
            senderMarks: ["phone": Date(timeIntervalSince1970: 500)],
            base: ["phone": Date(timeIntervalSince1970: 300)],
            localPeerId: "mac"
        )
        XCTAssertEqual(advanced["phone"], Date(timeIntervalSince1970: 100))
    }

    func testAMarkMovesUpWhenThePlaysJoinOn() {
        let advanced = EventMarks.advance(
            ["phone": Date(timeIntervalSince1970: 300)],
            senderMarks: ["phone": Date(timeIntervalSince1970: 500), "ipad": Date(timeIntervalSince1970: 50)],
            base: ["phone": Date(timeIntervalSince1970: 200)],
            localPeerId: "mac"
        )
        XCTAssertEqual(advanced["phone"], Date(timeIntervalSince1970: 500))
        XCTAssertEqual(advanced["ipad"], Date(timeIntervalSince1970: 50), "nothing in the base means everything was sent")
    }

    /// Plays chosen by date — a push to a peer whose marks are not known yet — claim nothing.
    func testPlaysChosenByDateMoveNoMark() {
        let advanced = EventMarks.advance(
            [:],
            senderMarks: ["phone": Date(timeIntervalSince1970: 500)],
            base: nil,
            localPeerId: "mac"
        )
        XCTAssertTrue(advanced.isEmpty)
    }

    /// Marks never go backwards, and this device's own is never taken from anyone else.
    func testAMarkNeverMovesBackwardsOrForThisDevice() {
        let advanced = EventMarks.advance(
            ["phone": Date(timeIntervalSince1970: 900)],
            senderMarks: ["phone": Date(timeIntervalSince1970: 500), "mac": Date(timeIntervalSince1970: 999)],
            base: [:],
            localPeerId: "mac"
        )
        XCTAssertEqual(advanced["phone"], Date(timeIntervalSince1970: 900))
        XCTAssertNil(advanced["mac"])
    }

    // MARK: - Any order at all

    /// Three devices, plays and rounds in a scrambled order, and two invariants checked after
    /// every step: what any device holds of another's plays up to its mark is exactly that
    /// device's own log up to the mark — no gaps — and once everyone has talked to everyone,
    /// everyone holds everything.
    func testThreeDevicesInAnyOrderConvergeWithoutGaps() {
        var generator = SplitMix(seed: 0x5EED)
        for _ in 0..<40 {
            var devices = [Device("phone"), Device("ipad"), Device("mac")]
            var clock: TimeInterval = 1_000
            var played = 0
            for _ in 0..<60 {
                if generator.next() % 3 == 0 {
                    let who = Int(generator.next() % 3)
                    clock += TimeInterval(6 + generator.next() % 600)
                    devices[who].play("p\(played)", at: clock)
                    played += 1
                } else {
                    let a = Int(generator.next() % 3)
                    let b = (a + 1 + Int(generator.next() % 2)) % 3
                    var client = devices[a]
                    var server = devices[b]
                    round(&client, &server)
                    devices[a] = client
                    devices[b] = server
                }
                assertNoGaps(devices)
            }
            for _ in 0..<2 {
                for a in 0..<3 {
                    for b in 0..<3 where a != b {
                        var client = devices[a]
                        var server = devices[b]
                        round(&client, &server)
                        devices[a] = client
                        devices[b] = server
                    }
                }
            }
            let everything = Set((0..<played).map { "p\($0)" })
            for device in devices {
                XCTAssertEqual(device.heldVideoIds, everything, "\(device.id) did not converge")
            }
        }
    }

    private func assertNoGaps(_ devices: [Device], file: StaticString = #filePath, line: UInt = #line) {
        for holder in devices {
            for origin in devices where origin.id != holder.id {
                guard let mark = holder.marks[origin.id] else { continue }
                let truth = Set(origin.log.filter { $0.origin == origin.id && EventMarks.second($0.playedAt) <= mark }.map(\.track.videoId))
                let held = Set(holder.log.filter { $0.origin == origin.id && EventMarks.second($0.playedAt) <= mark }.map(\.track.videoId))
                XCTAssertEqual(held, truth, "\(holder.id) claims \(origin.id)'s plays to \(mark) but has a gap", file: file, line: line)
            }
        }
    }
}

/// A seeded generator, so a failure here fails the same way twice.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
