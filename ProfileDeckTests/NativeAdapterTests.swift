import XCTest
@testable import ProfileDeck

final class NativeAdapterTests: XCTestCase {
    func testEnvironmentExcludesOtherProfileEndpointsAndKeys() {
        let result = ProcessRunner.profileEnvironment(home: "/fixture/profile", inherited: [
            "PATH": "/usr/bin", "CODEX_HOME": "/wrong", "CODEX_RPC_ENDPOINT": "private",
            "OPENAI_API_KEY": "fixture-secret", "OPENAI_BASE_URL": "https://invalid.example", "LANG": "en_US.UTF-8",
            "OPENAI_ORGANIZATION": "fixture-org", "OPENAI_PROJECT": "fixture-project",
            "OPENAI_API_BASE": "https://invalid.example/alternate", "OPENAI_FUTURE_OVERRIDE": "fixture",
            "AZURE_OPENAI_API_KEY": "fixture-azure-secret", "AZURE_OPENAI_ENDPOINT": "https://invalid.example/azure",
            "AZURE_OPENAI_API_VERSION": "fixture-version"
        ])
        XCTAssertEqual(result["CODEX_HOME"], "/fixture/profile")
        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["LANG"], "en_US.UTF-8")
        XCTAssertNil(result["CODEX_RPC_ENDPOINT"])
        XCTAssertNil(result["OPENAI_API_KEY"])
        XCTAssertNil(result["OPENAI_BASE_URL"])
        XCTAssertFalse(result.keys.contains { $0.hasPrefix("OPENAI_") || $0.hasPrefix("AZURE_OPENAI_") })
    }

    func testLockPIDParsingRejectsInvalidIdentifiers() {
        XCTAssertEqual(NativeAdapter.pidFromLock("my-mac-12345"), 12345)
        XCTAssertNil(NativeAdapter.pidFromLock("my-mac-0"))
        XCTAssertNil(NativeAdapter.pidFromLock("hostname-not-a-pid"))
        XCTAssertNil(NativeAdapter.pidFromLock("host-99999999999999999"))
    }

    func testProfileLockContentionPreservesOwnerAndReleasesCleanly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeckLockTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: ProfileOperationLock? = try ProfileOperationLock(home: directory.path)
        try withExtendedLifetime(owner) {
            for _ in 0..<20 { XCTAssertThrowsError(try ProfileOperationLock(home: directory.path)) }
        }
        owner = nil
        XCTAssertNoThrow(try ProfileOperationLock(home: directory.path))
    }

    func testKernelArgumentsResolveOnlyMatchingProfilePaths() throws {
        let data = kernelFixture(arguments: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", "--user-data-dir=/tmp/deck-data"],
                                 environment: ["CODEX_HOME=/tmp/deck-home", "OPENAI_API_KEY=fixture-secret"])
        let result = try XCTUnwrap(NativeAdapter.profilePaths(argumentBuffer: data))
        XCTAssertEqual(result.home, NativeAdapter.canonical("/tmp/deck-home"))
        XCTAssertEqual(result.data, NativeAdapter.canonical("/tmp/deck-data"))
    }

    func testKernelEnvironmentIsolationAndSpacedArguments() throws {
        let data = kernelFixture(arguments: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", "--user-data-dir", "/tmp/deck with spaces"],
                                 environment: ["CODEX_HOME=/tmp/deck-home", "CODEX_ELECTRON_USER_DATA_PATH=/tmp/other"])
        let result = try XCTUnwrap(NativeAdapter.profilePaths(argumentBuffer: data))
        XCTAssertEqual(result.data, NativeAdapter.canonical("/tmp/deck with spaces"))
    }

    func testMalformedKernelArgumentsFailClosed() {
        XCTAssertNil(NativeAdapter.profilePaths(argumentBuffer: Data()))
        XCTAssertNil(NativeAdapter.profilePaths(argumentBuffer: Data([255, 255, 255, 255, 0])))
        let data = kernelFixture(arguments: ["app"], environment: ["CODEX_HOME=relative"])
        XCTAssertNil(NativeAdapter.profilePaths(argumentBuffer: data))
    }

    func testProfilePathsMustBeDistinctAndAbsolute() {
        XCTAssertThrowsError(try NativeAdapter.validatePaths(Profile(name: "bad", homePath: "/tmp/shared", dataPath: "/tmp/shared")))
        XCTAssertThrowsError(try NativeAdapter.validatePaths(Profile(name: "bad", homePath: "/tmp/shared", dataPath: "/tmp/shared/nested")))
        XCTAssertThrowsError(try NativeAdapter.validatePaths(Profile(name: "bad", homePath: "relative", dataPath: "/tmp/data")))
    }

    func testJSONPreservesNullAndNestedConfigTypes() throws {
        let value: JSONValue = .object(["edits": .array([.object(["keyPath": .string("features.example"), "value": .bool(false)])]), "expectedVersion": .null])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(value["edits"].array?.first?["value"].bool, false)
    }

    func testProcessReceivesStdinWithoutShellExpansion() async throws {
        let payload = Data("$(do-not-expand) `literal`\n".utf8)
        let result = try await ProcessRunner.run(executable: "/bin/cat", stdin: payload)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, payload)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testProcessOutputIsBounded() async throws {
        let result = try await ProcessRunner.run(executable: "/usr/bin/printf", arguments: ["%10000s", "x"], maximumOutputBytes: 128)
        XCTAssertEqual(result.stdout.count, 128)
        XCTAssertTrue(result.truncated)
    }

    func testProcessTimeoutStopsOnlyItsOwnHelper() async {
        do {
            _ = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["3"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch ProcessRunnerError.timeout { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testProcessCancellation() async {
        let task = Task { try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["3"]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch ProcessRunnerError.cancelled { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTimeoutAlsoStopsHelperDescendants() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeckDescendantTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            _ = try await ProcessRunner.run(executable: "/bin/sh", arguments: [
                "-c", "(trap '' TERM; /bin/sleep 0.5; /usr/bin/touch \"$1\") & wait", "fixture", marker.path
            ], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch ProcessRunnerError.timeout { }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A child escaped helper timeout cleanup")
    }

    func testMissingAppAndUsageNeverInventTelemetry() async {
        let profile = Profile(name: "Fixture", homePath: "/nonexistent/profile-deck-fixture/home", dataPath: "/nonexistent/profile-deck-fixture/data", appPath: "/nonexistent/ProfileDeckFixture.app")
        let adapter = NativeAdapter()
        let snapshot = await adapter.inspect(profile: profile)
        XCTAssertEqual(snapshot.state, .unknown)
        XCTAssertNil(snapshot.pid)
        XCTAssertFalse(snapshot.capabilities.contains { $0.id == "taskStatus" && $0.available })
        let usage = await adapter.usage(profile: profile)
        XCTAssertNotNil(usage.error)
        XCTAssertTrue(usage.windows.isEmpty)
    }

    func testAdministrationRejectsTaskOwnershipAndTokenRefreshBeforeStartingHelper() async {
        let profile = Profile(name: "Fixture", homePath: "/nonexistent/deck-fixture/home", dataPath: "/nonexistent/deck-fixture/data")
        let rpc = ProviderRPC(profile: profile)
        for (method, params) in [("thread/resume", JSONValue.object([:])), ("account/read", JSONValue.object(["refreshToken": .bool(true)]))] {
            do { _ = try await rpc.call(method: method, params: params); XCTFail("Expected unavailable") }
            catch ProviderRPCError.unavailable { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await rpc.close()
    }

    private func kernelFixture(arguments: [String], environment: [String]) -> Data {
        var count = Int32(arguments.count)
        var result = withUnsafeBytes(of: &count) { Data($0) }
        result.append(Data("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT\0\0\0".utf8))
        for entry in arguments + environment { result.append(Data(entry.utf8)); result.append(0) }
        return result
    }
}
