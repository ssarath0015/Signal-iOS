//
//  Copyright © 2025 MyCustomCompany. All rights reserved.
//

import Foundation
import SignalServiceKit
import UIKit

public class KeepAliveManager {

    public static let shared = KeepAliveManager()

    private var timer: Timer?
    private let queue = DispatchQueue(label: "KeepAliveManagerQueue", qos: .background)
    private let pollingInterval: TimeInterval = 5.0

    private var isAppVisible: Bool = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        stopPolling()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applicationDidBecomeActive() {
        Logger.info("[KeepAliveManager] Application became active.")
        self.isAppVisible = true
        startPolling()
    }

    @objc private func applicationWillResignActive() {
        Logger.info("[KeepAliveManager] Application will resign active.")
        self.isAppVisible = false
        stopPolling()
    }

    private func startPolling() {
        // Ensure we don't start multiple timers.
        guard self.timer == nil else {
            Logger.info("[KeepAliveManager] Polling is already active.")
            return
        }

        Logger.info("[KeepAliveManager] Starting polling.")
        queue.async {
            self.timer = Timer.scheduledTimer(
                timeInterval: self.pollingInterval,
                target: self,
                selector: #selector(self.sendKeepAlive),
                userInfo: nil,
                repeats: true
            )

            // Start the run loop for the background queue.
            RunLoop.current.add(self.timer!, forMode: .default)
            RunLoop.current.run()
        }
    }

    private func stopPolling() {
        Logger.info("[KeepAliveManager] Stopping polling.")
        queue.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    @objc private func sendKeepAlive() {
        guard self.isAppVisible else {
            // This check is slightly redundant as the timer is stopped when the app resigns active,
            // but it's a good safety measure.
            Logger.debug("[KeepAliveManager] App is not visible, skipping keep-alive.")
            return
        }

        Logger.debug("[KeepAliveManager] Sending keep-alive.")

        let keepAliveRequest = TSRequest(url: URL(string: "/v1/keepalive/last_seen")!, method: "GET")

        SSKEnvironment.shared.networkManager.makeRequest(keepAliveRequest) { result in
            switch result {
            case .success:
                Logger.debug("[KeepAliveManager] Keep-alive sent successfully.")
            case .failure(let error):
                Logger.warn("[KeepAliveManager] Keep-alive failed: \(error)")
            }
        }
    }
}
