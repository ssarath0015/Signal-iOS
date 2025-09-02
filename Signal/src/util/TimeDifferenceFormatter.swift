//
//  Copyright © 2025 MyCustomCompany. All rights reserved.
//

import Foundation

public class TimeDifferenceFormatter {

    public static func formatLastSeen(date: Date) -> String {
        let now = Date()
        let secondsAgo = Int(now.timeIntervalSince(date))

        if secondsAgo < 60 {
            return NSLocalizedString("LAST_SEEN_JUST_NOW", comment: "Last seen status for a user who was online less than a minute ago.")
        }

        let minutesAgo = secondsAgo / 60
        if minutesAgo < 60 {
            return String(format: NSLocalizedString("LAST_SEEN_MINUTES_AGO", comment: "Last seen status for a user who was online minutes ago. e.g., 'last seen 5 minutes ago'"), minutesAgo)
        }

        let hoursAgo = minutesAgo / 60
        if hoursAgo < 24 {
             return String(format: NSLocalizedString("LAST_SEEN_HOURS_AGO", comment: "Last seen status for a user who was online hours ago. e.g., 'last seen 3 hours ago'"), hoursAgo)
        }

        if Calendar.current.isDateInYesterday(date) {
            return NSLocalizedString("LAST_SEEN_YESTERDAY", comment: "Last seen status for a user who was online yesterday.")
        }

        let daysAgo = hoursAgo / 24
        if daysAgo < 7 {
            return String(format: NSLocalizedString("LAST_SEEN_DAYS_AGO", comment: "Last seen status for a user who was online days ago. e.g., 'last seen 2 days ago'"), daysAgo)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return String(format: NSLocalizedString("LAST_SEEN_DATE", comment: "Last seen status for a user who was online on a specific date. e.g., 'last seen on 1/23/25'"), dateFormatter.string(from: date))
    }
}
