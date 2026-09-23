import Foundation
import Darwin

enum ManagerInstanceLockError: Error, LocalizedError, Sendable, Equatable {
    case alreadyRunning, unavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Another Profile Deck window or copy is already managing these profiles. Quit the other Profile Deck app, then reopen this one. Your native account windows can stay open."
        case .unavailable:
            "Profile Deck could not lock its local storage. Check that its Application Support folder is available and writable, then reopen Profile Deck."
        }
    }
}

/// Retain for the entire storage session, including pending saves. The lock file
/// must remain on disk so later owners always contend on the same inode.
final class ManagerInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    init(directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ManagerInstanceLockError.unavailable }
        let path = directory.appendingPathComponent(".manager-instance.lock").path
        let candidate = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                                    S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { throw ManagerInstanceLockError.unavailable }
        var metadata = stat()
        guard fstat(candidate, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(candidate)
            throw ManagerInstanceLockError.unavailable
        }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(candidate)
            throw code == EWOULDBLOCK || code == EAGAIN
                ? ManagerInstanceLockError.alreadyRunning : ManagerInstanceLockError.unavailable
        }
        descriptor = candidate
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
