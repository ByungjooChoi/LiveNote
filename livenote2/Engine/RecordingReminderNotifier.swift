import Foundation
import UserNotifications

/// UNUserNotificationCenter 기반 리마인더 알림 발송 및 사용자 액션 처리기
final class RecordingReminderNotifier: NSObject, RecordingReminderNotifying, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    var onStart: (@MainActor () -> Void)?
    private static var isDelegateSet = false

    init(center: UNUserNotificationCenter = .current(), onStart: (@MainActor () -> Void)? = nil) {
        self.center = center
        self.onStart = onStart
        super.init()

        registerCategory()
        if !Self.isDelegateSet {
            center.delegate = self
            Self.isDelegateSet = true
        }
    }

    private func registerCategory() {
        let startAction = UNNotificationAction(
            identifier: "start",
            title: "Start LiveNote",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "livenote.recording-reminder",
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded(_ completion: @escaping @MainActor (Bool) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in
                        completion(granted)
                    }
                }
            case .authorized, .provisional:
                Task { @MainActor in
                    completion(true)
                }
            case .denied:
                Task { @MainActor in
                    completion(false)
                }
            @unknown default:
                Task { @MainActor in
                    completion(false)
                }
            }
        }
    }

    func deliver(appName: String, completion: @escaping @MainActor (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting in progress?"
        content.body = "\(appName) is using the microphone but LiveNote is not recording."
        content.sound = .default
        content.categoryIdentifier = "livenote.recording-reminder"

        let request = UNNotificationRequest(
            identifier: "livenote.recording-reminder.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            Task { @MainActor in
                completion(error)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        if actionIdentifier == "start" || actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                self.onStart?()
            }
        }
        completionHandler()
    }
}
