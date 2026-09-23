import XCTest
@testable import ProfileDeck

final class ManagerInstanceLockTests: XCTestCase {
    private func fixture() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeckManagerLockTests-" + UUID().uuidString)
    }

    func testSecondOwnerIsRejectedUntilFirstOwnerReleasesStorage() throws {
        let directory = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: ManagerInstanceLock? = try ManagerInstanceLock(directory: directory)
        let path = directory.appendingPathComponent(".manager-instance.lock").path
        let originalInode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try ManagerInstanceLock(directory: directory)) {
                XCTAssertEqual($0 as? ManagerInstanceLockError, .alreadyRunning)
            }
        }
        first = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let second = try ManagerInstanceLock(directory: directory)
        try withExtendedLifetime(second) {
            let currentInode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
            XCTAssertNotNil(originalInode)
            XCTAssertEqual(originalInode, currentInode)
            XCTAssertThrowsError(try ManagerInstanceLock(directory: directory)) {
                XCTAssertEqual($0 as? ManagerInstanceLockError, .alreadyRunning)
            }
        }
    }

    func testIndependentStorageDirectoriesCanHaveOwnersAtTheSameTime() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ManagerInstanceLock(directory: root.appendingPathComponent("first"))
        let second = try ManagerInstanceLock(directory: root.appendingPathComponent("second"))
        try withExtendedLifetime((first, second)) {
            XCTAssertThrowsError(try ManagerInstanceLock(directory: root.appendingPathComponent("first")))
            XCTAssertThrowsError(try ManagerInstanceLock(directory: root.appendingPathComponent("second")))
        }
    }

    func testSymbolicLinkLockIsRejectedWithoutChangingItsDestination() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("preserved.txt")
        let contents = Data("Preserve this file".utf8)
        try contents.write(to: destination)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".manager-instance.lock"), withDestinationURL: destination)
        XCTAssertThrowsError(try ManagerInstanceLock(directory: root)) {
            XCTAssertEqual($0 as? ManagerInstanceLockError, .unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: destination), contents)
    }
}
