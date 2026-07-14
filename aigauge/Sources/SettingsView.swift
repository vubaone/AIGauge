import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store    = UsageStore.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TrayTab()
                .tabItem { Label("Tray", systemImage: "menubar.rectangle") }
            ClaudeTab()
                .tabItem { Label("Claude", systemImage: "c.circle") }
            ServiceTab(service: .codex)
                .tabItem { Label("Codex",  systemImage: "x.circle") }
        }
        .frame(minWidth: 480, minHeight: 360)
        .padding(12)
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Auto-refresh") {
                Stepper(value: $settings.autoRefreshSeconds, in: 0...3600, step: 30) {
                    Text("Every \(settings.autoRefreshSeconds)s (0 = off)")
                }
                Text("How often usage numbers are re-read in the background. This only checks usage — it never spends tokens.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Confirmations") {
                Toggle("Ask before sending a quota refresh", isOn: $settings.confirmQuotaRefresh)
                Text("A quota refresh from the tray menu spends a few tokens. When on, AIGauge asks first; the dialog's “Don't ask again” also turns this off.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Window behaviour") {
                Toggle("Close button hides window (stays in tray)", isOn: $settings.closeToTray)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Text("Note: launch-at-login requires this binary to live in a stable location (e.g. /Applications). Toggle takes effect on next reboot.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("CLI paths (optional)") {
                LabeledContent("ClaudeGauge:") {
                    TextField("auto-discover", text: $settings.claudeGaugePath)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("CodexGauge:") {
                    TextField("auto-discover", text: $settings.codexGaugePath)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Leave empty to auto-discover: AIGauge looks beside its own binary, then in sibling project .build/release/ directories, then in PATH.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            }
            .formStyle(.grouped)

            // Small, dim credit line pinned under the form.
            HStack(spacing: 5) {
                Text("Made by VUBA")
                Text("·")
                Link("dev@vuba.one", destination: URL(string: "mailto:dev@vuba.one")!)
                Text("·")
                Link("vuba.one", destination: URL(string: "https://vuba.one/")!)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .tint(.secondary)
            .padding(.top, 3)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Tray tab

struct TrayTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var store = UsageStore.shared

    var body: some View {
        Form {
            Section("Tray status item") {
                Picker("Show on tray:", selection: $settings.trayBackend) {
                    ForEach(BackendSelection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                Toggle("Show service name with percent", isOn: $settings.trayShowLabel)
                Toggle("Show “%” sign", isOn: $settings.trayShowPercentSign)
                Text("Tray colors are set per provider: Claude in the Claude tab (per account), Codex in the Codex tab. With name off, the colors tell them apart.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if store.orderedTrayItems.count > 1 {
                Section("Tray order") {
                    ReorderStrip(items: store.orderedTrayItems)
                }
            }

            Section("Tray dropdown menu") {
                Picker("Show sections for:", selection: $settings.menuBackends) {
                    ForEach(BackendSelection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Each chosen provider gets a section in the click-menu with short/long-term usage and a Refresh button.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Per-service tab (Codex)

enum ServiceKind { case claude, codex }

struct ServiceTab: View {
    let service: ServiceKind   // currently only .codex uses this view
    @ObservedObject var store = UsageStore.shared
    @ObservedObject var settings = AppSettings.shared

    private var snapshot: UsageSnapshot { store.codex }
    private var isLoading: Bool { store.isLoadingCodex }

    /// Two-way binding between the Codex tray color and its hex in settings.
    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.codexColorHex) },
            set: { settings.codexColorHex = $0.hexString }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28)
                    .help("Color used for Codex in the tray and menu")
                Text(snapshot.serviceName).font(.title2).bold()
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Text(lastUpdatedString)
                    .font(.caption).foregroundColor(.secondary)
            }

            if let err = snapshot.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .font(.callout)
            }

            if snapshot.windows.isEmpty && snapshot.error == nil {
                Text("No data yet — press “Check usage”.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(snapshot.windows) { w in
                    WindowRow(window: w)
                }
            }

            Spacer()

            HStack {
                Button {
                    Task { await store.refreshCodex() }
                } label: { Label("Check usage", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")

                Button {
                    Task { await store.triggerCodexRefresh() }
                } label: { Label("Refresh window (~24 tokens)", systemImage: "bolt.fill") }
                .help("Sends a tiny private prompt that starts the 5-hour quota window. Spends a small number of tokens.")

                Spacer()
            }

            AutoRefreshRow(serviceKey: AppSettings.codexOrderKey)

            if let msg = store.lastActionMessage {
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(8)
    }

    private var lastUpdatedString: String {
        guard snapshot.lastUpdated > .distantPast else { return "never" }
        let f = RelativeDateTimeFormatter()
        return "updated " + f.localizedString(for: snapshot.lastUpdated, relativeTo: Date())
    }
}

// MARK: - Claude tab (multi-account, stacked sections)

struct ClaudeTab: View {
    @ObservedObject var store = UsageStore.shared

    @State private var showAddSheet = false
    @State private var pendingRemoval: ClaudeAccountSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude").font(.title2).bold()
                Spacer()
                if store.isLoadingClaude { ProgressView().controlSize(.small) }
                Text(lastUpdatedString)
                    .font(.caption).foregroundColor(.secondary)
            }

            if let err = store.claudeGlobalError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red).font(.callout)
            }

            if store.claudeAccounts.isEmpty && store.claudeGlobalError == nil {
                Text("No accounts yet — press “Add account”.")
                    .foregroundColor(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.claudeAccounts) { acct in
                        AccountSection(account: acct,
                                       onRefresh: { Task { await store.triggerClaudeRefresh(accountId: acct.id) } },
                                       onRemove: acct.id == "single" ? nil : { pendingRemoval = acct })
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button {
                    Task { await store.refreshClaude() }
                } label: { Label("Check usage", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")

                Button {
                    showAddSheet = true
                } label: { Label("Add account", systemImage: "plus") }

                Spacer()
            }

            if let msg = store.lastActionMessage {
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .sheet(isPresented: $showAddSheet) {
            AddClaudeAccountSheet()
        }
        .alert("Remove account?",
               isPresented: Binding(get: { pendingRemoval != nil },
                                    set: { if !$0 { pendingRemoval = nil } })) {
            Button("Remove", role: .destructive) {
                if let a = pendingRemoval {
                    Task { _ = await store.removeClaudeAccount(idOrLabel: a.id) }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Remove “\(pendingRemoval?.shownLabel ?? "")” from AIGauge? This only forgets the account here; your Claude login is untouched.")
        }
    }

    private var lastUpdatedString: String {
        guard store.claudeLastUpdated > .distantPast else { return "never" }
        let f = RelativeDateTimeFormatter()
        return "updated " + f.localizedString(for: store.claudeLastUpdated, relativeTo: Date())
    }
}

/// A compact, draggable row of colored percent chips — the unified tray order
/// of every Claude account plus Codex. Drag a chip to set the left-to-right
/// order used in the menu-bar status item.
struct ReorderStrip: View {
    let items: [TrayItem]
    @ObservedObject private var store = UsageStore.shared
    @State private var dragging: String?     // id of the chip being dragged

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    chip(item)
                        .onDrag {
                            dragging = item.id
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(of: [.text],
                                delegate: ChipDropDelegate(item: item.id,
                                                           items: items,
                                                           dragging: $dragging,
                                                           store: store))
                }
                Spacer(minLength: 0)
            }
            Text("Drag to set the order Claude accounts and Codex appear in the tray.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func chip(_ item: TrayItem) -> some View {
        let pct = item.hasError ? "!"
            : (item.percent.map { String(format: "%.0f%%", $0) } ?? "…")
        return HStack(spacing: 5) {
            Circle().fill(Color(hex: item.colorHex)).frame(width: 8, height: 8)
            Text(item.label).font(.caption)
            Text(pct).font(.caption).monospacedDigit().foregroundColor(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .opacity(dragging == item.id ? 0.4 : 1)
        .help(item.label)
    }
}

/// Live-reorders the strip as a chip is dragged over a neighbour, persisting
/// the new tray order through the store.
struct ChipDropDelegate: DropDelegate {
    let item: String                 // id of the chip being dropped onto
    let items: [TrayItem]
    @Binding var dragging: String?
    let store: UsageStore

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != item,
              let fromIdx = items.firstIndex(where: { $0.id == from }),
              let toIdx = items.firstIndex(where: { $0.id == item }) else { return }
        var ids = items.map(\.id)
        ids.move(fromOffsets: IndexSet(integer: fromIdx),
                 toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        store.reorderTrayItems(ids)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// One account's header + windows + per-account refresh/remove.
struct AccountSection: View {
    let account: ClaudeAccountSnapshot
    let onRefresh: () -> Void
    let onRemove: (() -> Void)?

    @ObservedObject private var store = UsageStore.shared
    /// Live-edited alias text; committed to the store on submit / focus loss.
    @State private var aliasDraft: String = ""
    @FocusState private var aliasFocused: Bool

    /// Two-way binding between the account color and the store.
    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: account.colorHex) },
            set: { store.setClaudeColor($0.hexString, forAccountId: account.id) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28)
                    .help("Color used for this account in the tray and menu")

                TextField("Account name", text: $aliasDraft)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($aliasFocused)
                    .onSubmit { commitAlias() }
                    .frame(maxWidth: 160)

                Spacer()

                Text(account.sourceDisplayName)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                if let onRemove = onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Remove this account from AIGauge")
                }
            }
            .onAppear { aliasDraft = account.shownLabel }
            .onChange(of: account.shownLabel) { aliasDraft = $0 }
            .onChange(of: aliasFocused) { focused in
                if !focused { commitAlias() }   // commit when the field loses focus
            }

            if let err = account.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red).font(.caption)
            } else if account.windows.isEmpty {
                Text("No data yet.").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(account.windows) { w in WindowRow(window: w) }
            }

            HStack {
                Button(action: onRefresh) {
                    Label("Refresh window (~2 tokens)", systemImage: "bolt.fill")
                }
                .controlSize(.small)
                .help("Sends a tiny private prompt from this account to start its 5-hour quota window.")
                Spacer()
            }

            AutoRefreshRow(serviceKey: account.id)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Persist the edited alias (no-op for the legacy "single" account).
    private func commitAlias() {
        guard account.id != "single" else { return }
        store.setClaudeAlias(aliasDraft, forAccountId: account.id)
    }
}

/// Sheet to add an account by choosing a cookie source.
struct AddClaudeAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store = UsageStore.shared

    @State private var label = ""
    @State private var sources: [ClaudeSourceJSON] = []
    @State private var selectedSource = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Claude account").font(.title3).bold()
            Text("Pick where this account is logged in. AIGauge reads its claude.ai cookies from that source (Keychain prompt on first use).")
                .font(.caption).foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Label").font(.subheadline).foregroundColor(.secondary)
                TextField("Team / Personal / …", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Cookie source").font(.subheadline).foregroundColor(.secondary)
                if sources.isEmpty {
                    Text("Detecting sources…").font(.caption).foregroundColor(.secondary)
                } else {
                    Picker("", selection: $selectedSource) {
                        ForEach(sources) { s in
                            Text(s.available ? s.name : "\(s.name) (not detected)")
                                .tag(s.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                }
            }

            if let errorText = errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red).font(.caption)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await add() }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) }
                    else { Text("Add") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty
                          || selectedSource.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 420, height: 340)
        .task {
            sources = await store.listClaudeSources()
            // Default to the first available source.
            selectedSource = sources.first(where: { $0.available })?.id
                ?? sources.first?.id ?? ""
        }
    }

    private func add() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        let err = await store.addClaudeAccount(
            label: label.trimmingCharacters(in: .whitespaces), sourceId: selectedSource)
        if let err = err {
            errorText = err
        } else {
            dismiss()
        }
    }
}

/// Per-service scheduled auto-refresh control: a checkbox, the label
/// "Auto-refresh at", and a small HH:mm text field. When enabled, the
/// AutoRefreshScheduler sends the token-spending "Refresh window" for this
/// service once a day at the given time (catching up on wake if the Mac was
/// asleep). `serviceKey` is a Claude account id or `AppSettings.codexOrderKey`.
struct AutoRefreshRow: View {
    let serviceKey: String

    @ObservedObject private var settings = AppSettings.shared
    @State private var timeDraft = ""
    @State private var invalid = false

    private var cfg: AutoRefreshConfig { settings.autoRefreshConfig(for: serviceKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: enabledBinding) {
                    Text("Auto-refresh at")
                }
                .toggleStyle(.checkbox)
                .fixedSize()

                TextField("HH:mm, HH:mm, …", text: $timeDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(!cfg.enabled)
                    .onSubmit { commit() }
                    .onChange(of: timeDraft) { _ in invalid = false }
            }
            hint
        }
        .font(.caption)
        .onAppear { timeDraft = cfg.time }
        .onChange(of: cfg.time) { timeDraft = $0 }
    }

    @ViewBuilder
    private var hint: some View {
        if invalid {
            Text("Use 24-hour HH:mm times, separated by commas — e.g. 06:00, 14:00")
                .foregroundColor(.red)
        } else if cfg.enabled, AutoRefreshScheduler.parseTimes(cfg.time) != nil {
            Text("runs daily at \(cfg.time) · fires on wake if any were missed")
                .foregroundColor(.secondary)
        } else {
            Text("24-hour; use commas for multiple times — e.g. 06:00, 10:00, 14:00")
                .foregroundColor(.secondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { cfg.enabled },
            set: { on in
                settings.updateAutoRefreshConfig(for: serviceKey) { $0.enabled = on }
                if on {
                    commit()   // validate/normalise whatever is currently typed
                    AutoRefreshScheduler.shared.seedBaseline(for: serviceKey)
                }
            })
    }

    /// Validate + normalise the typed times (zero-pad, sort, de-dupe) and persist.
    /// Blank clears the schedule; any malformed entry flags `invalid` and nothing
    /// is saved.
    private func commit() {
        let trimmed = timeDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            settings.updateAutoRefreshConfig(for: serviceKey) { $0.time = "" }
            invalid = false
            return
        }
        guard let list = AutoRefreshScheduler.parseTimes(trimmed) else {
            invalid = true
            return
        }
        let norm = Set(list.map { $0.hour * 60 + $0.minute })
            .sorted()
            .map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
            .joined(separator: ", ")
        timeDraft = norm
        invalid = false
        settings.updateAutoRefreshConfig(for: serviceKey) { $0.time = norm }
        if cfg.enabled { AutoRefreshScheduler.shared.seedBaseline(for: serviceKey) }
    }
}

struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.callout).bold()
                Spacer()
                Text(String(format: "%.1f%%", window.percent))
                    .font(.callout).monospacedDigit()
                Text("• resets in \(window.resetText)")
                    .font(.caption).foregroundColor(.secondary)
            }
            ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                .tint(color(for: window.percent))
        }
        .padding(.vertical, 4)
    }

    private func color(for pct: Double) -> Color {
        switch pct {
        case ..<50:  return .green
        case ..<80:  return .yellow
        default:     return .red
        }
    }
}
