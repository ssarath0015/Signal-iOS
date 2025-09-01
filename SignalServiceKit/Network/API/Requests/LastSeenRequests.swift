//
//  Copyright © 2025 MyCustomCompany. All rights reserved.
//

import Foundation

public enum LastSeenRequests {

    public static func getLastSeen(for usernames: [String]) -> TSRequest {
        let url = URL(string: "/v1/accounts/last_seen_all/")!

        let parameters: [String: Any] = [
            "usernameList": usernames
        ]

        var request = TSRequest(url: url, method: "POST", parameters: parameters)

        // This request needs to be authenticated.
        // The default auth is .identified(.implicit()), which should be correct here.

        return request
    }

    public static func getLastSeen(for username: String) -> TSRequest {
        let url = URL(string: "/v1/accounts/last_seen/\(username)")!

        var request = TSRequest(url: url, method: "GET")

        // This request needs to be authenticated.
        request.auth = .identified(.implicit())

        return request
    }
}
