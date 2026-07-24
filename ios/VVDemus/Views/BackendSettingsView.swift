import SwiftUI

/// Lets the backend URL be changed on-device — required on a physical phone, since
/// 127.0.0.1 only resolves to the phone itself, not the Mac running uvicorn.
struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case checking
        case success
        case failure(String)
    }

    init() {
        _urlText = State(initialValue: UserDefaults.standard.string(forKey: APIClient.baseURLDefaultsKey) ?? APIClient.defaultBaseURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.33:8000", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Backend URL")
                } footer: {
                    Text("On the Simulator, 127.0.0.1 works. On a real phone, use your Mac's LAN IP — both need to be on the same Wi-Fi, and `uvicorn app.main:app --host 0.0.0.0 --port 8000` needs to be running.")
                }

                Section {
                    Button("Save & Test Connection") {
                        save()
                    }
                    switch status {
                    case .idle:
                        EmptyView()
                    case .checking:
                        HStack {
                            ProgressView()
                            Text("Checking…").foregroundStyle(Theme.textSecondary)
                        }
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Backend Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func save() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            status = .failure("That doesn't look like a valid URL")
            return
        }
        UserDefaults.standard.set(trimmed, forKey: APIClient.baseURLDefaultsKey)
        APIClient.shared.baseURL = url
        status = .checking
        Task {
            do {
                let ok = try await APIClient.shared.healthCheck()
                status = ok ? .success : .failure("Backend responded, but health check failed")
            } catch {
                status = .failure("Couldn't reach \(url.host ?? "host") — check Wi-Fi and that uvicorn is running")
            }
        }
    }
}
