import Foundation
import AppKit

/// Explicit manual harness: no sign-in, credentials, model tasks, or existing-profile mutation.
@main struct NativeLaunchSmoke {
    static func main() async throws {
        guard CommandLine.arguments.contains("--disposable-native-smoke") else { throw DeckError.message("This harness requires --disposable-native-smoke and opens two empty native profiles.") }
        let native=NativeAdapter()
        let baselineProfiles=await native.discoverKnownProfiles()
        var before:[UUID:RuntimeSnapshot]=[:]
        for p in baselineProfiles { before[p.id]=await native.inspect(profile:p) }
        let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ProfileDeck/NativeSmoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try "Disposable smoke fixture, no account credentials entered.".write(to:root.appendingPathComponent("FIXTURE.txt"),atomically:true,encoding:.utf8)
        let profiles=(1...2).map { Profile(name:"Disposable \($0)",homePath:root.appendingPathComponent("Profile\($0)/home").path,dataPath:root.appendingPathComponent("Profile\($0)/data").path,createdByDeck:true) }
        var outcomes:[String:Any]=[:]
        do {
            var snapshots:[RuntimeSnapshot]=[]
            let start=Date()
            for p in profiles { snapshots.append(try await native.open(profile:p)) }
            outcomes["twoIsolatedProcesses"] = snapshots[0].pid != snapshots[1].pid && snapshots.allSatisfy {$0.state == .open}
            outcomes["launchSeconds"] = Date().timeIntervalSince(start)
            for (i,p) in profiles.enumerated() {
                let again=try await native.open(profile:p)
                guard again.pid == snapshots[i].pid, again.processStart == snapshots[i].processStart else { throw DeckError.message("Repeated open changed process identity.") }
            }
            outcomes["repeatOpenPreservesProcess"] = true
            var focusDurations:[Double]=[]
            for p in profiles + profiles {
                let start=Date(); try await native.focus(profile:p)
                focusDurations.append(Date().timeIntervalSince(start))
                let expected=await native.inspect(profile:p)
                var focused=false
                for _ in 0..<20 {
                    focused=await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid }
                    if focused { break }
                    try await Task.sleep(for:.milliseconds(100))
                }
                guard focused else { throw DeckError.message("The selected native process did not become frontmost.") }
            }
            outcomes["activationRequestsAccepted"] = true
            outcomes["correctNativeProcessBecameFrontmost"] = true
            outcomes["focusRequestSeconds"] = focusDurations
            for p in profiles { try await native.quit(profile:p) }
            outcomes["ownedProfilesClosedNormally"] = true
        } catch {
            outcomes["failure"] = error.localizedDescription
            for p in profiles { try? await native.quit(profile:p) }
        }
        var preserved=true
        for p in baselineProfiles {
            let after=await native.inspect(profile:p)
            if before[p.id]?.state == .open && (after.pid != before[p.id]?.pid || after.processStart != before[p.id]?.processStart) { preserved=false }
        }
        outcomes["existingProcessIdentitiesPreserved"] = preserved
        outcomes["authenticatedModelTasks"] = "not run; no credentials entered"
        outcomes["visualWindowFocus"] = "requires separate native UI verification"
        outcomes["fixtureData"] = "retained locally under ProfileDeck cache for recovery"
        var output=try JSONSerialization.data(withJSONObject:outcomes,options:[.prettyPrinted,.sortedKeys]); output.append(10)
        FileHandle.standardOutput.write(output)
        if outcomes["failure"] != nil || !preserved { exit(1) }
    }
}
