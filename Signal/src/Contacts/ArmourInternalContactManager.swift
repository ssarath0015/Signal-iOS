//
//  Copyright © 2025 MyCustomCompany. All rights reserved.
//

import Foundation
import SignalServiceKit

public struct InternalContact {
    public let number: String
    // You can add other properties here as needed, e.g., name, profile picture, etc.
}

public class ArmourInternalContactManager {

    public static let shared = ArmourInternalContactManager()

    private let contactsManager: OWSContactsManager

    private init() {
        // Assuming we can get the standard contacts manager from the environment.
        self.contactsManager = SSKEnvironment.shared.contactsManager
    }

    /// Returns all known Signal contacts.
    /// In a real implementation, you might want to filter this list
    /// or fetch it from a different source.
    public func getAllInternalContacts() -> [InternalContact] {
        let allSignalContacts = contactsManager.allSignalContacts

        let internalContacts = allSignalContacts.map { contact -> InternalContact in
            // Assuming the 'number' is the E.164 phone number.
            let number = contact.recipientAddress.toE164() ?? ""
            return InternalContact(number: number)
        }

        return internalContacts.filter { !$0.number.isEmpty }
    }
}
