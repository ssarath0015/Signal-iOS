//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

public class MessageRequestManager {
    public static let shared = MessageRequestManager()

    private init() {}

    public func acceptMessageRequestIfNecessary(for thread: TSThread, transaction: DBWriteTransaction) {
        guard let contactThread = thread as? TSContactThread else {
            return
        }

        let armourContacts = ArmourInternalContactManager.shared.getAllInternalContacts()
        let contactPhoneNumber = contactThread.contactAddress.phoneNumber

        let isArmourContact = armourContacts.contains { $0.number == contactPhoneNumber }

        if isArmourContact {
            // This is an internal contact, so we can auto-accept the message request.
            SSKEnvironment.shared.messageRequestManager.acceptMessageRequest(
                in: thread,
                mode: .contactOrGroupRequest,
                unblockThread: true,
                unhideRecipient: true,
                transaction: transaction
            )
        }
    }
}
