import JavaScriptCore
import XCTest
@testable import AIGauge

final class OpenAIBillingTests: XCTestCase {
    func testMenuRefreshInterval() {
        let first = ContinuousClock.now
        XCTAssertTrue(OpenAIBilling.canRefresh(since: nil, at: first))
        XCTAssertFalse(OpenAIBilling.canRefresh(since: first, at: first + .milliseconds(9999)))
        XCTAssertTrue(OpenAIBilling.canRefresh(since: first, at: first + .seconds(10)))
    }

    func testReadsLocalizedBalanceAfterDashboardRenders() throws {
        let page = try fixture()
        page.evaluateScript(OpenAIBilling.balanceScript)
        XCTAssertEqual(page.evaluateScript("amounts").toArray() as? [String], [])

        page.evaluateScript(#"render('42,17\u00a0US$', 'Next expiration: 12,34 US$')"#)
        page.evaluateScript(#"render('42,17\u00a0US$', 'Next expiration: 12,34 US$')"#)
        page.evaluateScript("render('$0.00', '')")
        page.evaluateScript("render('-US$1.25', '')")
        XCTAssertEqual(page.evaluateScript("amounts").toArray() as? [String], ["42,17 US$", "$0.00", "-US$1.25"])
    }

    func testIgnoresAmbiguousBalancesAndAmountsOutsideBillingOverview() throws {
        let page = try fixture()
        page.evaluateScript(OpenAIBilling.balanceScript)
        page.evaluateScript("render('42,17 US$', '12,34 US$')")
        page.evaluateScript("location.pathname = '/usage'; render('$42.17', '')")
        XCTAssertEqual(page.evaluateScript("amounts").toArray() as? [String], [])
    }

    private func fixture() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        const amounts = [];
        const location = { origin: 'https://platform.openai.com', pathname: '/settings/organization/billing/overview' };
        const NodeFilter = { SHOW_TEXT: 4 };
        const root = {};
        const group = { innerText: '', parentElement: root };
        const parent = { innerText: 'API credit balance', parentElement: group, getClientRects: () => [1] };
        const label = { textContent: parent.innerText, parentElement: parent };
        const document = {
            body: root,
            querySelector: () => root,
            createTreeWalker: () => {
                let found = false;
                return { currentNode: label, nextNode: () => !found && (found = true) };
            }
        };
        let update;
        class MutationObserver {
            constructor(callback) { update = callback; }
            observe() {}
        }
        const webkit = { messageHandlers: { openAIBillingBalance: { postMessage: value => amounts.push(value) } } };
        function render(balance, footer) {
            group.innerText = [parent.innerText, balance, footer].join('\n');
            update();
        }
        """#)
        return context
    }
}
