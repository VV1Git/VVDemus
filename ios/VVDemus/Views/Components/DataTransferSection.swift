import SwiftUI
import UniformTypeIdentifiers

/// Export the whole library to a file, and merge one back in.
///
/// A component rather than another block in `SettingsView`, which is deliberately nothing but a
/// list of sections: this one carries two file pickers, an alert and the result of a merge, and
/// inlining that would make the settings screen mostly this feature.
///
/// One code path for both platforms. `.fileExporter` is a share sheet on iOS and a save panel on
/// the Mac, and `.fileImporter` is the document browser or an open panel — SwiftUI picks, so
/// there is nothing here to keep in step between the two apps.
struct DataTransferSection: View {
    @State private var document: BackupDocument?
    @State private var exportFilename = ""
    @State private var isExporting = false
    @State private var isImporting = false
    /// The merge's own summary, kept as a value so the row still says what arrived after the
    /// user has navigated away from and back to the stores it describes.
    @State private var lastImport: SyncSummary?
    @State private var failure: Failure?

    var body: some View {
        Section {
            Button("Export Data…") { startExport() }
            Button("Import Data…") {
                // Cleared here rather than when the merge lands: a summary from the previous
                // file sitting above a picker the user has just reopened reads as the result
                // of the import they are about to do.
                lastImport = nil
                isImporting = true
            }

            // Branched on whether anything actually moved, not on the import having finished.
            // A green "imported" over a merge that changed nothing is the strongest signal on
            // the screen pointing at an outcome the user cannot find in their library —
            // `SyncSummary` already says "Already up to date" for exactly this case, in the
            // words a peer sync uses.
            if let lastImport {
                Label(lastImport.description, systemImage: lastImport.isEmpty ? "checkmark.circle" : "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(lastImport.isEmpty ? Color.secondary : Theme.accent)
            }
        } footer: {
            // The last sentence is not padding. Connect's on/off state is deliberately neither
            // exported nor imported — it opens an unauthenticated listener, so it should be a
            // thing you did on purpose on that device — and without saying so, Connect not
            // coming back after a restore reads as a bug in the import.
            //
            // `fixedSize` for the reason the Data Saver footer records: a row otherwise hands a
            // footer one line and truncates it.
            Text("Export writes your playlists, liked songs, listening history, radios and preferences to a single file. Importing merges that file into this device: nothing is replaced, and importing the same file twice changes nothing the second time. VVDemus Connect isn't included — it stays set per device.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .vvdemBackup,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                failure = Failure(title: "Couldn't Save the Backup", message: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            // The exported type, not `.json`: a picker offering every JSON file on the device
            // invites choosing one that cannot possibly import.
            allowedContentTypes: [.vvdemBackup]
        ) { result in
            switch result {
            case .success(let url):
                importFile(at: url)
            case .failure(let error):
                failure = Failure(title: "Couldn't Open That File", message: error.localizedDescription)
            }
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: - Export

    @MainActor
    private func startExport() {
        // `eventsSince: nil` is the whole log. The field it fills on the returned payload is a
        // live peer's "only send me what I don't have"; `BackupFile` clears it, because in a
        // file it is an instruction to nobody.
        let payload = SyncEngine.snapshot(eventsSince: nil)
        let file = BackupFile(
            exportedAt: Date(),
            exportedBy: .init(peerId: PeerIdentity.shared.peerId, deviceName: PeerIdentity.shared.name),
            appVersion: AppVersion.summary,
            payload: payload,
            preferences: .init(dataSaverEnabled: UserDefaults.standard.bool(forKey: InnerTubeClient.dataSaverDefaultsKey))
        )
        do {
            document = BackupDocument(data: try BackupCodec.encode(file))
            exportFilename = "VVDemus Backup \(Self.filenameDate.string(from: Date()))"
            isExporting = true
        } catch {
            failure = Failure(title: "Couldn't Build the Backup", message: error.localizedDescription)
        }
    }

    /// Date-only, and fixed rather than localized, so backups from a phone and a Mac sort
    /// together in a folder however each machine is set up.
    private static let filenameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Import

    @MainActor
    private func importFile(at url: URL) {
        // The picker hands back a URL this process has no standing permission to read — the
        // file lives in iCloud Drive, or another app's container. Without the scoped-access
        // pair the read fails outright on a real device, while the simulator, whose files are
        // all reachable anyway, happily reads it and hides the bug.
        //
        // The return value is deliberately not checked: it is false both when access was
        // refused and when the URL was never scoped to begin with (a plain file on the Mac,
        // where the app is unsandboxed), and treating the second as a failure would make
        // importing impossible there. If access really was refused, the read below throws and
        // is reported.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let file = try BackupCodec.decode(try Data(contentsOf: url))
            // Merge, not replace — the same call a peer sync round makes, with the same rules:
            // newest `EditStamp` wins per record, tombstones are respected, and a second import
            // of the same file is a no-op. Nothing on this device is destroyed by an import,
            // which is the property that makes it safe to hand a backup to someone who is not
            // sure what is in it.
            //
            // `file.exportedBy.peerId` reaches `SyncCursor` through the payload and stops
            // there; it is never adopted as this device's identity. Two devices sharing a peer
            // id would break `EditStamp`'s deterministic tiebreak, which is the thing that
            // makes two copies of a playlist converge.
            let summary = SyncEngine.merge(file.payload)
            // Applied after the merge for no reason other than order of reading — the
            // preference is a plain scalar with no stamp to compare, so the file's value simply
            // wins. `preferences` holds exactly what import applies; Connect's key is not in it.
            UserDefaults.standard.set(file.preferences.dataSaverEnabled, forKey: InnerTubeClient.dataSaverDefaultsKey)
            lastImport = summary
        } catch {
            // `BackupError` is a `LocalizedError` whose messages are written for this alert —
            // "That file isn't a VVDemus backup", not a decoding-error dump. The silently empty
            // library is the failure this feature must never have, so every rejection says
            // which one it was.
            failure = Failure(title: "Couldn't Import That File", message: error.localizedDescription)
        }
    }

    // MARK: - Plumbing

    /// A value rather than a bare `String?`, so one alert can carry both the export and import
    /// failures without a shared title that fits neither.
    private struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

/// The exported bytes, wrapped for `.fileExporter`.
///
/// Write-only in practice: `BackupCodec` owns reading, and the import path decodes the picked
/// URL itself rather than round-tripping through a document. The protocol still demands a
/// reading initialiser, so it exists and refuses — nothing constructs this from a file.
private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vvdemBackup] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
