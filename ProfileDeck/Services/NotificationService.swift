import Foundation
import UserNotifications

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    override init() { super.init(); UNUserNotificationCenter.current().delegate = self; registerCategories() }
    private func registerCategories() {
        let open = UNNotificationAction(identifier:"openProfile",title:"Open profile",options:.foreground)
        let usage = UNNotificationAction(identifier:"viewUsage",title:"View usage",options:.foreground)
        let handoff = UNNotificationAction(identifier:"prepareHandoff",title:"Prepare handoff",options:.foreground)
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier:"profile",actions:[open,usage,handoff],intentIdentifiers:[])])
    }
    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.badge,.sound])
    }
    func send(id:String,title:String,body:String,profileID:UUID,sound:Bool) async throws {
        let content=UNMutableNotificationContent(); content.title=title; content.body=body; content.categoryIdentifier="profile"; content.userInfo=["profileID":profileID.uuidString]
        if sound { content.sound = .default }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:id,content:content,trigger:nil))
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse) async {
        let id=response.notification.request.content.userInfo["profileID"] as? String
        let action=response.actionIdentifier
        await MainActor.run { NotificationCenter.default.post(name:.deckNotificationAction,object:nil,userInfo:["profileID":id ?? "", "action":action]) }
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification) async -> UNNotificationPresentationOptions { [.banner,.list] }
}
