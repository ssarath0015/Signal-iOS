//
//  Copyright © 2025 MyCustomCompany. All rights reserved.
//

import Foundation
import SignalServiceKit

public class OnlineStatusManager {

    public static let shared = OnlineStatusManager()

    public static let onlineStatusDidChange = Notification.Name("onlineStatusDidChange")

    private var lastSeenData: [String: Date] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "OnlineStatusManagerQueue", qos: .background)
    // Polling interval is aggressive, as requested.
    // In a real-world application, this should be longer or use a push-based system.
    private let pollingInterval: TimeInterval = 5.0

    private init() {
        startPolling()
    }

    deinit {
        stopPolling()
    }

    public func startPolling() {
        queue.async {
            self.timer?.invalidate()

            self.timer = Timer.scheduledTimer(
                timeInterval: self.pollingInterval,
                target: self,
                selector: #selector(self.fetchOnlineStatus),
                userInfo: nil,
                repeats: true
            )

            RunLoop.current.add(self.timer!, forMode: .default)
            RunLoop.current.run()
        }
    }

    public func stopPolling() {
        queue.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    @objc private func fetchOnlineStatus() {
        let contacts = ArmourInternalContactManager.shared.getAllInternalContacts()
        let usernames = contacts.compactMap { $0.number }

        guard !usernames.isEmpty else {
            return
        }

        let request = LastSeenRequests.getLastSeen(for: usernames)

        SSKEnvironment.shared.networkManager.makeRequest(request) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let response):
                guard let data = response.data else { return }
                do {
                    let lastSeenContacts = try JSONDecoder().decode([ContactLastSeen].self, from: data)
                    self.updateLastSeenData(with: lastSeenContacts)
                } catch {
                    Logger.error("Failed to decode last seen response: \(error)")
                }
            case .failure(let error):
                Logger.error("Failed to fetch last seen status: \(error)")
            }
        }
    }

    private func updateLastSeenData(with contacts: [ContactLastSeen]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var newData: [String: Date] = [:]
        for contact in contacts {
            if let date = formatter.date(from: contact.lastSeen) {
                newData[contact.user] = date
            }
        }

        self.lastSeenData = newData

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.onlineStatusDidChange, object: nil)
        }
    }

    /// Checks if a user should be considered "online".
    /// A user is considered online if their last seen time was within the last 60 seconds.
    public func isOnline(username: String) -> Bool {
        guard let lastSeenDate = lastSeenData[username] else {
            return false
        }

        let isOnline = Date().timeIntervalSince(lastSeenDate) <= 60
        return isOnline
    }
}
