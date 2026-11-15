import XCTest
import AppKit
@testable import AIGauge

final class BackendModelsTests: XCTestCase {
    func testHelperReceivesSecretThroughStdinAndEOFWithoutAnArgument() async throws {
        let input = Data("synthetic-key-for-pipe-test".utf8)
        let output = try await BackendRunner.runProcess(executable: URL(fileURLWithPath: "/bin/cat"),
                                                        args: [], standardInput: input)
        XCTAssertEqual(output, input)
    }

    func testMistralConnectionMethodsSeparateKeychainFromBrowserPermissions() {
        XCTAssertEqual(MistralConnectionMethod(rawValue: "keychain"), .keychain)
        XCTAssertEqual(MistralConnectionMethod(rawValue: "browser"), .browser)
        XCTAssertTrue(MistralConnectionMethod.keychain.label.contains("recommended"))
    }

    func testMistralFileAccessHelpSurvivesCLIErrorTruncationAndRecognizesOlderHelper() {
        let message = "error: Browser cookie access denied by macOS. Grant Full Disk Access to AIGauge in System Settings → Privacy & Security, then quit and reopen AIGauge. For the standalone CLI, authorize your terminal app. Keychain access is separate."
        let wrapped = BackendRunner.RunError.nonZeroExit(code: 3, stderr: message).localizedDescription
        XCTAssertTrue(MistralAccessHelp.isFileAccessError(wrapped))
        XCTAssertTrue(MistralAccessHelp.isFileAccessError("Exit code 3. error: Cannot read browser cookies. Check file access permissions for MistralGauge."))
        XCTAssertFalse(MistralAccessHelp.isFileAccessError("Cannot access Microsoft Edge Safe Storage (Keychain -25308)."))
        XCTAssertFalse(MistralAccessHelp.isFileAccessError("HTTP 403: Mistral session expired or access blocked."))
        XCTAssertFalse(MistralAccessHelp.isFileAccessError("Browser cookie database is busy."))
    }

