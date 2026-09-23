import Foundation
import Darwin

struct ProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32
    var truncated: Bool
}

enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case timeout, cancelled, invalidInput, launchFailed
    var errorDescription: String? {
        switch self {
        case .timeout: "The helper did not respond in time."
        case .cancelled: "The operation was cancelled."
        case .invalidInput: "The helper input is too large or invalid."
        case .launchFailed: "The helper could not be started."
        }
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum ProcessRunner {
    /// Never invokes a shell. Output remains in memory and is never automatically logged.
    static func run(executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                    stdin: Data? = nil, timeout: TimeInterval = 15,
                    maximumOutputBytes: Int = 1_048_576) async throws -> ProcessResult {
        guard timeout > 0, maximumOutputBytes > 0, (stdin?.count ?? 0) <= 1_048_576 else {
            throw ProcessRunnerError.invalidInput
        }
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                if cancellation.cancelled { throw ProcessRunnerError.cancelled }
                let output = Pipe(), errors = Pipe(), input = Pipe()
                let process = try OwnedHelperProcess(executable: executable, arguments: arguments,
                    environment: environment ?? ProcessInfo.processInfo.environment,
                    input: input, output: output, errors: errors)
                let outFD = output.fileHandleForReading.fileDescriptor
                let errFD = errors.fileHandleForReading.fileDescriptor
                let inFD = input.fileHandleForWriting.fileDescriptor
                for fd in [outFD, errFD, inFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
                // A child may close stdin early. Suppress SIGPIPE only on this owned pipe.
                _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
                var out = Data(), err = Data(), truncated = false, position = 0, inputOpen = true
                let payload = stdin ?? Data()
                let started = ProcessInfo.processInfo.systemUptime
                var failure: ProcessRunnerError?
                var terminatedAt: TimeInterval?
                defer {
                    process.finish()
                    if inputOpen { try? input.fileHandleForWriting.close() }
                    try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
                }
                func drain(_ fd: Int32, into data: inout Data) {
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    for _ in 0..<64 {
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        guard count > 0 else { break }
                        let keep = min(count, max(0, maximumOutputBytes - data.count))
                        data.append(contentsOf: buffer.prefix(keep))
                        if keep != count { truncated = true }
                    }
                }
                while true {
                    let now = ProcessInfo.processInfo.systemUptime
                    if failure == nil && (cancellation.cancelled || now - started > timeout) {
                        failure = cancellation.cancelled ? .cancelled : .timeout
                        if process.isRunning { process.terminate(); terminatedAt = now }
                    }
                    if let terminatedAt, now - terminatedAt > 0.5, process.isRunning {
                        process.signalGroup(SIGKILL)
                    }
                    if inputOpen {
                        if position < payload.count {
                            let count = payload.withUnsafeBytes { raw in
                                Darwin.write(inFD, raw.baseAddress!.advanced(by: position), payload.count - position)
                            }
                            if count > 0 { position += count }
                            else if count < 0 && errno != EAGAIN && errno != EINTR { position = payload.count }
                        }
                        if position == payload.count { try? input.fileHandleForWriting.close(); inputOpen = false }
                    }
                    drain(outFD, into: &out); drain(errFD, into: &err)
                    if !process.isRunning { drain(outFD, into: &out); drain(errFD, into: &err); break }
                    usleep(10_000)
                }
                if let failure { throw failure }
                return ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus, truncated: truncated)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    static func profileEnvironment(home: String, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = inherited.filter { key, _ in
            !key.hasPrefix("CODEX_") && !key.hasPrefix("OPENAI_") && !key.hasPrefix("AZURE_OPENAI_")
        }
        result["CODEX_HOME"] = home
        return result
    }
}

/// A process group created atomically at spawn, never the manager's or a desktop client's group.
/// Descendants that deliberately create a new session escape this boundary; no arbitrary PID scan is used.
final class OwnedHelperProcess {
    let processIdentifier: Int32
    private var exitCode: Int32?
    private var finished = false

    init(executable: String, arguments: [String], environment: [String: String], input: Pipe, output: Pipe, errors: Pipe) throws {
        guard executable.hasPrefix("/"), !([executable] + arguments).contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.key.contains("\0") || $0.key.contains("=") || $0.value.contains("\0") }) else {
            throw ProcessRunnerError.invalidInput
        }
        var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProcessRunnerError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProcessRunnerError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let descriptors = [input.fileHandleForReading.fileDescriptor, input.fileHandleForWriting.fileDescriptor,
                           output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor,
                           errors.fileHandleForReading.fileDescriptor, errors.fileHandleForWriting.fileDescriptor]
        guard descriptors.allSatisfy({ $0 > 2 }),
              posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[3], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[5], STDERR_FILENO) == 0 else { throw ProcessRunnerError.launchFailed }
        for descriptor in descriptors {
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else { throw ProcessRunnerError.launchFailed }
        }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, signal) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0 else { throw ProcessRunnerError.launchFailed }
        var argv = ([executable] + arguments).map { strdup($0) }
        var envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw ProcessRunnerError.launchFailed }
        argv.append(nil); envp.append(nil)
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        guard code == 0, pid > 1 else { throw ProcessRunnerError.launchFailed }
        processIdentifier = pid
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }

    var isRunning: Bool {
        if exitCode != nil { return false }
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0, info.si_pid == processIdentifier {
            exitCode = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
            return false
        }
        if result < 0 && errno != EINTR {
            // Ownership can no longer be proven; never signal a potentially reused process group.
            finished = true; exitCode = -1
            return false
        }
        return true
    }
    var terminationStatus: Int32 { exitCode ?? -1 }
    func terminate() { signalGroup(SIGTERM) }
    func signalGroup(_ signal: Int32) {
        guard !finished else { return }
        // The unreaped group leader reserves its PID until finish completes, preventing ID reuse.
        _ = Darwin.kill(-processIdentifier, signal)
    }
    func finish() {
        guard !finished else { return }
        signalGroup(SIGTERM)
        usleep(100_000)
        signalGroup(SIGKILL)
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0 && errno == EINTR { }
        finished = true
    }
    deinit { finish() }
}

/// Nonblocking advisory lock shared with the existing profile launcher.
final class ProfileOperationLock: @unchecked Sendable {
    private let descriptor: Int32
    init(home: String) throws {
        let path = URL(fileURLWithPath: home).appendingPathComponent(".profile-launch.lock").path
        let candidate = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { throw DeckError.message("The profile lock could not be opened.") }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(candidate)
            throw DeckError.message("Another operation is using this profile. Try again when it finishes.")
        }
        descriptor = candidate
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
