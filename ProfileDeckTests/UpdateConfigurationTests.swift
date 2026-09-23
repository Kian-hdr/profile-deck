import XCTest
@testable import ProfileDeck

final class UpdateConfigurationTests: XCTestCase {
    private var valid: [String: Any] {
        ["SUFeedURL": UpdateConfiguration.stableFeed,
         "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
         "SUSignedFeedFailureExpirationInterval": 0]
    }
    func testOnlyProductFeedsAreAccepted() {
        XCTAssertNotNil(UpdateConfiguration(info: valid))
        var info = valid
        info["SUFeedURL"] = UpdateConfiguration.testingFeed
        XCTAssertNotNil(UpdateConfiguration(info: info))
        for url in ["http://example.test/feed.xml", "https://raw.githubusercontent.com/Kian-hdr/nodebay/updates/stable/appcast.xml", "file:///tmp/feed.xml"] {
            info["SUFeedURL"] = url
            XCTAssertNil(UpdateConfiguration(info: info))
        }
    }
    func testMissingOrWeakenedSignatureConfigurationIsRejected() {
        for key in valid.keys {
            var info = valid; info.removeValue(forKey: key)
            XCTAssertNil(UpdateConfiguration(info: info), key)
        }
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var info = valid; info[key] = false
            XCTAssertNil(UpdateConfiguration(info: info))
        }
        var info = valid; info["SUSignedFeedFailureExpirationInterval"] = 60
        XCTAssertNil(UpdateConfiguration(info: info))
        info = valid; info["SUPublicEDKey"] = "not-a-key"
        XCTAssertNil(UpdateConfiguration(info: info))
    }
    @MainActor func testDemoNeverStartsUpdater() async {
        let model = AppModel(demo: true)
        await model.bootstrap()
        let updates = SoftwareUpdateStore()
        updates.configure(model: model)
        XCTAssertFalse(updates.isConfigured)
        XCTAssertFalse(updates.canCheckForUpdates)
    }
    @MainActor func testRelaunchResumesExactlyOnceAfterTemporarySaveFailure() async {
        var attempts = 0; var errors = 0; var installs = 0
        await UpdateRelaunchGate.run(isBusy: { false }, flush: {
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteOutOfSpace) }
        }, reportError: { _ in errors += 1 }, install: { installs += 1 }, retryDelay: .milliseconds(1))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(installs, 1)
    }
    @MainActor func testCancelledDeferredRelaunchNeverInstalls() async {
        var installs = 0
        let task = Task { @MainActor in
            await UpdateRelaunchGate.run(isBusy: { true }, flush: {}, reportError: { _ in },
                install: { installs += 1 }, retryDelay: .milliseconds(1))
        }
        task.cancel()
        await task.value
        XCTAssertEqual(installs, 0)
    }
}
