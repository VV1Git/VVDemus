import Foundation

/// Your named mix radios: each one's picks, and what was removed from it.
///
/// Synced with every linked device as `MixRadio` records — see that type for why a mix merges
/// newest-wins as a whole. The stations built from them live in `MixStationStore`.
@MainActor
final class MixRadioStore: ObservableObject {
    static let shared = MixRadioStore()

    /// Present mixes, oldest first, so a new one lands at the bottom of the list it is in.
    @Published private(set) var mixes: [MixRadio] = []
    /// The real storage. `mixes` is the tombstone-free projection of this.
    private(set) var records: [MixRadio] = []

    private let key = "mix_radios_v1"

    /// The single unnamed tray this feature started as becomes a mix under this one id on
    /// every device, so two devices that each migrate it end up with one mix, not two.
    static let migratedId = UUID(uuidString: "6D1C0E2A-3B57-4F0B-9E7A-0A11CE5EED01")!

    private init() {
        if let decoded = DefaultsSnapshot.load([MixRadio].self, forKey: key) {
            records = decoded
        } else {
            migrateTray()
        }
        rebuild()
    }

    func mix(_ id: UUID) -> MixRadio? {
        mixes.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, with track: Track) -> MixRadio {
        var mix = MixRadio(id: UUID(), name: name, seeds: [], removed: [], createdAt: Date(),
                           deletedAt: nil, stamp: .now())
        mix.add(track)
        records.append(mix)
        edited(mix.id)
        return mix
    }

    func add(_ track: Track, to id: UUID) {
        edit(id) { $0.add(track) }
    }

    func remove(_ track: Track, from id: UUID) {
        edit(id) { $0.remove(track) }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        edit(id) { $0.name = name }
    }

    func delete(_ id: UUID) {
        edit(id) { $0.deletedAt = Date() }
        MixStationStore.shared.forget(id)
    }

    /// The rule is `MixRadio.merging`; this is the plumbing around it. Not announced back —
    /// the peer is where these came from.
    @discardableResult
    func merge(_ incoming: [MixRadio]) -> Int {
        let merged = MixRadio.merging(records, incoming)
        guard merged.changed > 0 else { return 0 }
        records = merged.mixes
        // A delete from another device takes its station with it here too.
        for mix in records where !mix.isPresent { MixStationStore.shared.forget(mix.id) }
        rebuild()
        save()
        return merged.changed
    }

    private func edit(_ id: UUID, _ change: (inout MixRadio) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let before = records[index]
        change(&records[index])
        guard records[index] != before else { return }
        records[index].stamp = .now()
        edited(id)
    }

    /// Saves, tells linked devices, and rebuilds the station here — on the device the edit
    /// was made on, whether or not the station is on screen, so the new station follows the
    /// edit to the other devices rather than each of them building its own.
    private func edited(_ id: UUID) {
        rebuild()
        save()
        PeerLink.shared.libraryDidChange()
        if mix(id) != nil { Task { try? await MixStationBuilder.shared.build(id) } }
    }

