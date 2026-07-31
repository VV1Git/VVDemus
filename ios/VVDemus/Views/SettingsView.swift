import SwiftUI

/// Preferences and diagnostics, pushed from the Library tab. These four sections used to
/// sit directly underneath the user's playlists, so ten lines of explanatory footer copy
/// and a byte-counter panel were the bottom half of "Your Library".
struct SettingsView: View {
    @AppStorage(InnerTubeClient.dataSaverDefaultsKey) private var dataSaverEnabled = false
    @AppStorage(LocalControlServer.defaultsKey) private var connectEnabled = true
    @ObservedObject private var controlServer = LocalControlServer.shared
    @ObservedObject private var byteCounter = NetworkByteCounter.shared
    @State private var imageCacheBytes: Int64 = 0

    var body: some View {
        List {
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
                Text("Requests smaller artwork and reads less far ahead, so skipping a track wastes less of what was already downloaded. Audio quality is unchanged — YouTube currently only offers this app one audio format, so the bitrate can't be lowered.")
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
            }

            Section {
                Toggle(
                    "VVDemus Connect",
                    isOn: $connectEnabled
                )
                // `.onChange` rather than a side effect inside a Binding setter, which
                // mutates an ObservableObject this view observes while it is rendering.
                .onChange(of: connectEnabled) { _, enabled in
                    enabled ? controlServer.start() : controlServer.stop()
                }

                if controlServer.isRunning {
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
                Text("Lets a browser on the same WiFi network see what's playing and control it — or play it through the computer's own speakers instead. No account or pairing needed, so only turn this on when you're on a network you trust.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
