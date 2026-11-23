import Foundation

/// Read-only billing API, with an explicit browser-session alternative.
/// Redirects are refused so neither keys nor cookies leave their original host.
final class MistralAPIClient: NSObject, URLSessionTaskDelegate {
    static let browserBudgetURL = URL(string: "https://admin.mistral.ai/api/local-trpc/billing.budget?input=%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D")!
    static let budgetURL = URL(string: "https://api.mistral.ai/v1/billing/budget")!
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    func fetchUsage(cookieHeader: String) async throws -> (usage: MistralUsageResponse, status: Int) {
        let cookie = try CredentialExtractor.validatedHeader(cookieHeader)
        var request = URLRequest(url: Self.browserBudgetURL)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("nextjs-react", forHTTPHeaderField: "x-trpc-source")
        let (data, status) = try await fetch(request, billing: false)
        return (try SubscriptionParser.parseBrowserBudgetJSON(data), status)
    }

    func fetchUsage(apiKey: String) async throws -> (usage: MistralUsageResponse, status: Int) {
        let key = try VibeCredentialStore.validatedKey(apiKey)
        var request = URLRequest(url: Self.budgetURL)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await fetch(request, billing: true)
        return (try SubscriptionParser.parseBudgetJSON(data), status)
    }

    private func fetch(_ request: URLRequest, billing: Bool) async throws -> (Data, Int) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MistralError.invalidResponse }
        guard http.statusCode == 200 else {
            throw billing ? MistralError.billingHTTP(http.statusCode) : MistralError.http(http.statusCode)
        }
        guard http.url?.host == request.url?.host, http.url?.scheme == "https",
              data.count <= 8 * 1024 * 1024 else { throw MistralError.invalidResponse }
        return (data, http.statusCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