    private func rebuild() {
        mixes = records.filter(\.isPresent).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The picks stored before mixes had names: `mix_radio_v2` (stamped, synced) or the first
    /// build's unstamped `mix_radio_seeds_v1`.
    private func migrateTray() {
        let defaults = UserDefaults.standard
        var seeds: [Track] = []
        var stamp = EditStamp.now()
        if let data = defaults.data(forKey: "mix_radio_v2"),
           let old = try? JSONDecoder().decode(MixRadioRecord.self, from: data) {
            seeds = old.seeds
            // Kept, so the device whose picks were edited last wins the merge here too.
            if old.stamp.editedAt != .distantPast { stamp = old.stamp }
        } else if let data = defaults.data(forKey: "mix_radio_seeds_v1"),
                  let old = try? JSONDecoder().decode([Track].self, from: data) {
            seeds = old
        }
        defaults.removeObject(forKey: "mix_radio_v2")
        defaults.removeObject(forKey: "mix_radio_seeds_v1")
        guard !seeds.isEmpty else {
            save()
            return
        }
        records = [MixRadio(id: Self.migratedId, name: MixRadio.suggestedName(for: seeds),
                            seeds: seeds, removed: [], createdAt: stamp.editedAt,
                            deletedAt: nil, stamp: stamp)]
        save()
    }
}

/// The stations built from each mix, and the radios they were built from.
///
/// Stations persist and sync, exactly as a single-seed radio's songs do in `RadioCacheStore`:
/// built once, kept until Refresh or an edit, and the same on every device. The radios behind
/// them are kept on this device only — they are what lets an edit rebuild the station from the
/// same inputs, so removing a song moves the songs like it and nothing else.
@MainActor
final class MixStationStore: ObservableObject {
    static let shared = MixStationStore()

    struct Station: Codable, Equatable {
        var tracks: [Track]
        /// The `MixRadio.signature` this was built for. Anything else means it is stale.
        var signature: String
        /// What a refresh pushed back, carried into every rebuild after it — otherwise the
        /// first edit after a refresh would put back the songs it had moved out of the way.
        var pushedBack: [String]
        var builtAt: Date
    }

    @Published private(set) var stations: [UUID: Station] = [:]
    private var radios: [String: [Track]] = [:]
    private var radioOrder: [String] = []

    /// Enough for a few mixes' picks and their recent removals.
    private let radioLimit = 60
    private let stationsKey = "mix_stations_v1"
    private let radiosKey = "mix_input_radios_v1"
    static let recordPrefix = "mix_station:"
    /// Where the build before this store kept mix stations, in `RadioCacheStore`.
    static let legacyRadioCachePrefix = "mix:"

    private init() {
        stations = DefaultsSnapshot.load([UUID: Station].self, forKey: stationsKey) ?? [:]
        if let saved = DefaultsSnapshot.load(RadioSnapshot.self, forKey: radiosKey) {
            radios = saved.radios
            radioOrder = saved.order
        }
        // They were taking slots in a cache sized for twenty real radios.
        RadioCacheStore.shared.removeStations(withPrefix: Self.legacyRadioCachePrefix)
    }

    func station(for id: UUID) -> Station? { stations[id] }

    var knownRadios: [String: [Track]] { radios }

    /// Keeps a built station, remembers what it was built from, and tells linked devices
    /// straight away — storing one is not itself a library change, so without the nudge the
    /// other device would only hear of it at the next sync, and build its own before then.
    func keep(_ build: MixRadioBuild, signature: String, pushedBack: [String], for id: UUID) {
        guard !build.tracks.isEmpty else { return }
        for (videoId, radio) in build.radios where !radio.isEmpty {
            radios[videoId] = radio
            radioOrder.removeAll { $0 == videoId }
            radioOrder.append(videoId)
        }
        while radioOrder.count > radioLimit {
            radios.removeValue(forKey: radioOrder.removeFirst())
        }
        stations[id] = Station(tracks: build.tracks, signature: signature,
                               pushedBack: pushedBack, builtAt: Date())
        save()
        PeerLink.shared.libraryDidChange()
    }

    func forget(_ id: UUID) {
        guard stations.removeValue(forKey: id) != nil else { return }
        save()
    }

    // MARK: - Sync

    func syncRecords() -> [GeneratedRecord] {
        stations.compactMap { id, station in
            guard let data = try? JSONEncoder().encode(station) else { return nil }
            return GeneratedRecord(
                id: Self.recordPrefix + id.uuidString,
                payload: data,
                generatedAt: station.builtAt,
                stamp: EditStamp(editedAt: station.builtAt, editedBy: PeerIdentityBox.currentPeerId)
            )
        }
    }

