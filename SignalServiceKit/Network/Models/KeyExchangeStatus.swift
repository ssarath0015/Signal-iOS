//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

public class KeyExchangeStatus: Record {
    public var contactIdentifier: String
    public var timestamp: Int64

    public override class var databaseTableName: String {
        "KeyExchangeStatus"
    }

    public init(contactIdentifier: String, timestamp: Int64) {
        self.contactIdentifier = contactIdentifier
        self.timestamp = timestamp
        super.init()
    }

    public required init(row: Row) throws {
        contactIdentifier = row["contactIdentifier"]
        timestamp = row["timestamp"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["contactIdentifier"] = contactIdentifier
        container["timestamp"] = timestamp
    }
}
