import AutocompleteCore
import Foundation
import Prompting
import XCTest

final class RemoteCompletionGeneratorTests: XCTestCase {
    func testEndpointNormalizationAndValidation() throws {
        func url(_ base: String) throws -> String {
            try RemoteCompletionConfiguration.endpoint(forBaseURL: base).absoluteString
        }
        XCTAssertEqual(try url("https://api.openai.com/v1/"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(try url("https://api.deepseek.com"), "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(try url("http://127.0.0.1:8080/proxy/v1/chat/completions/"),
                       "http://127.0.0.1:8080/proxy/v1/chat/completions")
        XCTAssertThrowsError(try url("http://api.example.com"))
        XCTAssertThrowsError(try url("https://api.example.com/v1?key=in-url"))
        XCTAssertThrowsError(try url("https://user:secret@example.com"))
    }

    func testModelsOnTheSameAddressShareAnEndpoint() throws {
        let preset = try RemoteCompletionConfiguration(baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let edited = try RemoteCompletionConfiguration(
            baseURL: "https://API.DeepSeek.com/chat/completions/", model: "  alternate-model  "
        )
        XCTAssertEqual(preset.endpoint, edited.endpoint)
        XCTAssertEqual(edited.model, "alternate-model")
        XCTAssertNotEqual(preset, edited)
        XCTAssertNotEqual(
            try RemoteCompletionConfiguration.endpoint(forBaseURL: "https://api.deepseek.com/v1"),
            edited.endpoint
        )
    }

    func testOfficialOpenAIRequestAndCandidatePreserveFirstSpace() async throws {
        let client = try makeGenerator(base: "https://api.openai.com/v1", model: "openai-test")
        let candidates = try await client.completions(for: Self.request(), documentSnippets: ["Private document excerpt"])
        XCTAssertEqual(candidates.map(\.text), [" your consideration."])
    }

    func testDeepSeekRequestDisablesThinkingAndUsesFixedConnectionExample() async throws {
        let client = try makeGenerator(base: "https://api.deepseek.com", model: "deepseek-flash")
        try await client.testConnection()
    }

    func testDeepSeekSendsAtMostThreeExcerptsInTheExistingRequest() async throws {
        let client = try makeGenerator(base: "https://api.deepseek.com", model: "deepseek-memory-fixture")
        _ = try await client.completions(for: Self.request(),
                                         documentSnippets: [String(repeating: "甲", count: 190), "乙", "丙", "不应发送"])
    }

    func testErrorAndSentenceMiddleReturnNoCandidate() async throws {
        let client = try makeGenerator(base: "https://api.example.com", model: "bad-key-test")
        do {
            _ = try await client.completions(for: Self.request())
            XCTFail("Expected unauthorized response")
        } catch RemoteCompletionError.httpStatus(401) {
            // Expected.
        }
        var request = Self.request()
        request.context.afterCursor = " existing text"
        let candidates = try await client.completions(for: request)
        XCTAssertTrue(candidates.isEmpty)
    }

    private static func request() -> CompletionRequest {
        CompletionRequest(
            context: TextFieldContext(
                beforeCursor: String(repeating: "x", count: 820) + "Thank you for",
                target: AppTarget(bundleIdentifier: "test.editor", appName: "Test Editor")
            ),
            prompt: "A local prompt that must not be sent",
            mode: .prose
        )
    }

    private func makeGenerator(base: String, model: String) throws -> RemoteCompletionGenerator {
        let config = try RemoteCompletionConfiguration(baseURL: base, model: model)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubCompletionProtocol.self]
        return RemoteCompletionGenerator(configuration: config, apiKey: "fixture-key",
                                         session: URLSession(configuration: session))
    }
}

private final class StubCompletionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        guard let url = request.url, let host = url.host,
              let body = requestBody(),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: String]] else {
            client?.urlProtocol(self, didFailWithError: RemoteCompletionError.invalidResponse)
            return
        }
        let prefix = messages.last?["content"] ?? ""
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?["role"], "user")
        XCTAssertEqual(json["stream"] as? Bool, false)
        if host == "api.deepseek.com" {
            XCTAssertEqual(url.path, "/chat/completions")
            XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
            if json["model"] as? String == "deepseek-memory-fixture" {
                let lines = prefix.components(separatedBy: "\n")
                guard lines.count == 5 else {
                    client?.urlProtocol(self, didFailWithError: RemoteCompletionError.invalidResponse)
                    return
                }
                let excerpts = try? JSONDecoder().decode([String].self, from: Data(lines[1].utf8))
                XCTAssertEqual(excerpts, [String(repeating: "甲", count: 180), "乙", "丙"])
                XCTAssertEqual(lines[3], "Text at the cursor:")
                XCTAssertEqual(lines[4].count, 800)
                XCTAssertTrue(lines[4].hasSuffix("Thank you for"))
            } else {
                XCTAssertEqual(json["model"] as? String, "deepseek-flash")
                XCTAssertEqual(json["max_tokens"] as? Int, 24)
                XCTAssertEqual(prefix, "Thank you for")
            }
        } else if host == "api.openai.com" {
            XCTAssertEqual(url.path, "/v1/chat/completions")
            XCTAssertEqual(json["model"] as? String, "openai-test")
            XCTAssertNotNil(json["max_completion_tokens"] as? Int)
            XCTAssertNil(json["max_tokens"])
            XCTAssertNil(json["thinking"])
            XCTAssertEqual(prefix.count, 800)
            XCTAssertTrue(prefix.hasSuffix("Thank you for"))
        }
        let status = host == "api.example.com" ? 401 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"choices":[{"message":{"content":" your consideration."},"finish_reason":"stop"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
