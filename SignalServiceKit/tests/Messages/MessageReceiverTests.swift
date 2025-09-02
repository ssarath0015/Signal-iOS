//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import LibSignalClient
import XCTest

@testable import SignalServiceKit

final class MessageReceiverTests: XCTestCase {

    private var messageReceiver: MessageReceiver!
    private var mockDatabase: (any DB)!
    private var mockProfileManager: MockProfileManager!
    private var mockMessageSenderJobQueue: MockMessageSenderJobQueue!
    private var mockTsAccountManager: MockTSAccountManager!
    private var mockCallMessageHandler: MockCallMessageHandler!
    private var mockDeleteForMeSyncMessageReceiver: MockDeleteForMeSyncMessageReceiver!

    // Store original implementations to restore them in tearDown
    private var originalProfileManager: ProfileManagerProtocol!
    private var originalMessageSenderJobQueue: any MessageSenderJobQueueProtocol!
    private var originalTsAccountManager: TSAccountManager!

    override func setUp() {
        super.setUp()

        mockDatabase = InMemoryDB()
        mockProfileManager = MockProfileManager()
        mockMessageSenderJobQueue = MockMessageSenderJobQueue()
        mockTsAccountManager = MockTSAccountManager()
        mockCallMessageHandler = MockCallMessageHandler()
        mockDeleteForMeSyncMessageReceiver = MockDeleteForMeSyncMessageReceiver()

        // Replace shared instances with mocks
        originalProfileManager = SSKEnvironment.shared.profileManagerRef
        originalMessageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueueRef
        originalTsAccountManager = DependenciesBridge.shared.tsAccountManager

        SSKEnvironment.shared.profileManagerRef = mockProfileManager
        SSKEnvironment.shared.messageSenderJobQueueRef = mockMessageSenderJobQueue
        DependenciesBridge.shared.tsAccountManager = mockTsAccountManager

        // The databaseStorageRef needs to be set for the asyncWrite block
        SSKEnvironment.shared.databaseStorageRef = mockDatabase

        messageReceiver = MessageReceiver(
            callMessageHandler: mockCallMessageHandler,
            deleteForMeSyncMessageReceiver: mockDeleteForMeSyncMessageReceiver
        )
    }

    override func tearDown() {
        // Restore original shared instances
        SSKEnvironment.shared.profileManagerRef = originalProfileManager
        SSKEnvironment.shared.messageSenderJobQueueRef = originalMessageSenderJobQueue
        DependenciesBridge.shared.tsAccountManager = originalTsAccountManager

        super.tearDown()
    }

    func testHandleProfileKeyRequest() throws {
        let addExpectation = XCTestExpectation(description: "MessageSenderJobQueue.add should be called")
        mockMessageSenderJobQueue.addExpectation = addExpectation

        let sourceAci = Aci.randomForTesting()
        let localAci = Aci.randomForTesting()
        let localPni = Pni.randomForTesting()
        let localIdentifiers = LocalIdentifiers(aci: localAci, pni: localPni)
        let profileKey = try ProfileKey(bytes: [UInt8](Data(repeating: 1, count: 32))))

        mockTsAccountManager.mockLocalIdentifiers = localIdentifiers
        mockProfileManager.profileKeyToReturn = profileKey

        var dataMessage = SSKProtoDataMessage()
        dataMessage.body = "@.profilekey.$.request"

        var envelope = SSKProtoEnvelope()
        envelope.sourceAci = sourceAci.data
        envelope.sourceDevice = 1

        let decryptedEnvelope = try DecryptedIncomingEnvelope(
            validatedEnvelope: .mock(envelope: envelope),
            updatedEnvelope: envelope,
            sourceAci: sourceAci,
            sourceDeviceId: 1,
            wasReceivedByUD: false,
            plaintextData: Data(),
            isPlaintextCipher: false
        )

        let request = MessageReceiverRequest.buildRequest(
            for: decryptedEnvelope,
            serverDeliveryTimestamp: 0,
            shouldDiscardVisibleMessages: false,
            tx: try mockDatabase.newReadTransaction()
        )

        guard case .request(let messageReceiverRequest) = request else {
            XCTFail("Failed to build MessageReceiverRequest")
            return
        }

        try mockDatabase.newWriteTransaction().write { tx in
            messageReceiver.handleRequest(
                messageReceiverRequest,
                context: PassthroughDeliveryReceiptContext(),
                localIdentifiers: localIdentifiers,
                tx: tx
            )
        }

