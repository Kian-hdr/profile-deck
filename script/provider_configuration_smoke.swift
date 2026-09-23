import Foundation

@main struct ProviderConfigurationSmoke {
    static func main() async throws {
        guard CommandLine.arguments.contains("--disposable-configuration-smoke") else { throw DeckError.message("Pass --disposable-configuration-smoke to test only an empty temporary profile.") }
        let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ProfileDeck/ConfigSmoke-" + UUID().uuidString)
        let home=root.appendingPathComponent("home"), data=root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        let config=home.appendingPathComponent("config.toml")
        try "# Profile Deck fixture: retain this comment\nmodel_verbosity = \"low\"\n\n[features]\ncollaboration_modes = true\n".write(to:config,atomically:true,encoding:.utf8)
        let profile=Profile(name:"Disposable configuration fixture",homePath:home.path,dataPath:data.path)
        let sharing=SharingService(recoveryRoot:root.appendingPathComponent("recovery"))
        var result:[String:Any]=["credentials":"none entered", "modelTasks":"none submitted", "profile":"disposable local fixture"]
        do {
            let before=try await sharing.readConfiguration(profile)
            let tx=try await sharing.applyIntegrationEdit(profile:profile,edits:["model_verbosity":.string("high")],title:"Fixture targeted write")
            let after=try await sharing.readConfiguration(profile)
            result["versionedUserLayer"] = !before.version.isEmpty
            result["targetedWriteVerified"] = tx.state == .applied && after.values["model_verbosity"] == .string("high")
            let text=try String(contentsOf:config,encoding:.utf8)
            result["unrelatedCommentAndFeaturePreserved"] = text.contains("retain this comment") && text.contains("collaboration_modes = true")
            try await sharing.restore(transaction:tx)
            let restored=try await sharing.readConfiguration(profile)
            result["recoveryVerified"] = restored.values["model_verbosity"] == .string("low")
        } catch { result["failure"] = error.localizedDescription }
        var bytes=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]); bytes.append(10); FileHandle.standardOutput.write(bytes)
        if result["failure"] != nil || result["targetedWriteVerified"] as? Bool != true || result["recoveryVerified"] as? Bool != true { exit(1) }
    }
}
