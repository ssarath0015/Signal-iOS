//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import GRDB

public class KeyExchangeManager {
    public static let shared = KeyExchangeManager()

    private init() {}

    public func sendKeyExchangeRequestIfNeeded(for thread: TSContactThread, transaction: DBReadTransaction) {
        let contactAddress = thread.contactAddress

        do {
            let profileKeyRecord = try ProfileKeyRecord.fetch(aci: contactAddress.aci, tx: transaction)
            if profileKeyRecord == nil {
                // No profile key, so send a request.
                self.sendProfileKeyRequest(to: thread)
            }
        } catch {
            Logger.warn("Failed to fetch profile key record: \(error)")
        }
    }

    private func sendProfileKeyRequest(to thread: TSContactThread) {
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { transaction in
            let message = OWSProfileKeyRequestMessage(thread: thread, transaction: transaction)
            let preparedMessage = PreparedOutgoingMessage.preprepared(
                transientMessageWithoutAttachments: message
            )
            SSKEnvironment.shared.messageSenderJobQueueRef.add(message: preparedMessage, transaction: transaction)
        }
    }
}
