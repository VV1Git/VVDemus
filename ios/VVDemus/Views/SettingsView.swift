import SwiftUI

/// Preferences and diagnostics, pushed from the Library tab. These four sections used to
/// sit directly underneath the user's playlists, so ten lines of explanatory footer copy
/// and a byte-counter panel were the bottom half of "Your Library".
struct SettingsView: View {
    @AppStorage(InnerTubeClient.dataSaverDefaultsKey) private var dataSaverEnabled = false
    @AppStorage(LocalControlServer.defaultsKey) private var connectEnabled = true
    @ObservedObject private var controlServer = LocalControlServer.shared
    @ObservedObject private var byteCounter = NetworkByteCounter.shared
    /// Observed, not read through `.shared` at render time: the row below is the only place
    /// this screen shows the pairing, and without the subscription it kept saying "Not set up"
    /// after coming back from `PairingView` having just paired.
    @ObservedObject private var pairedStore = PairedPeerStore.shared
    @State private var imageCacheBytes: Int64 = 0

    var body: some View {
        // A `List` is the phone's settings container; the Mac's is a grouped `Form`, and the
        // difference is not cosmetic. Under `.listStyle(.inset)` every footer here truncated
        // to a single line — the sentences explaining Data Saver and Connect ended in "Y…"
        // and "nee…" — the toggles drew as checkboxes rather than switches, and each row was
        // stretched to the window's full width, so a label sat a foot away from its value.
        // `.formStyle(.grouped)` is what macOS Settings itself uses and fixes all three.
        #if os(macOS)
        Form { sections }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            // A grouped form paints its own scroll background, and constrained to a column that
            // background became a lighter rectangle standing on the pane's black — a visible
            // seam down both sides for the height of the window. The rows keep their own fills;
            // it is only the sheet behind them that has to go.
            .scrollContentBackground(.hidden)
            // Settings is a column of prose and label/value pairs, and neither reads at
            // 1600pt. Matches the width `PairingView` already pins itself to.
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .navigationTitle("Settings")
        #else
        List { sections }
            .settingsListStyle()
            .navigationTitle("Settings")
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            LabeledContent("Version") {
                Text(AppVersion.summary)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }

        Section {
            Toggle("Data Saver", isOn: $dataSaverEnabled)
        } footer: {
            // Deliberately modest, because the measurements say so
            // (VVDemusTests/DataUsageBenchmarks):
            //  · Bitrate: no effect today. The low-bitrate audio-only formats are
            //    only reachable through a client YouTube currently refuses, so
            //    every track comes from the one muxed format there is.
            //  · Batch limits: no effect. They're applied to an already-downloaded
            //    response; there is no count parameter to ask for less.
            //  · Artwork and read-ahead: real, and measured.
            //
            // `fixedSize` here and on the other two footers: a footer is only ever a
            // paragraph, and a row will otherwise hand it one line and truncate.
            Text("Requests smaller artwork and reads less far ahead, so skipping a track wastes less of what was already downloaded. Audio quality is unchanged — YouTube currently only offers this app one audio format, so the bitrate can't be lowered.")
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            ForEach(NetworkByteCounter.Category.allCases) { category in
                LabeledContent(category.rawValue) {
                    Text(Self.formattedBytes(byteCounter.bytes[category] ?? 0))
                        .font(.system(.footnote, design: .monospaced))
                }
            }
            // Worth showing next to the counters: the artwork cache is what stops
            // those numbers climbing on every relaunch, so its size is the visible
            // evidence that caching is working.
            LabeledContent("Artwork cache") {
                Text(Self.formattedBytes(imageCacheBytes))
                    .font(.system(.footnote, design: .monospaced))
            }
            .task { imageCacheBytes = await DiskImageCache.shared.totalBytes() }

            Button("Reset Counters", role: .destructive) { byteCounter.reset() }
            Button("Clear Image Cache", role: .destructive) {
                Task {
                    await DiskImageCache.shared.clear()
                    imageCacheBytes = 0
                }
            }
        } header: {
            Text("Network Usage (this session)")
        } footer: {
            Text("Doesn't include live-streaming playback bytes — AVPlayer manages that networking internally, so compare cellular usage in iOS Settings for a full before/after picture.")
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            NavigationLink {
                PairingView()
            } label: {
                LabeledContent("Paired Device") {
                    Text(pairedStore.peer?.name ?? "Not set up")
                        .foregroundStyle(.secondary)
                }
            }
        }

        DataTransferSection()

        Section {
            Toggle(
                "VVDemus Connect",
                isOn: $connectEnabled
            )
            // `.onChange` rather than a side effect inside a Binding setter, which
            // mutates an ObservableObject this view observes while it is rendering.
            //
            // Turning this off no longer stops the server — it stops serving the browser.
            // The paired device's routes stay up, because pairing and sync have nothing to
            // do with a browser and used to break entirely when this was switched off.
            .onChange(of: connectEnabled) { _, enabled in
                controlServer.setWebRemoteEnabled(enabled)
            }

            if connectEnabled, controlServer.isRunning {
                LabeledContent("Open on your computer") {
                    Text(verbatim: controlServer.localAddress.map { "http://\($0):\(controlServer.port)" } ?? "Finding address…")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            // A toggle left switched on next to a blank address is
            // indistinguishable from "still starting up"; say what went wrong.
            // Warning, not accent: it needs the user, but nothing worked.
            if let startupError = controlServer.startupError {
                Text(startupError)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        } footer: {
            Text("Lets a browser on the same WiFi network see what's playing and control it — or play it through the computer's own speakers instead. A browser needs no code, so only turn this on when you're on a network you trust. Your paired device is unaffected: it authenticates, and stays connected either way.")
                .fixedSize(horizontal: false, vertical: true)
        }

        // Last, and outside every `Section`, so it reads as space below the final group rather
        // than as an empty row belonging to it.
        TransportClearanceRow()
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