    /// Newest build wins. A station is a single generated artefact — half of one device's
    /// build spliced into the other's is not something either of them showed.
    @discardableResult
    func applySynced(_ record: GeneratedRecord) -> Bool {
        guard record.id.hasPrefix(Self.recordPrefix),
              let id = UUID(uuidString: String(record.id.dropFirst(Self.recordPrefix.count))),
              let station = try? JSONDecoder().decode(Station.self, from: record.payload),
              !station.tracks.isEmpty else { return false }
        if let existing = stations[id], station.builtAt <= existing.builtAt { return false }
        stations[id] = station
        save()
        return true
    }

    private struct RadioSnapshot: Codable {
        var radios: [String: [Track]]
        var order: [String]
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(stations) { defaults.set(data, forKey: stationsKey) }
        if let data = try? JSONEncoder().encode(RadioSnapshot(radios: radios, order: radioOrder)) {
            defaults.set(data, forKey: radiosKey)
        }
    }
}

/// Builds and refreshes mix stations, one at a time per mix.
@MainActor
final class MixStationBuilder: ObservableObject {
    static let shared = MixStationBuilder()

    /// Mixes being built right now, for the screens showing them.
    @Published private(set) var building: Set<UUID> = []

    /// How long a device that did not make an edit waits for the station from the one that
    /// did, before building its own. Two builds would each be different and the newer would
    /// replace the older on every device: the list changing once, under you, for no reason.
    static let peerGrace: TimeInterval = 20

    enum Failure: Error { case noNewSongs }

    /// Whether this device should build `mix`'s stale station now, or leave it to the device
    /// that made the edit.
    func shouldBuildHere(_ mix: MixRadio, now: Date = Date()) -> Bool {
        mix.stamp.editedBy == PeerIdentityBox.currentPeerId
            || now.timeIntervalSince(mix.stamp.editedAt) > Self.peerGrace
    }

    /// Builds the station for the mix as it stands, if the one kept is not already for it.
    /// Reuses the radios the last build read, so an edit moves only what it is about.
    func build(_ id: UUID) async throws {
        guard let mix = MixRadioStore.shared.mix(id), !mix.seeds.isEmpty,
              !building.contains(id) else { return }
        let stations = MixStationStore.shared
        let existing = stations.station(for: id)
        guard existing?.signature != mix.signature else { return }
        building.insert(id)
        defer { building.remove(id) }
        let pushedBack = existing?.pushedBack ?? []
        let build = try await MixRadioService.build(
            seeds: mix.seeds, removed: mix.removed, avoiding: Set(pushedBack),
            deeper: false, known: stations.knownRadios
        )
        // The mix may have moved on while this was out; that edit has its own build coming.
        guard MixRadioStore.shared.mix(id)?.signature == mix.signature else { return }
        stations.keep(build, signature: mix.signature, pushedBack: pushedBack, for: id)
    }

    /// New songs for the same mix: each pick's radio read afresh and a page deeper, with what
    /// was showing pushed to the back. The picks stay on top.
    func refresh(_ id: UUID) async throws {
        guard let mix = MixRadioStore.shared.mix(id), !mix.seeds.isEmpty,
              !building.contains(id) else { return }
        building.insert(id)
        defer { building.remove(id) }
        let stations = MixStationStore.shared
        let seedIds = Set(mix.seeds.map(\.videoId))
        let shown = Set((stations.station(for: id)?.tracks ?? []).map(\.videoId)).subtracting(seedIds)
        let build = try await MixRadioService.build(
            seeds: mix.seeds, removed: mix.removed, avoiding: shown,
            deeper: true, known: stations.knownRadios
        )
        guard !build.tracks.isEmpty else { throw Failure.noNewSongs }
        guard let current = MixRadioStore.shared.mix(id) else { return }
        stations.keep(build, signature: current.signature == mix.signature ? mix.signature : "",
                      pushedBack: Array(shown), for: id)
    }
}
