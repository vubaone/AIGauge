import SwiftUI

struct MistralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = UsageStore.shared
    @State private var apiKey = ""
    @State private var showFileAccessGuide = false

    var body: some View {
        Form {
            Section {
                HStack {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: settings.mistralColorHex) },
                        set: { settings.mistralColorHex = $0.hexString }), supportsOpacity: false)
                        .labelsHidden().frame(width: 28)
                    Text("Mistral").font(.title2).bold()
                    Spacer()
                    if store.isLoadingMistral { ProgressView().controlSize(.small) }
                }
                Toggle("Enable Mistral", isOn: $settings.mistralEnabled)
                    .onChange(of: settings.mistralEnabled) { enabled in
                        settings.trayBackend = settings.trayBackend.withMistral(enabled)
                        settings.menuBackends = settings.menuBackends.withMistral(enabled)
                        store.clearMistral()
                        if enabled { Task { await store.refreshMistral() } }
                    }
                Text("Shows the shared monthly Vibe & Studio allowance when available, otherwise API/Studio. The tray uses the displayed allowance. Checks never spend tokens.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Connection") {
                Picker("Connect using", selection: $settings.mistralConnectionMethod) {
                    ForEach(MistralConnectionMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .onChange(of: settings.mistralConnectionMethod) { _ in
                    apiKey = ""
                    showFileAccessGuide = false
                    store.clearMistral()
                }

                if settings.mistralConnectionMethod == .keychain {
                    Text("Reads Mistral’s public API using the API key stored by Mistral Vibe in macOS Keychain, or a key added below. Browser cookies are not read in this mode.")
                        .font(.caption).foregroundColor(.secondary)
                    DisclosureGroup("Use an API key") {
                        SecureField("Mistral API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Save and connect") {
                            let key = apiKey
                            Task { if await store.saveMistralKey(key) { apiKey = "" } }
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("The key is verified with Mistral, then saved in Keychain. Use a key with permission to view organization usage.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .disabled(!settings.mistralEnabled || store.isLoadingMistral)
                    Link("Mistral Vibe setup", destination: URL(string: "https://docs.mistral.ai/vibe/code/overview")!)
                } else {
                    Text("Connect to the Mistral Admin dashboard using your selected browser session. This reads dashboard billing data rather than the public API.")
                        .font(.caption).foregroundColor(.secondary)
                    Picker("Browser", selection: $settings.mistralSource) {
                        ForEach(["edge", "chrome", "brave"], id: \.self) { source in
                            Text(humanSourceName(source)).tag(source)
                        }
                    }
                    .onChange(of: settings.mistralSource) { _ in store.clearMistral() }
                    TextField("Profile directory", text: $settings.mistralProfile)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: settings.mistralProfile) { _ in store.clearMistral() }
                    Text("Use Default or a profile directory such as Profile 1 from your browser’s version page. Sign in to Mistral Admin in that profile.")
                        .font(.caption).foregroundColor(.secondary)
                    Button {
                        showFileAccessGuide = true
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Grant cookie access…", systemImage: "lock.open")
                    }
                    if showFileAccessGuide { MistralFileAccessHelp() }
                }
                HStack {
                    Button {
                        Task { await store.refreshMistral(allowKeychainPrompt: true) }
                    } label: { Label("Connect Mistral", systemImage: "key") }
                    Button("Check usage") {
                        Task { await store.refreshMistral() }
                    }
                    Link("Mistral Admin", destination: URL(string: "https://admin.mistral.ai/subscription")!)
                }
                .disabled(!settings.mistralEnabled || store.isLoadingMistral)
                Text("Connect Mistral may ask for Keychain access. Background checks never show Keychain prompts.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if settings.mistralEnabled {
                Section("Monthly allowance") {
                    if let error = store.mistral.error {
                        Text(error).foregroundColor(.red).textSelection(.enabled)
                        if settings.mistralConnectionMethod == .browser,
                           !showFileAccessGuide, MistralAccessHelp.isFileAccessError(error) {
                            MistralFileAccessHelp()
                        }
                    } else if store.mistral.windows.isEmpty {
                        Text("No data yet — connect Mistral or check usage.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.mistral.windows) { window in WindowRow(window: window) }
                        Text("Updated \(store.mistral.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MistralFileAccessHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow access to browser cookies").font(.headline)
            Text("In Full Disk Access, drag AIGauge below into the app list and enable it. Then quit and reopen AIGauge before checking usage again.")
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path))
                    .resizable().frame(width: 32, height: 32)
                Text("AIGauge.app").font(.headline)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").foregroundColor(.secondary)
            }
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("Drag this app into the Full Disk Access app list")
            Text("App to add: \(Bundle.main.bundleURL.path)")
                .font(.caption).textSelection(.enabled)
            HStack {
                Button("Open Full Disk Access") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Show AIGauge in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
            Text("macOS requires you to enable file access in System Settings. Full Disk Access covers protected files from other apps; Keychain access is a separate permission.")
                .font(.caption).foregroundColor(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}
