import Foundation

enum MistralConnectionMethod: String, CaseIterable, Identifiable {
    case keychain, browser
    var id: String { rawValue }
    var label: String {
        self == .keychain ? "Keychain (recommended)" : "Browser session (advanced)"
    }
}

enum MistralAccessHelp {
    static func isFileAccessError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("browser cookie access denied by macos")
            || lower.contains("cannot read browser cookies. check file access permissions")
    }
}

/// Mirrors MistralGauge usage --json, keeping the GUI independent of browser auth.
struct MistralUsageJSON: Decodable {
    let observedAt: String?
    let api: Allowance?
    let vibe: Allowance?

    struct Allowance: Decodable {
        let usedPercent: Double
        let total: Double
        let used: Double
        let remaining: Double
        let currency: String
        let resetsAt: String?
        let resetLabel: String?

        var isValid: Bool {
            usedPercent.isFinite && usedPercent >= 0 && total.isFinite && total > 0
                && used.isFinite && used >= 0 && remaining.isFinite && remaining >= 0
        }

        var detailText: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            func amount(_ value: Double) -> String {
                formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
            }
            return "\(amount(used)) / \(amount(total)) used · \(amount(remaining)) remaining"
        }
    }
}

extension UsageSnapshot {
    static func fromMistral(_ json: MistralUsageJSON) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        for (label, allowance) in [("API/Studio", json.api), ("Vibe Code", json.vibe)] {
            if let allowance, allowance.isValid {
                windows.append(UsageWindow(label: label, percent: allowance.usedPercent,
                    resetText: allowance.resetLabel ?? "unknown", detailText: allowance.detailText))
            }
        }
        guard !windows.isEmpty else { return .failure("Mistral", "No included Mistral allowance returned.") }
        // Vibe is the coding allowance; API is the fallback for API-only accounts.
        let primary = windows.first(where: { $0.label == "Vibe Code" }) ?? windows[0]
        return UsageSnapshot(serviceName: "Mistral", windows: windows,
            primaryPercent: primary.percent,
            lastUpdated: json.observedAt.flatMap(parseCodexTimestamp) ?? Date(), error: nil)
    }
}
