import Foundation

nonisolated enum DemoData {
    static func make() -> PersistedDeck {
        var state = PersistedDeck(); state.onboardingComplete=true
        var personal=Profile(name:"Example One",color:"blue",homePath:"/demo/example-one/home",dataPath:"/demo/example-one/data",favorite:true)
        personal.observedAccount="example-one@example.test"; personal.verifiedAuthMode = .subscription
        let work=Profile(name:"Studio",color:"orange",homePath:"/demo/studio/home",dataPath:"/demo/studio/data",manualOrder:1)
        let api=Profile(name:"Development",color:"purple",authMode:.apiKey,homePath:"/demo/dev/home",dataPath:"/demo/dev/data",manualOrder:2)
        state.profiles=[personal,work,api]; state.world=SharedWorld(sourceHome:"/demo/shared",workspacePaths:["/demo/Shared Workspace"],memoryOwnerID:personal.id)
        state.integrations=[
            IntegrationStatus(id:"documentation",name:"Documentation",kind:.mcp,detail:"Illustrative shared selection; no connection has been made."),
            IntegrationStatus(id:"writing-personal",name:"Writing tools",kind:.plugin,source:"writing@example",profileID:personal.id,detail:"Preview only. Package configuration and authorization are checked separately."),
            IntegrationStatus(id:"writing-studio",name:"Writing tools",kind:.plugin,source:"writing@example",profileID:work.id,detail:"Preview only. This profile has not verified the shared tools yet.")
        ]
        if CommandLine.arguments.contains("--demo-scale") {
            for index in 4...50 { state.profiles.append(Profile(name:String(format:"Example %02d",index),homePath:"/demo/profile\(index)/home",dataPath:"/demo/profile\(index)/data",manualOrder:index-1)) }
            state.tasks=(0..<1000).map { TaskObservation(id:"example-task-\($0)",profileID:state.profiles[$0%50].id,turnID:"fixture",title:"Example task \($0)",state:.unavailable) }
        }
        return state
    }
}
