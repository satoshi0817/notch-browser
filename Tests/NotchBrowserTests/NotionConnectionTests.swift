import XCTest
import Foundation
@testable import NotchBrowser

final class NotionConnectionTests: XCTestCase {
    private func response(_ request: URLRequest, status: Int, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                          httpVersion: nil, headerFields: nil)!)
    }

    func testValidTokenDoesNotRequireAgentListAccess() async throws {
        var paths: [String] = []
        let api = NotionConnectionAPI(token: "secret", fetch: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["page_size"] as? Int, 1)
            paths.append(request.url!.path)
            if request.url?.path == "/v1/search" {
                return self.response(request, status: 200, body: #"{"object":"list","results":[]}"#)
            }
            return self.response(request, status: 403, body: #"{"message":"Agent listing forbidden"}"#)
        })
        try await api.verify()
        XCTAssertEqual(paths, ["/v1/search"])
    }

    func testInvalidTokenIsRejected() async {
        let api = NotionConnectionAPI(token: "bad", fetch: { request in
            self.response(request, status: 401, body: #"{"message":"unauthorized"}"#)
        })
        do {
            try await api.verify()
            XCTFail("Invalid token must fail validation")
        } catch NotionAPIError.server(let code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedSearchResponseIsRejected() async {
        let api = NotionConnectionAPI(token: "secret", fetch: { request in
            self.response(request, status: 200, body: #"{"object":"list"}"#)
        })
        do {
            try await api.verify()
            XCTFail("Malformed response must fail validation")
        } catch NotionAPIError.invalidResponse {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
