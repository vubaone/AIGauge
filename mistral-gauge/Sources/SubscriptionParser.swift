import Foundation

/// Decode billing budgets and legacy subscription-page props without inferring
/// limits from plan names, visible amounts, or bar widths.
enum SubscriptionParser {
    private struct Budget: Decodable {
        let usage_percentage: Double
        let initial_budget: Double
        let currency: String
        let reset_at: String?
    }

    /// The official Vibe CLI's public billing endpoint returns these budgets
    /// directly, with the same monetary fields as the subscription-page props.
    static func parseBudgetJSON(_ data: Data) throws -> MistralUsageResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MistralError.invalidResponse
        }
        let response = effectiveUsage(object)
        guard response.api != nil || response.vibe != nil else { throw MistralError.missingAllowance }
        return response
    }

    static func parseBrowserBudgetJSON(_ data: Data) throws -> MistralUsageResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let result = object["result"] as? [String: Any],
              let data = result["data"] as? [String: Any],
              let budgets = data["json"] as? [String: Any] else {
            throw MistralError.invalidResponse
        }
        guard let vibe = allowance(budgets["vibe_budget"]) else { throw MistralError.missingAllowance }
        return MistralUsageResponse(api: nil, vibe: vibe)
    }

    static func parse(html: String) throws -> MistralUsageResponse {
        // Decode each JS argument as JSON, including escaped quotes/newlines.
        let expression = try NSRegularExpression(
            pattern: #"self\.__next_f\.push\(\s*(\[\s*1\s*,\s*"(?:\\.|[^"\\])*"\s*\])\s*\)"#)
        let ns = html as NSString
        let chunks = expression.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> String? in
                let argument = Data(ns.substring(with: match.range(at: 1)).utf8)
                return (try? JSONSerialization.jsonObject(with: argument) as? [Any])?[1] as? String
            }
        let bytes = Array(chunks.joined().utf8)
        var offset = 0
        var candidates: [MistralUsageResponse] = []

        while offset < bytes.count {
            let end = bytes[offset...].firstIndex(of: 10) ?? bytes.count
            guard let colon = bytes[offset..<end].firstIndex(of: 58), colon > offset,
                  bytes[offset..<colon].allSatisfy({ hex($0) }) else {
                offset = min(end + 1, bytes.count)
                continue
            }
            let payload = colon + 1
            // Text/binary records are byte-counted, not newline-delimited. Skip
            // their entire payload so embedded JSON cannot masquerade as props.
            if payload < end, "TAOoUSsLlGgMmV".utf8.contains(bytes[payload]) {
                guard let comma = bytes[payload..<end].firstIndex(of: 44), comma > payload + 1,
                      bytes[(payload + 1)..<comma].allSatisfy({ hex($0) }),
                      let length = Int(String(decoding: bytes[(payload + 1)..<comma], as: UTF8.self), radix: 16),
                      length <= bytes.count - comma - 1 else { throw MistralError.invalidResponse }
                offset = comma + 1 + length
                continue
            }
            if payload < end, bytes[payload] == 91 || bytes[payload] == 123 {
                guard let object = try? JSONSerialization.jsonObject(with: Data(bytes[payload..<end])) else {
                    throw MistralError.invalidResponse
                }
                collect(object, depth: 0, into: &candidates)
            }
            offset = min(end + 1, bytes.count)
        }
        guard let first = candidates.first else { throw MistralError.missingAllowance }
        guard candidates.allSatisfy({ $0 == first }) else { throw MistralError.ambiguousAllowance }
        return MistralUsageResponse(api: first.vibe == nil ? first.api : nil, vibe: first.vibe)
    }

    private static func hex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func collect(_ node: Any, depth: Int, into candidates: inout [MistralUsageResponse]) {
        guard depth < 64 else { return }
        if let object = node as? [String: Any] {
            if let budgets = object["budget"] as? [String: Any] {
                let result = MistralUsageResponse(api: allowance(budgets["api_budget"]),
                                                  vibe: allowance(budgets["vibe_budget"]))
                if result.api != nil || result.vibe != nil { candidates.append(result) }
            }
            for value in object.values { collect(value, depth: depth + 1, into: &candidates) }
        } else if let list = node as? [Any] {
            for value in list { collect(value, depth: depth + 1, into: &candidates) }
        }
    }

    private static func effectiveUsage(_ budgets: [String: Any]) -> MistralUsageResponse {
        let vibe = allowance(budgets["vibe_budget"])
        // The dashboard uses the shared Vibe/Studio budget, not the legacy API
        // sibling. Retain an API-only fallback for native API-key accounts.
        return MistralUsageResponse(api: vibe == nil ? allowance(budgets["api_budget"]) : nil, vibe: vibe)
    }

    private static func allowance(_ object: Any?) -> MistralAllowance? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let budget = try? JSONDecoder().decode(Budget.self, from: data) else { return nil }
        let currency = budget.currency.uppercased()
        guard budget.usage_percentage.isFinite, budget.usage_percentage >= 0,
              budget.initial_budget.isFinite, budget.initial_budget > 0,
              currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        let allowance = MistralAllowance(usedPercent: budget.usage_percentage,
                                        total: budget.initial_budget, currency: currency,
                                        resetsAt: budget.reset_at)
        return allowance.used.isFinite ? allowance : nil
    }
}
