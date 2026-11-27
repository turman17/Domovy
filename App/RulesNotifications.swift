import DomovyCore
import Foundation
import UserNotifications

/// Local notifications for rule runs: "Archived 12 sessions (340 MB)." with Undo, and
/// "3 sessions are ready to archive." with Review for rules that ask first. Nothing leaves
/// the Mac; the text carries counts and sizes, never session titles.
final class RulesNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let runCategory = "rules.run"
    static let reviewCategory = "rules.review"
    static let undoAction = "rules.undo"
    static let reviewAction = "rules.review"

    /// Set once by the controller; read on the main actor only.
    @MainActor weak var controller: RulesController?

    /// Notifications need an app bundle; a bare test binary has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func install() {
        guard let center else { return }
        center.delegate = self
        let undo = UNNotificationAction(identifier: Self.undoAction, title: "Undo")
        let review = UNNotificationAction(identifier: Self.reviewAction, title: "Review", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.runCategory, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.reviewCategory, actions: [review], intentIdentifiers: []),
        ])
    }

    /// Asked when the first rule is turned on, not at launch.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postRun(_ record: RuleRunRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Rules ran"
        content.body = record.summary + " You can undo this."
        content.categoryIdentifier = Self.runCategory
        content.userInfo = ["record": record.id.uuidString]
        post(content, id: record.id.uuidString)
    }

    func postReview(_ preview: RulePreview) {
        let content = UNMutableNotificationContent()
        content.title = "Rules are waiting for your review"
        content.body = preview.summary.replacingOccurrences(of: " You can undo this.", with: "") + " Nothing changes until you confirm."
        content.categoryIdentifier = Self.reviewCategory
        post(content, id: "rules-review")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let record = (response.notification.request.content.userInfo["record"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        await MainActor.run {
            guard let controller else { return }
            Task { @MainActor in
                if action == Self.undoAction, let record {
                    await controller.undo(recordID: record)
                } else if category == Self.reviewCategory {
                    await controller.review()
                } else {
                    controller.wantsSettings = true
                }
            }
        }
    }
}
