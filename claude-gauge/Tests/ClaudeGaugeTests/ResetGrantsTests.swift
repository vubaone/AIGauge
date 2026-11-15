import XCTest
@testable import ClaudeGauge

final class ResetGrantsTests: XCTestCase {
    func testAvailableGrantsAreEmittedInUsageJSON() throws {
        let data = Data(#"""
        {
          "five_hour": {"utilization": 42, "resets_at": "2099-01-01T00:00:00Z"},
          "cedar_ember": {
            "eligible": true,
            "grants": [
              {"id":"weekly","label":"Explore Opus","resets_total":3,"resets_left":2,
               "ends_at":"2099-01-02T00:00:00.123Z","clears":["seven_day"],"paused":false},
              {"id":"weekly","resets_left":2,"ends_at":"2099-01-02T00:00:00Z"},
              {"id":"expired","resets_left":1,"ends_at":"2020-01-01T00:00:00Z"},
              {"id":"paused","resets_left":1,"ends_at":"2099-01-01T00:00:00Z","paused":true}
            ]
          }
        }
        """#.utf8)

        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        XCTAssertEqual(usage.cedarEmber?.availableGrants.map(\.id), ["weekly"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(CLI.usageJSON(usage).utf8)) as? [String: Any])
        let resets = try XCTUnwrap(object["limitResets"] as? [String: Any])
        XCTAssertEqual(resets["availableCount"] as? Int, 2)
        let grants = try XCTUnwrap(resets["grants"] as? [[String: Any]])
        XCTAssertEqual(grants.first?["label"] as? String, "Explore Opus")
        XCTAssertEqual(grants.first?["resetsLeft"] as? Int, 2)
    }

    func testOldUsageResponseDoesNotInventResets() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"five_hour":null}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(CLI.usageJSON(usage).utf8)) as? [String: Any])
        XCTAssertNil(object["limitResets"])
    }

    func testMalformedResetPayloadDoesNotHideUsageWindows() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(#"""
        {"five_hour":{"utilization":12,"resets_at":null},"cedar_ember":{"eligible":true,"grants":"unexpected"}}
        """#.utf8))
        XCTAssertEqual(usage.fiveHour?.utilization, 12)
        XCTAssertNil(usage.cedarEmber)
    }
}
