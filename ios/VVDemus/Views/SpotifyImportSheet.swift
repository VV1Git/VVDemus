import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Paste a public Spotify playlist link, get the same songs as a local playlist.
///
/// A plain stack rather than a `Form`, for the reason `PairingView` gives at length: this is a
/// focused, one-time task with a text field and one button, and the List-row interaction bugs
/// that screen ran into are not worth re-inviting. The three states — link, run, summary — are
/// all rendered inside one `ScrollView`, because the summary's miss list is unbounded (a run of
/// 100 obscure tracks can miss dozens) and a fixed-height sheet would simply clip the names of
/// the songs the user now has to go and find by hand.
struct SpotifyImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer = SpotifyImporter()

    @State private var link = ""
    @State private var name = ""

    #if os(macOS)
    /// What the current state's content actually wants, so the sheet can be the size of the
    /// thing it is showing.
    ///
    /// This replaces a flat `minHeight: 340`, which was there because a `ScrollView` has no
    /// intrinsic height and a macOS sheet sizes to its content — without *some* height the
    /// sheet opens as a sliver. But a floor is the wrong instrument: every state paid the tall
    /// state's price, so a finished summary reading "Added 29 of 29 songs." and a Done button
    /// sat at the top of a sheet that was mostly empty black.
    @State private var contentHeight: CGFloat = 0

    /// Bounded at both ends. The floor covers the first frame, before the measurement lands,
    /// where the height is still 0 and an unclamped sheet would flicker open at nothing. The
    /// ceiling is what keeps the scrolling: a hundred-track import can miss dozens of songs,
    /// and a sheet free to grow with that list would run off the bottom of a laptop screen and
    /// take the Done button with it.
    private var macContentHeight: CGFloat { min(max(contentHeight, 120), 520) }
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    switch importer.phase {
                    case .idle:
                        linkForm(problem: nil)
                    case .failed(let message):
                        // Deliberately still the form, with the message above it. A dead end with
                        // only a Done button would throw away a link the user has already pasted
                        // over a failure they can often fix in one keystroke — a private playlist
                        // swapped for a public one, or a link copied with half the id missing.
                        linkForm(problem: message)
                    case .fetching:
                        fetching
                    case .matching(let completed, let total, let current):
                        matching(completed: completed, total: total, current: current)
                    case .finished(let summary):
                        finished(summary)
                    }
                }
                .padding(Theme.Metrics.gutter)
                .frame(maxWidth: 520, alignment: .leading)
                #if os(macOS)
                // Measured, not guessed. A vertical `ScrollView` proposes unbounded height to
                // its content, so this reports the height the stack actually wants and is not
                // a function of the frame applied below — no feedback loop between the two.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                #endif
            }
            .frame(maxWidth: .infinity)
            #if os(macOS)
            .frame(height: macContentHeight)
            #endif
            .background(Theme.background)
            .navigationTitle("Import from Spotify")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .leadingActions) {
                    Button("Close") { dismiss() }
                        // While songs are being matched the only way out is the Cancel button in
                        // the content, which tears the run down first. Leaving Close live here
                        // would abandon a running import behind a closed sheet, still burning
                        // searches against the rate limiter for a playlist nobody will see.
                        .disabled(isRunning)
                }
            }
        }
        // Same reason as the disabled Close: a half-finished import that vanishes under a swipe
        // is worse than no import, because nothing on screen afterwards says it was ever running.
        .interactiveDismissDisabled(isRunning)
        #if os(macOS)
        .frame(minWidth: 460)
        #endif
        .task {
            // Read once, on appearance, and only when the clipboard is worth reading. Reading
            // `UIPasteboard.general.string` outright puts the system's blocking "would like to
            // paste from Safari" alert in front of the sheet *every* time it is opened — the
            // sheet is constructed fresh by `.sheet`, so `link` is always empty and the read
            // always happened, including for the overwhelmingly common clipboard holding a
            // shopping list and nothing we could ever have used. `probablyHoldsAWebURL` asks
            // the system whether a URL is in there without exposing the contents and without
            // prompting, so the alert now only appears when it might buy the user something.
            guard link.isEmpty, await Self.probablyHoldsAWebURL, let pasted = Self.clipboardText
            else { return }
            // Anything that is not a playlist link stays out of the field entirely: a clipboard
            // holding a URL to something else is not a better starting point than empty, and
            // pre-filling it would only make the validation message look like our mistake.
            if SpotifyPlaylistLink.playlistId(from: pasted) != nil { link = pasted }
        }
        // A failure describes the link that produced it, and the sheet deliberately leaves the
        // form up underneath so the user can fix it in place — which is the exact moment the
        // message stops being true. Without this, "Spotify won't share that playlist" stayed on
        // screen above a corrected link, and while the replacement was half-typed it sat next to
        // a second orange line about a link that was no longer in the field.
        .onChange(of: link) { _, _ in importer.clearFailure() }
    }

    // MARK: - Link

    @ViewBuilder
    private func linkForm(problem: String?) -> some View {
        if let problem {
            Text(problem).font(.footnote).foregroundStyle(Theme.warning)
        }

        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Spotify playlist link").font(.caption).foregroundStyle(.secondary)
            TextField("https://open.spotify.com/playlist/…", text: $link)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { startImport() }

            // Said while the link is still being edited rather than after Import is pressed:
            // the parse costs nothing, and the alternative is a spinner followed by a failure
            // for a mistake that was visible the whole time.
            if isLinkUnusable {
                Text("That doesn't look like a Spotify playlist link. Album, artist and song links can't be imported.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }

        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Playlist name").font(.caption).foregroundStyle(.secondary)
            // The placeholder is the only place this is explained, so it says what blank does
            // rather than repeating the label.
            TextField("Leave blank to use the Spotify name", text: $name)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { startImport() }
        }

        Button("Import") { startImport() }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(playlistId == nil)

        Text("Songs are matched on YouTube Music one by one, so this takes a moment. Anything that can't be matched is listed at the end instead of being guessed at.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Running

    @ViewBuilder
    private var fetching: some View {
        // No bar at all until there is a total. A determinate bar sitting at zero for the whole
        // fetch reads as a stall, and the honest answer here is that we don't know yet how many
        // songs there are.
        HStack(spacing: Theme.Space.sm) {
            ProgressView().controlSize(.small)
            Text("Reading the playlist from Spotify…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        cancelButton
    }

    @ViewBuilder
    private func matching(completed: Int, total: Int, current: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // `DownloadProgressBar` rather than `ProgressView(value:)` for the reason its own
            // header records: the system bar changes intrinsic size between its determinate and
            // indeterminate forms, so the song title below it would hop. Both layers get the same
            // fraction — there is no "partially matched" song, a search either resolved or hasn't.
            DownloadProgressBar(settled: fraction(completed, of: total),
                                fraction: fraction(completed, of: total))

            HStack(spacing: Theme.Space.sm) {
                Text("\(completed) / \(total)")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    // So the counter ticks over instead of crossfading every time a search lands.
                    .contentTransition(.numericText())
                Spacer(minLength: Theme.Space.sm)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Import progress")
            .accessibilityValue("\(completed) of \(total) songs matched")
            .accessibilityAddTraits(.updatesFrequently)
        }

        // One line, truncated. Song titles run long and this is a progress readout, not content;
        // letting it wrap to three lines would move the Cancel button on every search.
        Text("Matching \"\(current)\"…")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

        cancelButton
    }

    private var cancelButton: some View {
        // The playlist is written only once the run completes, so this really does leave nothing
        // behind — worth saying, because "Cancel" halfway through an import otherwise looks like
        // it might strand a partial playlist in the library.
        Button("Cancel") { importer.cancel() }
            .font(.controlLabel)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Cancel import")
    }

    // MARK: - Summary

    @ViewBuilder
    private func finished(_ summary: ImportSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // Branched on whether a playlist really exists afterwards, not on the run having
            // finished. `SpotifyImporter.write` creates nothing when nothing matched, so an
            // all-miss import — or an empty Spotify playlist, or a 429 on the very first search
            // — used to put a green checkmark and `Imported "Deep Cuts"` at the top of the
            // screen above "Added 0 of 12 songs". The strongest signal on the sheet named a
            // playlist the user then could not find in their library.
            if summary.didCreatePlaylist {
                Label("Imported \"\(summary.playlistName)\"", systemImage: "checkmark.circle.fill")
                    .font(.sheetHeadline)
                    .foregroundStyle(Theme.accent)
            } else {
                Label("Nothing was imported", systemImage: "exclamationmark.circle.fill")
                    .font(.sheetHeadline)
                    .foregroundStyle(Theme.warning)
            }
            Text("Added \(summary.added) of ^[\(summary.requested) song](inflect: true).")
                .foregroundStyle(.secondary)
            if !summary.didCreatePlaylist {
                Text("No playlist was created.").foregroundStyle(.secondary)
            }
        }

        if summary.stoppedEarly {
            Text("YouTube Music started refusing requests, so the import stopped early. Everything matched up to that point was kept.")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
        }

        if summary.truncated {
            Text("Spotify only shares the first 100 songs of a playlist without an account, so this import may be incomplete if the playlist is longer.")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
        }

        if !summary.misses.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("^[\(summary.misses.count) song](inflect: true) couldn't be matched")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                // Named rather than counted, because the only thing to do with a miss is search
                // for it by hand, and a bare "3 missed" makes that impossible.
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(Array(summary.misses.enumerated()), id: \.offset) { _, miss in
                        Text("\(miss.title) — \(miss.artist)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }

        Button("Done") { dismiss() }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
    }

    // MARK: - Plumbing

    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var playlistId: String? { SpotifyPlaylistLink.playlistId(from: trimmedLink) }

    /// Typed something, and it isn't a playlist link. An empty field is not a mistake yet.
    private var isLinkUnusable: Bool { !trimmedLink.isEmpty && playlistId == nil }

    private var isRunning: Bool {
        switch importer.phase {
        case .fetching, .matching: return true
        case .idle, .finished, .failed: return false
        }
    }

    private func fraction(_ completed: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    private func startImport() {
        guard playlistId != nil else { return }
        let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await importer.run(link: trimmedLink, name: chosen.isEmpty ? nil : chosen) }
    }

    /// Plain text on the clipboard, or nil when it holds none.
    ///
    /// Lives here as a private detail rather than in `Platform/` because this sheet is the only
    /// thing in the app that has ever read a pasteboard; promote it the moment there is a second
    /// caller. Both platforms agree on nil for non-text contents — `NSPasteboard` returns nil
    /// rather than an empty string — so no caller has to distinguish "empty" from "not text".
    private static var clipboardText: String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #endif
    }

    /// Whether the clipboard is worth the paste prompt.
    ///
    /// `detectPatterns(for:)` answers "is there something URL-shaped in there" from outside the
    /// sandbox, without handing the app the contents and without showing the user anything —
    /// which is precisely what makes it safe to call unprompted on every appearance. macOS has
    /// no such alert to avoid, so the question does not arise there and the answer is always
    /// yes.
    private static var probablyHoldsAWebURL: Bool {
        get async {
            #if os(iOS)
            // Bridged by hand because UIKit publishes only the `Result` completion form of
            // `detectPatterns`, which Swift does not turn into an `async` overload for us.
            return await withCheckedContinuation { continuation in
                UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                    // A detection error is not a reason to fall back to reading the clipboard:
                    // that would put the prompt back on every appearance, which is the whole
                    // thing being avoided. No answer means no pre-fill.
                    let patterns = try? result.get()
                    continuation.resume(returning: patterns?.contains(.probableWebURL) ?? false)
                }
            }
            #else
            return true
            #endif
        }
    }
}
