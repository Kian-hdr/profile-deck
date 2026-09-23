import Foundation
import Darwin

enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var int: Int? { if case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max) { Int(v) } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
}

enum ProviderRPCError: Error, LocalizedError, Sendable {
    case unavailable, busy, rejected(Int?), malformed, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable: "The provider helper is unavailable. Use the provider's Settings."
        case .busy: "Close this profile before changing its configuration."
        case .rejected(let code): "The provider rejected the request\(code.map { " (code \($0))" } ?? ""). No unverified result was applied."
        case .malformed: "The provider returned an unsupported response."
        case .timeout: "The provider helper timed out."
        }
    }
}

/// A short-lived account reader or closed-profile administration session. Neither observes desktop tasks.
actor ProviderRPC {
    enum Purpose: Sendable { case configuration, accountUsage, mcpOAuth }
    private let profile: Profile
    private let purpose: Purpose
    private var transport: ProviderTransport?
    private var operationLock: ProfileOperationLock?
    private var busy = false
    private var sequence = 1

    init(profile: Profile, purpose: Purpose = .configuration) { self.profile = profile; self.purpose = purpose }

    nonisolated static func permits(method: String, params: JSONValue, purpose: Purpose) -> Bool {
        let allowed: [String]
        switch purpose {
        case .accountUsage: allowed = ["account/read", "account/rateLimits/read"]
        case .configuration: allowed = ["config/read", "configRequirements/read", "config/batchWrite", "config/value/write", "account/read"]
        case .mcpOAuth: allowed = ["config/read", "mcpServerStatus/list", "mcpServer/oauth/login"]
        }
        guard allowed.contains(method) else { return false }
        if purpose == .accountUsage {
            return method == "account/read"
                ? params == .object(["refreshToken": .bool(false)])
                : params == .object([:])
        }
        if purpose == .mcpOAuth {
            switch method {
            case "config/read": return params == .object(["includeLayers": .bool(true)])
            case "mcpServerStatus/list":
                return params["detail"].string == "toolsAndAuthOnly" && params.object?.keys.allSatisfy { ["detail", "cursor", "limit"].contains($0) } == true
            default:
                return params["name"].string?.isEmpty == false && params.object?.keys.allSatisfy { ["name", "timeoutSecs"].contains($0) } == true
            }
        }
        return method != "account/read" || params["refreshToken"].bool == false
    }

    func call(method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard Self.permits(method: method, params: params, purpose: purpose) else { throw ProviderRPCError.unavailable }
        guard !busy else { throw ProviderRPCError.busy }
        if method == "account/read", params["refreshToken"].bool != false { throw ProviderRPCError.unavailable }
        busy = true
        defer { busy = false }
        do {
            if transport == nil {
                if purpose == .configuration {
                    let snapshot = await NativeAdapter().inspect(profile: profile)
                    guard snapshot.state == .closed else { throw ProviderRPCError.busy }
                    let lock = try ProfileOperationLock(home: profile.canonicalHome)
                    operationLock = lock
                    let checked = await NativeAdapter().inspect(profile: profile)
                    guard checked.state == .closed else { throw ProviderRPCError.busy }
                }
                try await NativeAdapter.validateClient(profile: profile)
                let p = profile
                let created = try await Task.detached(priority: .utility) { try ProviderTransport(profile: p) }.value
                transport = created
                _ = try await exchange(created, method: "initialize", params: .object([
                    "clientInfo": .object(["name": .string("profile_deck"), "version": .string("0.1.5")]),
                    "capabilities": .object(["experimentalApi": .bool(purpose == .configuration)])
                ]))
                try await Task.detached(priority: .utility) {
                    try created.write(.object(["method": .string("initialized")]))
                }.value
            }
            guard let transport else { throw ProviderRPCError.unavailable }
            if method == "mcpServer/oauth/login", let name = params["name"].string {
                transport.clearMCPCompletions(name: name)
            }
            return try await exchange(transport, method: method, params: params)
        } catch {
            await shutdown()
            throw error
        }
    }

    private func exchange(_ transport: ProviderTransport, method: String, params: JSONValue) async throws -> JSONValue {
        sequence += 1
        let id = sequence
        return try await Task.detached(priority: .utility) {
            try transport.request(id: id, method: method, params: params)
        }.value
    }

    func close() async {
        // The caller must await its operation before closing; do not race a stream reader.
        guard !busy else { return }
        await shutdown()
    }

    func abort() async {
        if let transport { await Task.detached(priority: .utility) { transport.stop() }.value }
        transport = nil
        operationLock = nil
    }

    func waitForMCPCompletion(name: String, timeout: TimeInterval = 180) async throws -> JSONValue {
        guard purpose == .mcpOAuth, !busy, let transport else { throw ProviderRPCError.unavailable }
        busy = true
        defer { busy = false }
        do {
            return try await Task.detached(priority: .utility) {
                try transport.waitForMCPCompletion(name: name, timeout: timeout)
            }.value
        } catch {
            await shutdown()
            throw error
        }
    }

    private func shutdown() async {
        if let transport { await Task.detached(priority: .utility) { transport.stop() }.value }
        transport = nil
        operationLock = nil
    }
}

