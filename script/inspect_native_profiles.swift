import Foundation

@main struct ReadOnlyProfileInspection {
    static func main() async throws {
        let native = NativeAdapter()
        let sharing = SharingService()
        let profiles = await native.discoverKnownProfiles()
        var world = SharedWorld.initial
        world.memoryOwnerID = profiles.first { $0.canonicalHome == URL(fileURLWithPath:world.sourceHome).resolvingSymlinksInPath().path }?.id
        var rows:[[String:Any]]=[]
        for profile in profiles {
            let runtime=await native.inspect(profile:profile)
            let shared=await sharing.inspect(profile:profile,world:world)
            rows.append(["profileLabel":profile.authMode.rawValue,"processState":runtime.state.rawValue,"verifiedProcessID":runtime.pid as Any? ?? NSNull(),"clientVersion":runtime.appVersion ?? "unavailable","resources":shared.resources.map {["name":$0.name,"state":$0.state.rawValue]},"taskStatus":"unavailable","operation":"read-only; no launch, focus, login, or configuration changes"])
        }
        let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