    func testMistralMapsBothMonthlyAllowancesAndUsesVibeInTray() throws {
        let data = Data(#"""
        {"httpStatus":200,"source":"edge:Default","observedAt":"2026-11-15T00:00:00Z",
         "api":{"usedPercent":0,"total":30,"used":0,"remaining":30,"currency":"USD","resetLabel":"16 days"},
         "vibe":{"usedPercent":64,"total":75,"used":48.0,"remaining":27.0,"currency":"USD",
                 "resetsAt":"2026-12-01T00:00:00Z","resetLabel":"16 days"}}
        """#.utf8)
        let json = try JSONDecoder().decode(MistralUsageJSON.self, from: data)
        let snapshot = UsageSnapshot.fromMistral(json)
        XCTAssertEqual(snapshot.windows.map(\.label), ["API/Studio", "Vibe Code"])
        XCTAssertEqual(snapshot.windows.map(\.percent), [0, 64])
        XCTAssertEqual(snapshot.primaryPercent, 64)
        XCTAssertEqual(snapshot.lastUpdated, parseCodexTimestamp("2026-11-15T00:00:00Z"))
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        XCTAssertTrue(snapshot.windows[1].detailText?.contains("48\(decimalSeparator)00") == true)
        XCTAssertFalse(snapshot.supportsWindowRefresh)
        XCTAssertNil(snapshot.availableResetCount)
    }

    func testMistralMissingQuotaFailsAndAPIOnlyUsesAPI() throws {
        let empty = try JSONDecoder().decode(MistralUsageJSON.self, from: Data("{}".utf8))
        XCTAssertNotNil(UsageSnapshot.fromMistral(empty).error)
        XCTAssertNil(UsageSnapshot.fromMistral(empty).primaryPercent)
        let apiOnly = Data(#"{"api":{"usedPercent":12,"total":100,"used":12,"remaining":88,"currency":"EUR"}}"#.utf8)
        let snapshot = UsageSnapshot.fromMistral(try JSONDecoder().decode(MistralUsageJSON.self, from: apiOnly))
        XCTAssertEqual(snapshot.primaryPercent, 12)
        XCTAssertEqual(snapshot.windows.first?.resetText, "unknown")
    }

    func testProviderSelectionPreservesExistingChoicesWhenMistralIsToggled() {
        XCTAssertEqual(BackendSelection(rawValue: "both"), .both)
        XCTAssertFalse(BackendSelection.both.includesMistral)
        XCTAssertTrue(BackendSelection.all.includesMistral)
        for selection in BackendSelection.allCases {
            let enabled = selection.withMistral(true)
            XCTAssertTrue(enabled.includesMistral)
            XCTAssertEqual(enabled.includesClaude, selection.includesClaude)
            XCTAssertEqual(enabled.includesCodex, selection.includesCodex)
            let disabled = selection.withMistral(false)
            XCTAssertFalse(disabled.includesMistral)
            XCTAssertEqual(disabled.includesClaude, selection.includesClaude)
            XCTAssertEqual(disabled.includesCodex, selection.includesCodex)
        }
    }

    func testClaudeAccountMapsAvailableResets() throws {
        let data = Data(#"""
        {
          "accountId": "personal",
          "label": "Personal",
          "source": "claude-desktop",
          "usage": {
            "fiveHour": {"utilization": 42, "resetsAt": "2099-01-01T00:00:00Z"},
            "limitResets": {
              "availableCount": 2,
              "grants": [{"id":"weekly","label":"Explore Opus","resetsLeft":2,
                          "endsAt":"2099-01-02T00:00:00.123Z","clears":["seven_day"]}]
            }
          }
        }
        """#.utf8)
        let response = try JSONDecoder().decode(ClaudeAccountUsageJSON.self, from: data)
        let account = ClaudeAccountSnapshot.from(response)
        XCTAssertEqual(account.availableResetCount, 2)
        XCTAssertEqual(account.resetCredits.first?.title, "Explore Opus")
        XCTAssertEqual(account.resetCredits.first?.remainingCount, 2)
        XCTAssertNotNil(account.resetCredits.first?.expirationDate)
    }

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
        let lines = title.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, MenuBarController.maximumMenuErrorLines)
        for line in lines {
            XCTAssertLessThanOrEqual(Self.renderedWidth(line), maximumWidth)
        }
        XCTAssertTrue(title.hasSuffix("…"))
    }

    /// An expired-token response is a single unbroken JSON blob: it has to wrap
    /// across the allowed lines rather than lose everything after the first.
    @MainActor
    func testJSONErrorWrapsAcrossLinesWithoutSpaces() {
        let json = #"Exit code 4. error: {"type":"error","error":{"type":"authentication_error","message":"OAuth authentication is currently not supported."}}"#
        let maximumWidth = MenuBarController.maximumMenuErrorWidth
        let title = MenuBarController.menuErrorTitle(json, maximumWidth: maximumWidth)
        let lines = title.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertLessThanOrEqual(Self.renderedWidth(line), maximumWidth)
        }
        // Far more of the body survives than a single truncated line would show.
        XCTAssertTrue(title.contains("authentication_error"))
    }

    /// Text that needs two lines gets two — no ellipsis, nothing dropped.
    @MainActor
    func testMediumErrorWrapsWithoutTruncating() {
        let medium = "Exit code 4. error: HTTP error: 401 — the saved session cookie is no longer valid."
        let title = MenuBarController.menuErrorTitle(
            medium, maximumWidth: MenuBarController.maximumMenuErrorWidth)
        let lines = title.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(title.contains("…"))
        XCTAssertTrue(title.hasSuffix("no longer valid."))
    }

    @MainActor
    func testLongResetLabelKeepsMenuNarrowAndExpiryVisible() {
        let reset = UsageResetCredit(
            id: "claude-grant",
            title: "Claude Opus 5.5 launch: one usage-limit reset for Team members",
            status: nil, grantedAt: nil, expiresAt: "2026-10-22T00:00:00Z")
        let maximumWidth = MenuBarController.maximumMenuResetWidth
        let title = MenuBarController.menuResetTitle(reset, maximumWidth: maximumWidth)
        let lines = title.components(separatedBy: "\n")

        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.last?.contains("expires") == true)
        for line in lines {
            XCTAssertLessThanOrEqual(Self.renderedWidth(line), maximumWidth)
        }
    }

    private static func renderedWidth(_ line: String) -> CGFloat {
        (line as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    }

    func testReloadTokenIsOnlyOfferedForCredentialFailures() {
        XCTAssertTrue(TokenSource.canReload(after: "HTTP error: 401"))
        XCTAssertTrue(TokenSource.canReload(after: #"{"type":"authentication_error"}"#))
        XCTAssertTrue(TokenSource.canReload(after: "no claude.ai cookies found"))
        XCTAssertFalse(TokenSource.canReload(after: "HTTP error: 429"))
        XCTAssertFalse(TokenSource.canReload(after: "Network connection lost"))
    }
}
