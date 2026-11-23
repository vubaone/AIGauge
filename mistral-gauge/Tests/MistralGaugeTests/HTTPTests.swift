import XCTest
@testable import MistralGauge

private final class StubProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var request: URLRequest?
    static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPTests: XCTestCase {
    private let budgetJSON = #"{"vibe_budget":{"usage_percentage":64,"initial_budget":75,"currency":"USD"}}"#
    private func client(status: Int, html: String) -> MistralAPIClient {
        StubProtocol.status = status
        StubProtocol.body = Data(html.utf8)
        StubProtocol.request = nil
        StubProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return MistralAPIClient(configuration: configuration)
    }

    func testBrowserReadsDashboardJSONWithoutAPIKeyOrTrackingHeaders() async throws {
        let api = client(status: 200, html: "{\"result\":{\"data\":{\"json\":\(budgetJSON)}}}")
        let response = try await api.fetchUsage(cookieHeader: "ory_session_test=do-not-log")
        XCTAssertEqual(response.usage.vibe?.used, 48.0)
        let request = try XCTUnwrap(StubProtocol.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, MistralAPIClient.browserBudgetURL)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/local-trpc/billing.budget")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "input" })?.value,
                       #"{"json":null,"meta":{"values":["undefined"],"v":1}}"#)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-trpc-source"), "nextjs-react")
        for header in ["Authorization", "baggage", "sentry-trace", "User-Agent", "sec-ch-ua"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header))
        }
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ory_session_test=do-not-log")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testAPIKeyReadsBillingWithoutBrowserCookies() async throws {
        let result = try await client(status: 200, html: budgetJSON).fetchUsage(apiKey: "fixture-key")
        XCTAssertEqual(result.usage.vibe?.used, 48.0)
        let request = try XCTUnwrap(StubProtocol.request)
        XCTAssertEqual(request.url, MistralAPIClient.budgetURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testAPIQuotaPermissionFailureDoesNotSuggestDiskAccessOrExposeKey() async {
        do {
            _ = try await client(status: 403, html: "sensitive-body").fetchUsage(apiKey: "fixture-secret")
            XCTFail("Expected quota permission failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("see_org_inference_usage"))
            XCTAssertFalse(error.localizedDescription.contains("Full Disk Access"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-body"))
        }
    }

    func testConnectOnlySavesKeyAfterSuccessfulQuotaRead() async throws {
        let credentials = MistralCredentials(value: .apiKey("fixture-key"), source: "stdin")
        var written: [String] = []
        let result = try await CLI.fetchUsage(credentials: credentials, saveKey: true,
            client: client(status: 200, html: budgetJSON), keyWriter: { written.append($0) })
        XCTAssertEqual(result.usage.vibe?.usedPercent, 64)
        XCTAssertEqual(written, ["fixture-key"])

        for (status, body) in [(401, ""), (403, ""), (200, "{}"), (200, "invalid")] {
            written = []
            do {
                _ = try await CLI.fetchUsage(credentials: credentials, saveKey: true,
                    client: client(status: status, html: body), keyWriter: { written.append($0) })
                XCTFail("Expected failed connection")
            } catch { XCTAssertTrue(written.isEmpty) }
        }
    }

    func testUsageNeverWritesCredentialsAndSaveFailureIsReported() async throws {
        let credentials = MistralCredentials(value: .apiKey("fixture-key"), source: "fixture")
        _ = try await CLI.fetchUsage(credentials: credentials, saveKey: false,
            client: client(status: 200, html: budgetJSON), keyWriter: { _ in XCTFail("usage must be read-only") })
        do {
            _ = try await CLI.fetchUsage(credentials: credentials, saveKey: true,
                client: client(status: 200, html: budgetJSON), keyWriter: { _ in
                    throw MistralError.credentials("Keychain write failed")
                })
            XCTFail("Connection cannot claim its key was saved")
        } catch { XCTAssertEqual(error.localizedDescription, "Keychain write failed") }
    }

    func testHTTPFailuresAndLoginHTMLNeverSucceedWithZero() async {
        for status in [302, 401, 403, 429, 500] {
            let api = client(status: status, html: "private billing data should not appear in error")
            do {
                _ = try await api.fetchUsage(cookieHeader: "ory_session_test=secret")
                XCTFail("Expected HTTP error")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(String(status)))
                XCTAssertFalse(error.localizedDescription.contains("private billing data"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        do {
            _ = try await client(status: 200, html: "<html>Sign in</html>")
                .fetchUsage(cookieHeader: "ory_session_test=secret")
            XCTFail("Login page must not decode to 0%")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid Mistral")) }
    }

    func testBrowserParseFailuresNeverFallBackToHTMLOrExposeBodies() async {
        let bodies = [
            budgetJSON,
            #"{"result":{"data":{"json":{}}}}"#,
            #"{"error":{"json":{"message":"fixture-sensitive-response"}}}"#,
            "<html>fixture-sensitive-response</html>"
        ]
        for body in bodies {
            do {
                _ = try await client(status: 200, html: body).fetchUsage(cookieHeader: "ory_session_test=fixture-session")
                XCTFail("Expected dashboard parse failure")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("fixture-sensitive-response"))
                XCTAssertFalse(error.localizedDescription.contains("fixture-session"))
            }
            XCTAssertEqual(StubProtocol.requestCount, 1)
            XCTAssertEqual(StubProtocol.request?.url, MistralAPIClient.browserBudgetURL)
        }
    }

    func testRedirectDelegateRefusesCredentialForwarding() {
        let api = MistralAPIClient()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let redirect = HTTPURLResponse(url: MistralAPIClient.browserBudgetURL, statusCode: 302,
                                       httpVersion: nil, headerFields: ["Location": "https://example.com/"])!
        var invoked = false
        api.urlSession(session, task: session.dataTask(with: MistralAPIClient.browserBudgetURL),
                       willPerformHTTPRedirection: redirect,
                       newRequest: URLRequest(url: URL(string: "https://example.com/")!)) { request in
            invoked = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(invoked)
    }
}
