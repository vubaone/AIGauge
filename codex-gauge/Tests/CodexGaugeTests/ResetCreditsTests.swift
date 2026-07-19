import XCTest
@testable import CodexGauge

final class ResetCreditsTests: XCTestCase {
    func testUsageSummaryDecodesAndWeeklyWindowDisablesLegacyRefresh() throws {
        let data = Data(#"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "primary_window": {
              "used_percent": 12.5,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 500000
            }
          },
          "rate_limit_reset_credits": {
            "available_count": 3,
            "applicable_available_count": 0
          }
        }
        """#.utf8)

        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

        XCTAssertEqual(usage.rateLimitResetCredits?.availableCount, 3)
        XCTAssertEqual(usage.rateLimitResetCredits?.applicableAvailableCount, 0)
        XCTAssertFalse(usage.supportsLegacyWindowRefresh)
    }

    func testEitherFiveHourWindowEnablesLegacyRefresh() throws {
        let data = Data(#"""
        {
          "rate_limit": {
            "primary_window": { "limit_window_seconds": 604800 },
            "secondary_window": { "limit_window_seconds": 18000 }
          }
        }
        """#.utf8)

        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

        XCTAssertTrue(usage.supportsLegacyWindowRefresh)
    }

    func testDetailedCreditsAppearInMachineReadableOutput() throws {
        let usageData = Data(#"""
        {
          "plan_type": "plus",
          "rate_limit_reset_credits": {
            "available_count": 3,
            "applicable_available_count": 1
          }
        }
        """#.utf8)
        let detailsData = Data(#"""
        {
          "available_count": 3,
          "credits": [{
            "id": "reset-1",
            "reset_type": "full_reset",
            "status": "available",
            "granted_at": "2026-07-18T20:22:26.924730Z",
            "expires_at": "2026-07-31T20:22:26.924730Z",
            "title": "Full reset"
          }]
        }
        """#.utf8)
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: usageData)
        let details = try JSONDecoder().decode(RateLimitResetCreditsResponse.self, from: detailsData)

        let output = CLI.usageJSON(
            usage,
            status: 200,
            headers: [:],
            resetCredits: details,
            raw: nil,
            src: "test")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let resets = try XCTUnwrap(object["rateLimitResetCredits"] as? [String: Any])
        let credits = try XCTUnwrap(resets["credits"] as? [[String: Any]])

        XCTAssertEqual(resets["availableCount"] as? Int, 3)
        XCTAssertEqual(resets["applicableAvailableCount"] as? Int, 1)
        XCTAssertEqual(credits.first?["expiresAt"] as? String,
                       "2026-07-31T20:22:26.924730Z")
        XCTAssertEqual(credits.first?["status"] as? String, "available")
    }
}
