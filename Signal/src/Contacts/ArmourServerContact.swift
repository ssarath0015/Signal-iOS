import Foundation
import UIKit
import GRDB
import LibSignalClient


// MARK: - ArmourServerContact Model (Updated)

public struct ArmourServerContact: Codable {
    public let number: String?
    public let uuid: String?
    public let bot: Bool?
    public let disappearingTimeoutException: Bool?
    public let groupList: [String]?
    public let email: String?

    // Computed properties for Signal integration
    public var signalServiceAddress: SignalServiceAddress? {
        if let uuidString = uuid, !uuidString.isEmpty {
            return SignalServiceAddress(aciString: uuidString, phoneNumber: number)
        } else if let phoneNumber = number, let e164 = E164(phoneNumber) {
            return SignalServiceAddress(phoneNumber: e164.stringValue)
        }
        return nil
    }

    public var displayName: String {
        if let number = number {
            return PhoneNumber.bestEffortLocalizedPhoneNumber(e164: number)
        } else if let email = email {
            return email
        } else if let uuid = uuid {
            return uuid
        }
        return "Unknown Contact"
    }

    public var isValidForSignal: Bool {
        return signalServiceAddress != nil
    }

    public var initials: String {
        let name = displayName
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(name.prefix(1)).uppercased()
        }
    }
}

// MARK: - Extensions

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let internalContactsDidUpdate = Notification.Name("InternalContactsDidUpdate")
}
