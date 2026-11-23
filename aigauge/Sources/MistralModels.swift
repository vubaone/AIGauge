import Foundation

enum MistralConnectionMethod: String, CaseIterable, Identifiable {
    case keychain, browser
    var id: String { rawValue }
    var label: String {
        self == .keychain ? "API key (Keychain)" : "Browser session (dashboard)"
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
        let selected: (label: String, allowance: MistralUsageJSON.Allowance)
        // Older helpers may return both budgets; prefer the shared allowance, not both.
        if let vibe = json.vibe, vibe.isValid {
            selected = ("Vibe & Studio", vibe)
        } else if let api = json.api, api.isValid {
            selected = ("API/Studio", api)
        } else {
            return .failure("Mistral", "No included Mistral allowance returned.")
        }
        let window = UsageWindow(label: selected.label, percent: selected.allowance.usedPercent,
            resetText: selected.allowance.resetLabel ?? "unknown", detailText: selected.allowance.detailText)
        return UsageSnapshot(serviceName: "Mistral", windows: [window],
            primaryPercent: window.percent,
            lastUpdated: json.observedAt.flatMap(parseCodexTimestamp) ?? Date(), error: nil)
    }
}
