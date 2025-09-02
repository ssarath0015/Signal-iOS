//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

public class LastSeenManager {
    public static let shared = LastSeenManager()

    private var lastSeenCache: [String: (status: SingleLastSeenResponse, timestamp: Date)] = [:]
    private let cacheDuration: TimeInterval = 60 // 60 seconds
    private var refreshTimer: Timer?

    private init() {}

    public func start() {
        // Invalidate existing timer before starting a new one
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshLastSeenStatusForAllContacts()
        }
        // Fire immediately on start
        refreshTimer?.fire()
    }

    public func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshLastSeenStatusForAllContacts() {
        let contacts = ArmourInternalContactManager.shared.getAllInternalContacts()
        for contact in contacts {
            guard let username = contact.number else { continue }
            getLastSeen(for: username) { _ in
                // Don't need to do anything with the result here, as the cache is updated internally.
            }
        }
    }

    public func getLastSeen(for username: String, completion: @escaping (Result<SingleLastSeenResponse, Error>) -> Void) {
        // Check cache first
        if let cachedData = lastSeenCache[username], Date().timeIntervalSince(cachedData.timestamp) < cacheDuration {
            completion(.success(cachedData.status))
            return
        }

        // If not in cache or expired, fetch from network
        let request = LastSeenRequests.getLastSeen(for: username)
        SSKEnvironment.shared.networkManager.makeRequest(request) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    guard let data = response.data else {
                        completion(.failure(OWSNetworkingError.invalidData))
                        return
                    }
                    do {
                        let lastSeenResponse = try JSONDecoder().decode(SingleLastSeenResponse.self, from: data)
                        self?.lastSeenCache[username] = (status: lastSeenResponse, timestamp: Date())
                        completion(.success(lastSeenResponse))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
}