        wait(for: [addExpectation], timeout: 1.0)

        guard let addedMessage = mockMessageSenderJobQueue.addedMessage else {
            XCTFail("MessageSenderJobQueue.add was not called with a message")
            return
        }

        guard let profileKeyMessage = addedMessage.transientMessage as? OWSProfileKeyMessage else {
            XCTFail("Added message was not of type OWSProfileKeyMessage")
            return
        }

        XCTAssertEqual(profileKeyMessage.profileKey, profileKey.serialize().asData)
        XCTAssertEqual(profileKeyMessage.thread.contactAddress.aci, sourceAci)
    }
}

// MARK: - Mocks

private class MockProfileManager: ProfileManagerProtocol {
    var profileKeyToReturn: ProfileKey?
    // Implement other methods with fatalError or empty bodies as needed
    func localProfileKey(tx: GRDB.Database) -> ProfileKey? { return profileKeyToReturn }
    func setProfileKeyData(_ profileKey: Data, for aci: Aci, onlyFillInIfMissing: Bool, shouldFetchProfile: Bool, userProfileWriter: UserProfileWriter, localIdentifiers: LocalIdentifiers, authedAccount: SignalAuthenticatedAccount, tx: DBWriteTransaction) {}
    func addGroupToProfileWhitelist(groupId: Data, userProfileWriter: UserProfileWriter, transaction: DBWriteTransaction) {}
    func getProfile(for address: SignalServiceAddress, userInitiated: Bool) async throws -> SignalServiceProfile { fatalError() }
    func getProfiles(for addresses: [SignalServiceAddress], userInitiated: Bool) async throws -> [SignalServiceAddress: SignalServiceProfile] { fatalError() }
    func getOwnProfile() async throws -> SignalServiceProfile { fatalError() }
    func setProfileAvatar(image: UIImage, userInitiated: Bool) async throws -> String { fatalError() }
    func setProfileName(_ name: String, userInitiated: Bool) async throws { fatalError() }
    func addGroupId(toProfileWhitelist groupId: Data, userProfileWriter: UserProfileWriter, transaction: DBWriteTransaction) {}
    func addUser(toProfileWhitelist address: SignalServiceAddress, userProfileWriter: UserProfileWriter, transaction: DBWriteTransaction) {}
    func removeUser(fromProfileWhitelist address: SignalServiceAddress, userProfileWriter: UserProfileWriter, transaction: DBWriteTransaction) {}
}

private class MockMessageSenderJobQueue: MessageSenderJobQueueProtocol {
    var addedMessage: PreparedOutgoingMessage?
    var addExpectation: XCTestExpectation?

    func add(message: PreparedOutgoingMessage, transaction: DBWriteTransaction) {
        self.addedMessage = message
        self.addExpectation?.fulfill()
    }

    func add(messages: [PreparedOutgoingMessage], transaction: DBWriteTransaction) {
        // For simplicity, only handle single message adds
    }
}

private class MockTSAccountManager: TSAccountManager {
    var mockLocalIdentifiers: LocalIdentifiers?

    override func localIdentifiers(tx: GRDB.ReadTransaction) -> LocalIdentifiers? {
        return mockLocalIdentifiers
    }
}

private class MockCallMessageHandler: CallMessageHandler {
    func receivedEnvelope(_ envelope: SSKProtoEnvelope, callEnvelope: CallEnvelopeType, from fromAddress: (sender: Aci, senderDeviceId: DeviceId), toLocalIdentity: RegistrationState.LocalIdentity, plaintextData: Data, wasReceivedByUD: Bool, sentAtTimestamp: UInt64, serverReceivedTimestamp: UInt64, serverDeliveryTimestamp: UInt64, tx: DBWriteTransaction) {}
    func receivedGroupCallUpdateMessage(_ groupCallUpdate: SSKProtoGroupCallUpdate, forGroupId groupId: GroupIdentifier, serverReceivedTimestamp: UInt64) async {}
}

private class MockDeleteForMeSyncMessageReceiver: DeleteForMeSyncMessageReceiver {
    func handleDeleteForMeProto(deleteForMeProto: SSKProtoSyncMessageDeleteForMe, tx: DBWriteTransaction) {}
}

extension ValidatedIncomingEnvelope {
    static func mock(envelope: SSKProtoEnvelope) -> ValidatedIncomingEnvelope {
        return try! ValidatedIncomingEnvelope(envelope, localIdentifiers: .init(aci: .randomForTesting(), pni: .randomForTesting()))
    }
}
