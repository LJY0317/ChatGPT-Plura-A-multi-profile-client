import Foundation
@preconcurrency import UserNotifications

struct RemoteCompletionNotificationPolicy {
    static func shouldNotify(isEnabled: Bool, wasBackgrounded: Bool) -> Bool {
        isEnabled && wasBackgrounded
    }
}

@MainActor
final class RemoteCompletionNotifier {
    private static let preferenceKey = "codexRemote.completionNotificationsEnabled"
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.preferenceKey)
    }

    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            return false
        }

        do {
            let settings = await center.notificationSettings()
            let authorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authorized = true
            case .notDetermined:
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
            case .denied:
                authorized = false
            @unknown default:
                authorized = false
            }
            UserDefaults.standard.set(authorized, forKey: Self.preferenceKey)
            return authorized
        } catch {
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            return false
        }
    }

    func notifyTurnCompleted(wasBackgrounded: Bool) {
        guard RemoteCompletionNotificationPolicy.shouldNotify(
            isEnabled: isEnabled,
            wasBackgrounded: wasBackgrounded
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Codex finished"
        content.body = "Your task finished in Plura Mobile."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "plura.turn.completed.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
