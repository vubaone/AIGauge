import XCTest
import AppKit
@testable import AIGauge

final class BackendModelsTests: XCTestCase {
    func testWeeklyResponseMapsBankedResetsAndDisablesWindowRefresh() throws {
        let data = Data(#"""
        {
          "httpStatus": 200,
          "planType": "plus",
          "rateLimit": {
            "allowed": true,
            "primaryWindow": {
              "usedPercent": 7.5,
              "limitWindowSeconds": 604800,
              "resetAfterSeconds": 500000,
              "resetLabel": "5d 18h",
              "window": "7d"
            }
          },
          "rateLimitResetCredits": {
            "availableCount": 3,
            "applicableAvailableCount": 0,
            "credits": [
              {
                "id": "later",
                "status": "available",
                "expiresAt": "2026-08-12T18:05:20.910003Z",
                "title": "Full reset"
              },
              {
                "id": "used",
                "status": "consumed",
                "expiresAt": "2026-07-20T00:00:00Z",
                "title": "Full reset"
              },
              {
                "id": "sooner",
                "status": "available",
                "expiresAt": "2026-07-27T00:05:16.750190Z",
                "title": "Full reset"
              }
            ]
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(CodexUsageJSON.self, from: data)
        let snapshot = UsageSnapshot.fromCodex(response)

        XCTAssertFalse(snapshot.supportsWindowRefresh)
        XCTAssertEqual(snapshot.availableResetCount, 3)
        XCTAssertEqual(snapshot.resetCredits.map(\.id), ["sooner", "later"])
        XCTAssertEqual(snapshot.windows.first?.label, "1 week")
    }

    func testLegacyFiveHourResponseEnablesWindowRefresh() throws {
        let data = Data(#"""
        {
          "rateLimit": {
            "primaryWindow": {
              "usedPercent": 1,
              "limitWindowSeconds": 18000,
              "resetLabel": "4 hr 59 min"
            }
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(CodexUsageJSON.self, from: data)
        let snapshot = UsageSnapshot.fromCodex(response)

        XCTAssertTrue(snapshot.supportsWindowRefresh)
        XCTAssertEqual(snapshot.windows.first?.label, "5 hours")
    }

    func testCodexTimestampAcceptsFractionalAndStandardISO8601() {
        XCTAssertNotNil(parseCodexTimestamp("2026-07-27T00:05:16.750190Z"))
        XCTAssertNotNil(parseCodexTimestamp("2026-07-27T00:05:16Z"))
        XCTAssertNil(parseCodexTimestamp("not-a-date"))
    }

    @MainActor
    func testMenuErrorsPreserveShortTextAndLimitLongRenderedWidth() {
        let short = "Exit code 4. error: The request timed out."
        let maximumWidth = MenuBarController.maximumMenuErrorWidth
        XCTAssertEqual(MenuBarController.menuErrorTitle(short, maximumWidth: maximumWidth),
                       "  ⚠ \(short)")

        let long = "Exit code 4. " + String(repeating: "A very long backend error occurred. ", count: 20)
        let title = MenuBarController.menuErrorTitle(long, maximumWidth: maximumWidth)
        let width = (title as NSString).size(withAttributes: [
            .font: NSFont.menuFont(ofSize: 0)
        ]).width

        XCTAssertLessThanOrEqual(width, maximumWidth)
        XCTAssertTrue(title.hasSuffix("…"))
    }
}
