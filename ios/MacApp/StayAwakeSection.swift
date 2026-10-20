import SwiftUI

/// Settings ▸ Stay Awake.
struct StayAwakeSection: View {
    @AppStorage(StayAwakePolicy.whilePlayingDefaultsKey) private var whilePlaying = false
    @AppStorage(StayAwakePolicy.lidClosedDefaultsKey) private var lidClosed = false
    @ObservedObject private var stayAwake = StayAwake.shared

    var body: some View {
        Section {
            Toggle("Stay awake while playing", isOn: $whilePlaying)
                .onChange(of: whilePlaying) { _, _ in stayAwake.settingsChanged() }

            Toggle("Keep playing with the lid closed", isOn: $lidClosed)
                .disabled(stayAwake.isAsking)
                .onChange(of: lidClosed) { _, enabled in
                    Task { await stayAwake.lidClosedChanged(enabled) }
                }

            if lidClosed || stayAwake.isAsking || stayAwake.lidError != nil {
                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(stayAwake.lidError != nil ? Theme.warning : .secondary)
                }
            }
        } footer: {
            Text("Stay awake while playing stops your Mac from going to sleep in the middle of a song — including in clamshell mode with an external display. Keep playing with the lid closed goes further and keeps music going with the lid shut and no display attached; turning it on asks for your administrator password once. Either one lets the Mac sleep again two minutes after playback stops. A closed laptop playing in a bag will still get warm.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if stayAwake.isAsking { return "Waiting for permission…" }
        if let error = stayAwake.lidError { return error }
        if !stayAwake.lidAuthorized { return "Permission missing — switch this off and on again" }
        if stayAwake.lidSleepDisabled { return "On — you can close the lid" }
        return "Ready — takes effect while music plays"
    }
}
