import XCTest
@testable import ProfileDeck

final class DeckLogicTests: XCTestCase {
    func profile(_ name:String,order:Int=0) -> Profile { Profile(name:name,homePath:"/fixture/\(name)/home",dataPath:"/fixture/\(name)/data",manualOrder:order) }
    func testNestedAndDuplicateProfilePathsRejected() throws {
        let a=profile("a"); var b=profile("b"); b.homePath=a.homePath + "/child"
        XCTAssertThrowsError(try DeckLogic.validateProfile(b,against:[a]))
        b.homePath=a.dataPath; XCTAssertThrowsError(try DeckLogic.validateProfile(b,against:[a]))
        XCTAssertNoThrow(try DeckLogic.validateProfile(profile("c"),against:[a]))
    }
    func testSearchFindsOwningTaskAndStableFavorites() {
        var a=profile("a",order:2); a.favorite=true
        let b=profile("b",order:1)
        let task=TaskObservation(id:"t",profileID:b.id,turnID:"turn",title:"Rendering",state:.running)
        XCTAssertEqual(DeckLogic.sorted([a,b],query:"render",order:.manual,showHidden:false,tasks:[task],usage:[]).map(\.id),[b.id])
        XCTAssertEqual(DeckLogic.sorted([b,a],query:"",order:.recent,showHidden:false,tasks:[task],usage:[]).first?.id,a.id)
    }
    func testManualOrderIsSharedAndFilteredReorderingLeavesOtherSlotsFixed() {
        var a = profile("a", order: 0); a.favorite = true
        let b = profile("b", order: 1)
        let c = profile("c", order: 2)
        let d = profile("d", order: 3)
        XCTAssertEqual(DeckLogic.sorted([d, c, b, a], query: "", order: .manual, showHidden: true, tasks: [], usage: []).map(\.id), [a, b, c, d].map(\.id))

        let reordered = try? XCTUnwrap(DeckLogic.manualReordering([a, b, c, d], moving: c.id, before: a.id, visibleIDs: [a.id, c.id]))
        XCTAssertEqual(DeckLogic.manuallyOrdered(reordered ?? []).map(\.id), [c, b, a, d].map(\.id))
    }
    func testExpiredResetNeverMeansZeroUsage() {
        let now=Date(); let w=UsageWindow(id:"x",usedPercent:97,durationMinutes:300,resetsAt:now.addingTimeInterval(-1))
        XCTAssertEqual(w.label,"5-hour"); XCTAssertEqual(w.remaining,3)
        XCTAssertEqual(DeckLogic.resetDescription(w,now:now),"Reset awaiting confirmation")
        let s=UsageSnapshot(profileID:UUID(),accountID:"account",windows:[w],observedAt:now)
        XCTAssertTrue(DeckLogic.notificationKeys(snapshot:s,settings:DeckSettings(),now:now).isEmpty)
    }
    func testThresholdIdentitySharedAcrossProfilesAndUnknownAccountSuppressed() {
        let now=Date(); let w=UsageWindow(id:"weekly",usedPercent:96,durationMinutes:10080,resetsAt:now.addingTimeInterval(60))
        let a=UsageSnapshot(profileID:UUID(),accountID:"same",windows:[w],observedAt:now)
        let b=UsageSnapshot(profileID:UUID(),accountID:"same",windows:[w],observedAt:now)
        XCTAssertEqual(DeckLogic.notificationKeys(snapshot:a,settings:DeckSettings(),now:now).map(\.0),DeckLogic.notificationKeys(snapshot:b,settings:DeckSettings(),now:now).map(\.0))
        let unknown=UsageSnapshot(profileID:UUID(),windows:[w]); XCTAssertTrue(DeckLogic.notificationKeys(snapshot:unknown,settings:DeckSettings()).isEmpty)
    }
    func testPortableExportExcludesPathsIdentityAndRuntime() throws {
        var state=PersistedDeck(); var p=profile("Demo"); p.observedAccount="secret@example.test"; state.profiles=[p]
        state.world.sourceHome="/private/source"; state.handoffs=[Handoff(objective:"PRIVATE BRIEF")]
        let text=String(data:try JSONEncoder().encode(PortableConfiguration(state:state)),encoding:.utf8)!
        for secret in ["/fixture/", "secret@example.test", "/private/source", "PRIVATE BRIEF"] { XCTAssertFalse(text.contains(secret)) }
    }
    func testHandoffDoesNotClaimOwnershipWithoutRelease() {
        var h=Handoff(objective:"Continue",progress:"Tests pass")
        XCTAssertTrue(h.rendered.contains("Do not begin overlapping edits")); h.ownershipReleased=true
        XCTAssertTrue(h.rendered.contains("explicitly released"))
    }
    func testHandoffIncludesOnlyTransferableSharedConversationLinks() {
        var shared = Handoff(objective: "Continue")
        shared.sourceContextLink = " https://chatgpt.com/share/example-snapshot "
        XCTAssertEqual(shared.sourceContextKind, .sharedConversation)
        XCTAssertTrue(shared.canTransferSourceContext)
        XCTAssertTrue(shared.rendered.contains("https://chatgpt.com/share/example-snapshot"))

        var privateThread = Handoff(objective: "Continue")
        privateThread.sourceContextLink = "codex://threads/private-thread-id"
        XCTAssertEqual(privateThread.sourceContextKind, .privateThread)
        XCTAssertFalse(privateThread.canTransferSourceContext)
        XCTAssertFalse(privateThread.rendered.contains("private-thread-id"))
        XCTAssertTrue(privateThread.rendered.contains("deliberately omitted"))
    }
    func testHandoffContextLinkClassificationRejectsNonShareURLs() {
        XCTAssertEqual(HandoffContextLinkKind.classify("https://chatgpt.com/c/private"), .privateThread)
        XCTAssertEqual(HandoffContextLinkKind.classify("https://example.com/context"), .unsupported)
        XCTAssertEqual(HandoffContextLinkKind.classify(""), .none)
    }
    func testPerformanceFiftyProfilesThousandTasks() {
        let profiles=(0..<50).map{profile("Profile \($0)",order:$0)}
        let tasks=(0..<1000).map{TaskObservation(id:"t\($0)",profileID:profiles[$0%50].id,turnID:"turn",title:"Task \($0)",state:.running)}
        let start=ContinuousClock.now
        _=DeckLogic.sorted(profiles,query:"Task 999",order:.attention,showHidden:false,tasks:tasks,usage:[])
        XCTAssertLessThan(start.duration(to:.now),.milliseconds(100))
    }
    func testSQLiteRoundTripAndOutOfOrderSave() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=DeckStore(directory:directory); var first=PersistedDeck(); first.profiles=[profile("first")]
        try await store.save(first,revision:2)
        var stale=PersistedDeck(); stale.profiles=[profile("stale")]; try await store.save(stale,revision:1)
        let loaded=try await store.load(); XCTAssertEqual(loaded?.profiles.first?.name,"first")
        let manifest = try String(contentsOf:directory.appendingPathComponent("shared-world.json"),encoding:.utf8)
        XCTAssertTrue(manifest.contains("schemaVersion")); XCTAssertFalse(manifest.contains("observedAccount"))
    }
    func testStoreRejectsUnexpectedProfileLossAndRecoversMissingDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeckStore(directory: directory)
        var original = PersistedDeck()
        original.profiles = [profile("first"), profile("second")]
        original.lastSelectedProfileID = original.profiles[1].id
        try await store.save(original, revision: 1)
        var stale = original
        stale.profiles.removeLast()
        do {
            try await store.save(stale, revision: 2)
            XCTFail("Unexpected profile loss must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("discard registered profiles"))
        }
        let retained = try await store.load()
        XCTAssertEqual(retained?.profiles.count, 2)
        XCTAssertEqual(retained?.lastSelectedProfileID, original.lastSelectedProfileID)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("deck.sqlite"))
        let recovered = try await DeckStore(directory: directory).load()
        XCTAssertEqual(recovered?.profiles.count, 2)
        XCTAssertEqual(recovered?.lastSelectedProfileID, original.lastSelectedProfileID)
        try await store.save(stale, revision: 3, allowedRemovedProfileIDs: [original.profiles[1].id])
        let afterRemoval = try await store.load()
        XCTAssertEqual(afterRemoval?.profiles.count, 1)
    }
    func testRecoverySnapshotWinsOverSmallerStartupDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeckStore(directory: directory)
        var complete = PersistedDeck()
        complete.profiles = [profile("Example One"), profile("Example Two"), profile("Example Three")]
        try await store.save(complete, revision: 1)
        let snapshot = try Data(contentsOf: directory.appendingPathComponent("deck-state-last-good.json"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("deck.sqlite"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("deck-state-last-good.json"))
        var smaller = PersistedDeck()
        smaller.profiles = Array(complete.profiles.prefix(2))
        try await DeckStore(directory: directory).save(smaller, revision: 1)
        try snapshot.write(to: directory.appendingPathComponent("deck-state-last-good.json"), options: .atomic)
        let recovered = try await DeckStore(directory: directory).load()
        XCTAssertEqual(recovered?.profiles.count, 3)
        try await DeckStore(directory: directory).save(recovered!, revision: 1)
        XCTAssertEqual(try JSONDecoder().decode(PersistedDeck.self, from: Data(contentsOf: directory.appendingPathComponent("deck-state-last-good.json"))).profiles.count, 3)
    }
    @MainActor func testDemoCannotAuthenticateOrFocusNativeProfile() async {
        let model = AppModel(demo:true)
        await model.bootstrap()
        let p = model.deck.profiles[0]
        model.focus(p,windowID:123)
        XCTAssertTrue(model.errorMessage?.contains("Demo mode") == true)
        model.errorMessage=nil
        model.loginAPI(p,key:"test-fixture-not-a-key")
        XCTAssertTrue(model.errorMessage?.contains("Demo mode") == true)
        var settings=model.deck.settings; settings.launchAtLogin=true; settings.notificationsEnabled=true
        model.updateSettings(settings)
        XCTAssertFalse(model.deck.settings.launchAtLogin); XCTAssertFalse(model.deck.settings.notificationsEnabled)
    }
    func testPortableExportKeepsOnlyCanonicalDesiredSelections() {
        var deck=PersistedDeck()
        deck.integrations=[IntegrationStatus(id:"mcp:a",name:"a",kind:.mcp), IntegrationStatus(id:"mcp:a",name:"a",kind:.mcp,profileID:UUID())]
        XCTAssertEqual(PortableConfiguration(state:deck).integrations.count,1)
    }
    func testFutureAndInvalidUsageReadingsAreUnavailable() {
        let now=Date()
        let valid=UsageWindow(id:"bucket",usedPercent:80)
        XCTAssertFalse(UsageSnapshot(profileID:UUID(),windows:[valid],observedAt:now.addingTimeInterval(1)).isFresh(at:now))
        XCTAssertFalse(UsageSnapshot(profileID:UUID(),windows:[UsageWindow(id:"bad",usedPercent:-10)],observedAt:now).isFresh(at:now))
        XCTAssertTrue(UsageSnapshot(profileID:UUID(),windows:[valid],observedAt:now).isFresh(at:now))
    }
    @MainActor func testCorruptManagerStoreBlocksNativeMutations() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        try Data("corrupt fixture".utf8).write(to:directory.appendingPathComponent("deck.sqlite"))
        let model=AppModel(directory:directory,demo:false)
        await model.bootstrap()
        XCTAssertFalse(model.storageAvailable)
        model.open(profile("blocked"))
        XCTAssertTrue(model.errorMessage?.contains("Restore the manager database") == true)
        XCTAssertTrue(model.deck.profiles.isEmpty)
    }
}
