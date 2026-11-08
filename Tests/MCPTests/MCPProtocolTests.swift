import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

struct MCPProtocolTests {
    @Test func modernDiscoveryAndStatelessRequests() async throws {
        let server = MCPServer(service: TestMonitor())
        let discover = try await response(server, "server/discover")
        #expect(discover["result"]?["resultType"] == "complete")
        #expect(discover["result"]?["supportedVersions"] == ["2026-07-28", "2025-11-25"])
        #expect(discover["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "procglint-mcp")
        #expect(discover["result"]?["capabilities"]?["tools"] == [:])
        #expect(try await response(server, "ping")["result"]?["resultType"] == "complete")
        #expect(try await call(server, "get_snapshot")["result"]?["isError"] == false)
        // Modern metadata authorizes only its own request, never subsequent legacy-shaped requests.
        #expect(try await response(server, "tools/list", modern: false)["error"]?["code"] == -32600)
    }

    @Test func legacyHandshake() async throws {
        let server = MCPServer(service: TestMonitor())
        let params: [String: JSONValue] = ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]
        let initialize = try await response(server, "initialize", params: params, modern: false)
        #expect(initialize["result"]?["protocolVersion"] == "2025-11-25")
        #expect(initialize["result"]?["serverInfo"]?["name"] == "procglint-mcp")
        #expect(initialize["result"]?["resultType"] == nil)
        #expect(try await response(server, "tools/list", modern: false)["error"]?["code"] == -32600)
        #expect(try await server.handle(line: request("notifications/initialized", id: nil, modern: false)) == nil)
        let listing = try await response(server, "tools/list", modern: false)
        #expect(listing["result"]?["tools"]?.elements?.count == 5)
        #expect(listing["result"]?["resultType"] == nil)
        let result = try await response(server, "tools/call", params: ["name": "get_snapshot"], modern: false)
        #expect(result["result"]?["structuredContent"]?["snapshot_id"] == "agent-a-1")
        #expect(result["result"]?["structured_content"] == nil)
        #expect(result["result"]?["isError"] == false)
        #expect(try await response(server, "server/discover")["result"]?["resultType"] == "complete")
    }

    @Test(arguments: ["1900-01-01", "2024-11-05", "2025-06-18", "2026-01-01"])
    func unsupportedVersions(version: String) async throws {
        let server = MCPServer(service: TestMonitor())
        var meta = try #require(modernMeta.object)
        meta[ModernAdapter.versionKey] = .string(version)
        let raw: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": ["_meta": .object(meta)]]
        let output = try #require(await server.handle(line: raw.text()))
        let error = try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(output.utf8))["error"]
        #expect(error?["code"] == -32022)
        #expect(error?["data"]?["requested"] == .string(version))
        #expect(error?["data"]?["supported"] == ["2026-07-28", "2025-11-25"])
        let legacy = try await response(server, "initialize", params: ["protocolVersion": .string(version)], modern: false)
        #expect(legacy["error"]?["code"] == -32022)
        #expect(legacy["error"]?["data"]?["supported"] == ["2026-07-28", "2025-11-25"])
    }

    @Test(arguments: ["io.modelcontextprotocol/clientInfo", "io.modelcontextprotocol/clientCapabilities"])
    func requiredModernMetadata(key: String) async throws {
        let server = MCPServer(service: TestMonitor())
        var meta = try #require(modernMeta.object)
        meta.removeValue(forKey: key)
        let raw: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": ["_meta": .object(meta)]]
        let output = try #require(await server.handle(line: raw.text()))
        #expect(try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(output.utf8))["error"]?["code"] == -32602)
    }

    @Test(arguments: ["{", "not json", "{\"id\":1,}", "[1,]", ""])
    func parseErrors(line: String) async throws {
        let server = MCPServer(service: TestMonitor())
        let result = try #require(await server.handle(line: line))
        let value = try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(result.utf8))
        #expect(value["error"]?["code"] == -32700)
        #expect(value["id"] == .null)
    }

    @Test(arguments: ["[]", "[{}]", "null", "1", "{}", "{\"jsonrpc\":\"1.0\",\"method\":\"ping\",\"id\":1}",
                      "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":true}",
                      "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":null}",
                      "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":1.5}"])
    func invalidRequests(line: String) async throws {
        let server = MCPServer(service: TestMonitor())
        let result = try #require(await server.handle(line: line))
        #expect(try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(result.utf8))["error"]?["code"] == -32600)
    }

    @Test func protocolErrorsAndNotifications() async throws {
        let server = MCPServer(service: TestMonitor())
        #expect(try await response(server, "unknown")["error"]?["code"] == -32601)
        #expect(try await response(server, "tools/call")["error"]?["code"] == -32602)
        #expect(try await call(server, "unknown")["error"]?["code"] == -32602)
        #expect(try await call(server, "get_process", [])["error"]?["code"] == -32602)
        #expect(try await response(server, "tools/list", params: ["cursor": "bad"])["error"]?["code"] == -32602)
        #expect(try await server.handle(line: request("unknown", id: nil)) == nil)
        #expect(try await server.handle(line: request("tools/call", params: ["name": "get_snapshot"], id: nil)) == nil)
        for params in [JSONValue.array([]), .null, "bad"] {
            let invalidParams: JSONValue = ["jsonrpc": "2.0", "id": "a", "method": "ping", "params": params]
            let output = try #require(await server.handle(line: invalidParams.text()))
            #expect(try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(output.utf8))["error"]?["code"] == -32602)
        }
    }

    @Test func strictJSONStillAcceptsCommaAndBracesInStrings() throws {
        let data = Data(#"{"message":",}","escaped":"a\",]"}"#.utf8)
        let parsed = try JSONValue.parse(data)
        #expect(parsed["message"] == ",}")
        #expect(parsed["escaped"] == .string("a\",]"))
    }

    @Test func invalidUTF8IsAParseError() async throws {
        let server = MCPServer(service: TestMonitor())
        let output = try #require(await server.handle(line: Data([0xFF])))
        #expect(try JSONValue.parse(Data(output.utf8))["error"]?["code"] == -32700)
    }

    @Test func inputAndOutputLimits() async throws {
        let service = TestMonitor()
        let server = MCPServer(service: service)
        let ping = try request("ping")
        let atLimit = ping + String(repeating: " ", count: MCPServer.maximumInputBytes - ping.utf8.count)
        let accepted = try #require(await server.handle(line: atLimit))
        #expect(try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(accepted.utf8))["result"] != nil)
        let rejected = try #require(await server.handle(line: atLimit + " "))
        #expect(try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(rejected.utf8))["error"]?["code"] == -32600)
        #expect(try await response(server, "ping")["result"] != nil)
        await service.configure(largeName: String(repeating: "x", count: MCPServer.maximumResponseBytes))
        let huge = try await call(server, "get_snapshot")
        #expect(huge["result"]?["isError"] == true)
        #expect(huge["result"]?["structuredContent"]?["error"]?["message"]?.string?.contains("page or limit") == true)
        #expect(try huge.text().utf8.count <= MCPServer.maximumResponseBytes)
        #expect(try await response(server, "ping")["result"] != nil)
    }

    @Test func concurrencyCancellationAndDuplicateIDs() async throws {
        let service = TestMonitor()
        await service.configure(blocked: true)
        let server = MCPServer(service: service)
        var tasks: [Task<String?, Never>] = []
        for number in 1 ... 4 {
            let line = try request("tools/call", params: ["name": "get_snapshot"], id: .number(.init(number)))
            await tasks.append(server.start(line: Data(line.utf8)))
        }
        await service.waitForCalls(4)
        let excess = try await call(server, "get_snapshot", id: 5)
        #expect(excess["error"]?["code"] == -32000)
        #expect(try await call(server, "get_snapshot", id: 1)["error"]?["code"] == -32600)
        #expect(await service.calls.count == 4)
        #expect(try await server.handle(line: request("notifications/cancelled", params: ["requestId": 1], id: nil)) == nil)
        let cancelled = try #require(await tasks[0].value)
        #expect(try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(cancelled.utf8))["error"]?["code"] == -32800)
        // Cancelling a missing request is harmless and doesn't cancel the other three.
        #expect(try await server.handle(line: request("notifications/cancelled", params: ["requestId": "missing"], id: nil)) == nil)
        service.clock.advance(by: 1_000_000_000)
        for task in tasks.dropFirst() {
            let output = try #require(await task.value)
            #expect(try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(output.utf8))["result"]?["isError"] == false)
        }
        #expect(try await response(server, "ping", id: 1)["result"] != nil)
    }

    @Test func rateLimitsAreIndependentAndRefillWithMonotonicTime() async throws {
        let clock = FakeClock()
        let server = MCPServer(service: TestMonitor(), flags: .init(permissions: .all), now: { clock.now })
        for _ in 0 ..< 20 {
            #expect(try await call(server, "get_snapshot")["result"]?["isError"] == false)
        }
        #expect(try await call(server, "get_snapshot")["result"]?["structuredContent"]?["error"]?["code"] == "rate_limited")
        for _ in 0 ..< 5 {
            #expect(try await call(server, "stop_observation", ["observation_id": "obs-a"])["result"]?["isError"] == false)
        }
        #expect(try await call(server, "stop_observation", ["observation_id": "obs-a"])["result"]?["structuredContent"]?["error"]?["code"] == "rate_limited")
        #expect(try await response(server, "ping")["result"] != nil)
        clock.advance(by: 100_000_000)
        #expect(try await call(server, "get_snapshot")["result"]?["isError"] == false)
        #expect(try await call(server, "get_snapshot")["result"]?["isError"] == true)
        #expect(try await call(server, "stop_observation", ["observation_id": "obs-a"])["result"]?["isError"] == true)
        clock.advance(by: 900_000_000)
        #expect(try await call(server, "stop_observation", ["observation_id": "obs-a"])["result"]?["isError"] == false)
    }

    @Test(arguments: ["a", "9007199254740993"])
    func preservesRequestIDs(id: String) async throws {
        let server = MCPServer(service: TestMonitor())
        #expect(try await response(server, "ping", id: .string(id))["id"] == .string(id))
        #expect(try await response(server, "ping", id: .number(9_007_199_254_740_993))["id"] == .number(9_007_199_254_740_993))
    }
}

extension JSONValue {
    var elements: [JSONValue]? {
        if case let .array(values) = self {
            values
        } else {
            nil
        }
    }
}
