import XCTest
import Foundation
@testable import NotchBrowser

final class NotionConnectionTests: XCTestCase {
    private func response(_ request: URLRequest, status: Int, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                          httpVersion: nil, headerFields: nil)!)
    }

    func testAgentAccessRequiresValidTokenAndAgentEndpoint() async throws {
        let api = NotionConnectionAPI(token: "secret", fetch: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            switch request.url?.path {
            case "/v1/users/me": return self.response(request, status: 200, body: #"{"object":"user","id":"user-1"}"#)
            case "/v1/agents": return self.response(request, status: 200, body: #"{"results":[]}"#)
            default: throw NotionAPIError.invalidResponse
            }
        })
        let result = try await api.verify()
        XCTAssertTrue(result.agentAccess)
    }

    func testValidTokenWithoutAgentAccessCannotEnableAgents() async throws {
        let api = NotionConnectionAPI(token: "secret", fetch: { request in
            switch request.url?.path {
            case "/v1/users/me": return self.response(request, status: 200, body: #"{"object":"user","id":"user-1"}"#)
            case "/v1/agents": return self.response(request, status: 403, body: #"{"message":"forbidden"}"#)
            default: throw NotionAPIError.invalidResponse
            }
        })
        let result = try await api.verify()
        XCTAssertFalse(result.agentAccess)
        XCTAssertNotNil(result.agentError)
    }

    func testInvalidTokenIsRejected() async {
        let api = NotionConnectionAPI(token: "bad", fetch: { request in
            self.response(request, status: 401, body: #"{"message":"unauthorized"}"#)
        })
        do {
            _ = try await api.verify()
            XCTFail("Invalid token must fail validation")
        } catch NotionAPIError.server(let code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
