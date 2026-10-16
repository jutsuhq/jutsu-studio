import Foundation
import ImageIO
import MediaKit
import Presentation
import UniformTypeIdentifiers
import UserNotifications
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "System")

/// Posts job notifications. Asks for permission with the first one, not at launch, so the prompt comes
/// with a reason the user can see.
@MainActor
final class JobNotifier {
    /// A click on a notification (`nil` action) or on one of its buttons.
    typealias ResponseHandler = @MainActor @Sendable (JobNotification.Response) -> Void

    /// `UNUserNotificationCenter.delegate` is weak; this keeps the handler alive.
    private var clickHandler: NotificationClickHandler?

    /// Also registers the notifications' buttons (`JobNotification.Category`).
    func install(onResponse: @escaping ResponseHandler) {
        let handler = NotificationClickHandler(onResponse: onResponse)
        clickHandler = handler
        let center = UNUserNotificationCenter.current()
        center.delegate = handler
        center.setNotificationCategories(Set(JobNotification.Category.allCases.map(Self.category)))
    }

    /// Every button brings the app forward: each opens a page or Finder, and Retry shows the job in the Queue.
    private static func category(_ category: JobNotification.Category) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: category.rawValue,
            actions: category.actions.map {
                UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: .foreground)
            },
            intentIdentifiers: [])
    }

    func post(_ notifications: [JobNotification]) {
        Task { await Self.deliver(notifications) }
    }

    /// Asking again after the user decided returns the decision without a prompt, and picks up a change
    /// made in System Settings since.
    private nonisolated static func deliver(_ notifications: [JobNotification]) async {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
        } catch {
            logger.error("Notification permission failed: \(String(describing: error), privacy: .private)")
            return
        }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
            content.sound = notification.playsSound ? .default : nil
            content.userInfo = notification.userInfo
            if let threadID = notification.threadID { content.threadIdentifier = threadID }
            if let category = notification.category { content.categoryIdentifier = category.rawValue }
            if let file = notification.resultFile, let thumbnail = await thumbnail(of: file, for: notification.jobID) {
                content.attachments = [thumbnail]
            }
            // One per job: a later state replaces the earlier banner in Notification Center.
            let request = UNNotificationRequest(
                identifier: notification.jobID.uuidString, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                logger.error("Can't post a notification: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// A frame of the result for the banner. UserNotifications moves the file into its own store, so it is
    /// written to a temporary file, never the result itself. `nil` when the frame can't be read: the
    /// notification goes out without it.
    private nonisolated static func thumbnail(of video: URL, for jobID: UUID) async -> UNNotificationAttachment? {
        let maximumSize = CGSize(width: 720, height: 720)
        guard let image = try? await ThumbnailStrip.images(for: video, count: 1, maximumSize: maximumSize).first
        else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "notification-\(jobID.uuidString).jpg")
        guard
            let destination = CGImageDestinationCreateWithURL(
                file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            return try UNNotificationAttachment(identifier: "thumbnail", url: file)
        } catch {
            logger.error("Can't attach a thumbnail: \(String(describing: error), privacy: .private)")
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }
}

/// Called by UserNotifications on its own queue; hops to the main actor for anything UI.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    private let onResponse: JobNotifier.ResponseHandler

    init(onResponse: @escaping JobNotifier.ResponseHandler) {
        self.onResponse = onResponse
        super.init()
    }

    /// Shows the banner even while the app is frontmost: the window may be on another Space or showing Create.
    /// `.list` keeps it in Notification Center too, as when the app is in the background.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard
            let reply = JobNotification.Response(
                userInfo: response.notification.request.content.userInfo,
                actionIdentifier: response.actionIdentifier,
                isDefaultAction: response.actionIdentifier == UNNotificationDefaultActionIdentifier)
        else { return }
        let onResponse = onResponse
        Task { @MainActor in onResponse(reply) }
    }
}