/// All stream access is serialized by ProviderRPC. No response or stderr is logged.
private final class ProviderTransport: @unchecked Sendable {
    let process: OwnedHelperProcess
    let input: Pipe
    let output: Pipe
    let errors: Pipe
    private var buffer = Data()
    private var mcpCompletions: [JSONValue] = []
    private let stopLock = NSLock()
    private var stopped = false

    init(profile: Profile) throws {
        input = Pipe(); output = Pipe(); errors = Pipe()
        do {
            let runtime = try ProfileRuntimePaths.prepare(profile)
            process = try OwnedHelperProcess(executable: URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Resources/codex").path,
                arguments: ["app-server", "--stdio"], environment: ProcessRunner.profileEnvironment(home: runtime.home),
                input: input, output: output, errors: errors)
        } catch { throw ProviderRPCError.unavailable }
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message); data.append(10)
        guard data.count <= 1_048_576 else { throw ProviderRPCError.malformed }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var offset = 0
        while offset < data.count {
            guard process.isRunning else { throw ProviderRPCError.unavailable }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProviderRPCError.timeout }
            let written = data.withUnsafeBytes { raw in
                Darwin.write(input.fileHandleForWriting.fileDescriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 { offset += written }
            else if errno != EAGAIN && errno != EINTR { throw ProviderRPCError.unavailable }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
    }

    func request(id: Int, method: String, params: JSONValue) throws -> JSONValue {
        try write(.object(["id": .number(Double(id)), "method": .string(method), "params": params]))
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var bytes = [UInt8](repeating: 0, count: 16384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            // Discard diagnostics rather than retaining provider output that can contain private state.
            for _ in 0..<64 {
                if Darwin.read(errors.fileHandleForReading.fileDescriptor, &bytes, bytes.count) <= 0 { break }
            }
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let response = try? JSONDecoder().decode(JSONValue.self, from: line) else { throw ProviderRPCError.malformed }
                // Server requests are not responses, even when their numeric IDs
                // coincide. This helper never handles login/token/tool requests.
                if response.object?["method"] != nil {
                    if response.object?["id"] != nil { throw ProviderRPCError.unavailable }
                    if response["method"].string == "mcpServer/oauthLogin/completed" { mcpCompletions.append(response) }
                    continue
                }
                if response["id"].int == id {
                    if response.object?["error"] != nil { throw ProviderRPCError.rejected(response["error"]["code"].int) }
                    guard let result = response.object?["result"] else { throw ProviderRPCError.malformed }
                    return result
                }
            }
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 8_388_608 else { throw ProviderRPCError.malformed }
            } else if count == 0 || !process.isRunning { throw ProviderRPCError.unavailable }
            else if errno != EAGAIN && errno != EINTR { throw ProviderRPCError.unavailable }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
        throw ProviderRPCError.timeout
    }

    func clearMCPCompletions(name: String) {
        mcpCompletions.removeAll { $0["params"]["name"].string == name }
    }

    func waitForMCPCompletion(name: String, timeout: TimeInterval) throws -> JSONValue {
        guard timeout > 0 else { throw ProviderRPCError.timeout }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = [UInt8](repeating: 0, count: 16384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let index = mcpCompletions.firstIndex(where: { $0["params"]["name"].string == name }) {
                return mcpCompletions.remove(at: index)["params"]
            }
            for _ in 0..<64 {
                if Darwin.read(errors.fileHandleForReading.fileDescriptor, &bytes, bytes.count) <= 0 { break }
            }
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { throw ProviderRPCError.malformed }
                if message["method"].string == "mcpServer/oauthLogin/completed" {
                    mcpCompletions.append(message)
                } else if message.object?["id"] != nil, message.object?["method"] != nil {
                    throw ProviderRPCError.unavailable
                }
            }
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 8_388_608 else { throw ProviderRPCError.malformed }
            } else if count == 0 || !process.isRunning { throw ProviderRPCError.unavailable }
            else if errno != EAGAIN && errno != EINTR { throw ProviderRPCError.unavailable }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
        throw ProviderRPCError.timeout
    }

    func stop() {
        stopLock.lock()
        guard !stopped else { stopLock.unlock(); return }
        stopped = true
        stopLock.unlock()
        try? input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        let forcedDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < forcedDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.signalGroup(SIGKILL) }
        process.finish()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
    deinit { stop() }
}
