import Foundation
import SignalServiceKit
import SignalUI
import UIKit
import GRDB
import LibSignalClient

// MARK: - Contact Exclusion Types

/// Information about whether a contact should be excluded from disappearing message updates
private struct ContactExclusionInfo {
    let isBot: Bool
    let hasDisappearingTimeoutException: Bool
    let lastUpdated: Date
}

// MARK: - ArmourInternalContactManager

class ArmourInternalContactManager {

    static let shared = ArmourInternalContactManager()

    // MARK: - Properties
    private var internalContacts: [ArmourServerContact] = []

    // Contact exclusion data for disappearing message management
    private var contactExclusionData: [String: ContactExclusionInfo] = [:]

    private var databaseStorage: SDSDatabaseStorage {
        return SSKEnvironment.shared.databaseStorageRef
    }
    private var signalService: OWSSignalServiceProtocol {
        return SSKEnvironment.shared.signalServiceRef
    }

    // MARK: - Existing Service Integration
    private lazy var contactsService: ContactsService = {
        return ContactsService(signalService: signalService)
    }()

    private init() {}

    // MARK: - Public API

    func syncInternalContacts(completion: @escaping (Error?) -> Void) {
        guard let phoneNumber = DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.phoneNumber else {
            Logger.error("No phone number found for logged-in user.")
            completion(ContactsServiceError.usernameNotFound)
            return
        }

        Task {
            do {
                Logger.info("Starting internal contacts sync...")
                let fetchedContacts = try await contactsService.getContactsWithGroup(username: phoneNumber)
                Logger.info("Fetched \(fetchedContacts.count) contacts from server")

                    // Store contact exclusion data locally to handle disappearing message exclusions
    // This ensures that contacts with bot=true or disappearingTimeoutException=true
    // are excluded from disappearing message updates
    self.updateContactExclusionData(fetchedContacts)
    Logger.info("Updated contact exclusion data for \(fetchedContacts.count) contacts")

                await self.processInternalContacts(fetchedContacts)

                DispatchQueue.main.async {
                    completion(nil)
                }
            } catch {
                Logger.error("Failed to sync internal contacts: \(error)")
                DispatchQueue.main.async {
                    completion(error)
                }
            }
        }
    }

    func getAllInternalContacts() -> [ArmourServerContact] {
        return internalContacts
    }

    func searchContacts(query: String) -> [ArmourServerContact] {
        guard !query.isEmpty else { return internalContacts }

        let lowercaseQuery = query.lowercased()
        return internalContacts.filter { contact in
            contact.displayName.lowercased().contains(lowercaseQuery) ||
            (contact.number?.contains(query) ?? false) ||
            (contact.email?.lowercased().contains(lowercaseQuery) ?? false)
        }
    }

    func createSignalThread(for contact: ArmourServerContact, completion: @escaping (TSContactThread?, Error?) -> Void) {
        Logger.info("Creating Signal thread for contact: \(contact.displayName)")

        guard let address = contact.signalServiceAddress else {
            Logger.error("No Signal address for contact: \(contact.displayName)")
            completion(nil, ContactsServiceError.usernameNotFound)
            return
        }

        Logger.info("Contact address: \(address), isValid: \(address.isValid)")

        var createdThread: TSContactThread?
        databaseStorage.asyncWrite { transaction in
            Logger.info("Creating thread in database for address: \(address)")
            createdThread = TSContactThread.getOrCreateThread(withContactAddress: address, transaction: transaction)
            Logger.info("Thread created: \(createdThread?.uniqueId ?? "nil")")
            self.createOrUpdateSignalAccount(for: contact, transaction: transaction)
        } completion: {
            DispatchQueue.main.async {
                if let thread = createdThread {
                    Logger.info("Successfully created thread: \(thread.uniqueId) for contact: \(contact.displayName)")
                } else {
                    Logger.error("Failed to create thread for contact: \(contact.displayName)")
                }
                completion(createdThread, nil)
            }
        }
    }

    // MARK: - Internal Processing

    @MainActor
    private func processInternalContacts(_ contacts: [ArmourServerContact]) async {
        let validContacts = contacts.filter { $0.isValidForSignal }
        self.internalContacts = validContacts

        Logger.info("Processing \(validContacts.count) valid internal contacts")

        // Process in batches
        let batchSize = 25
        for i in stride(from: 0, to: validContacts.count, by: batchSize) {
            let endIndex = min(i + batchSize, validContacts.count)
            let batch = Array(validContacts[i..<endIndex])
            await processBatch(batch)
        }

        // After processing, mark removed contacts as unregistered
        databaseStorage.asyncWrite { transaction in
            self.markRemovedContactsAsUnregistered(fetchedContacts: validContacts, transaction: transaction)
        } completion: {
            NotificationCenter.default.post(name: .internalContactsDidUpdate, object: nil)
        }
    }

    private func processBatch(_ contacts: [ArmourServerContact]) async {
        await withCheckedContinuation { continuation in
            databaseStorage.asyncWrite { transaction in
                for contact in contacts {
                    self.createSignalEntities(for: contact, transaction: transaction)
                }
                continuation.resume()
            }
        }
    }

    private func createSignalEntities(for contact: ArmourServerContact, transaction: DBWriteTransaction) {
        guard let address = contact.signalServiceAddress else { return }

        // Create SignalAccount for contact display
        createOrUpdateSignalAccount(for: contact, transaction: transaction)

        // Use proper recipient management APIs instead of manual creation
        let recipientManager = DependenciesBridge.shared.recipientManager
        let recipientDatabaseTable = DependenciesBridge.shared.recipientDatabaseTable

        // Try to find existing recipient by address
        let existingRecipient = recipientDatabaseTable.fetchRecipient(
            address: address,
            tx: transaction
        )

        if let recipient = existingRecipient {
            // Update existing recipient - keep them registered if they were registered
            Logger.info("Updating existing recipient: \(contact.displayName)")

            // If they weren't registered, mark them as registered since they're on the server
            if !recipient.isRegistered {
                Logger.info("Marking existing recipient as registered: \(contact.displayName)")
                recipientManager.markAsRegisteredAndSave(
                    recipient,
                    deviceId: .primary,
                    shouldUpdateStorageService: true,
                    tx: transaction
                )
            }
        } else {
            // Create new recipient using proper API
            Logger.info("Creating new recipient: \(contact.displayName)")
            let newRecipient = SignalRecipient(
                aci: address.aci,
                pni: nil,
                phoneNumber: address.phoneNumber.flatMap { E164($0) },
                deviceIds: [.primary]
            )
            recipientDatabaseTable.insertRecipient(newRecipient, transaction: transaction)

            // Mark as registered since they're on the server
            recipientManager.markAsRegisteredAndSave(
                newRecipient,
                deviceId: .primary,
                shouldUpdateStorageService: true,
                tx: transaction
            )
        }
    }

    private func createOrUpdateSignalAccount(for contact: ArmourServerContact, transaction: DBWriteTransaction) {
        guard let address = contact.signalServiceAddress else { return }

        // Try to fetch existing SignalAccount
        let existingAccount = SignalAccount.anyFetch(uniqueId: address.phoneNumber ?? "", transaction: transaction)

        if let account = existingAccount {
            // Update existing account
            account.givenName = contact.displayName
            account.fullName = contact.displayName
            account.anyUpsert(transaction: transaction)
        } else {
            // Create new account
            let newAccount = SignalAccount(
                recipientPhoneNumber: contact.number,
                recipientServiceId: address.serviceId,
                multipleAccountLabelText: nil,
                cnContactId: nil,
                givenName: contact.displayName,
                familyName: "",
                nickname: "",
                fullName: contact.displayName,
                contactAvatarHash: nil
            )
            newAccount.anyUpsert(transaction: transaction)
        }
    }

    // New helper to mark removed contacts as unregistered
    private func markRemovedContactsAsUnregistered(fetchedContacts: [ArmourServerContact], transaction: DBWriteTransaction) {
        // Build a set of identifiers for fetched contacts (using phone number as key)
        let fetchedNumbers = Set(fetchedContacts.compactMap { $0.number })

        // Enumerate all local recipients and mark removed ones as unregistered
        DependenciesBridge.shared.recipientDatabaseTable.enumerateAll(tx: transaction) { recipient in
            guard let phoneNumber = recipient.phoneNumber?.stringValue else { return }
            if !fetchedNumbers.contains(phoneNumber) {
                // Mark as unregistered if currently registered
                if recipient.isRegistered {
                    let recipientManager = DependenciesBridge.shared.recipientManager
                    recipientManager.markAsUnregisteredAndSave(
                        recipient,
                        unregisteredAt: .now,
                        shouldUpdateStorageService: true,
                        tx: transaction
                    )
                    Logger.info("Marked recipient as unregistered: \(phoneNumber)")
                }
            }
        }
    }

    // MARK: - Contact Exclusion Management

    /// Update contact exclusion data for disappearing message management
    private func updateContactExclusionData(_ contacts: [ArmourServerContact]) {
        for contact in contacts {
            guard let key = contact.number else { continue }
            let exclusionInfo = ContactExclusionInfo(
                isBot: contact.bot ?? false,
                hasDisappearingTimeoutException: contact.disappearingTimeoutException ?? false,
                lastUpdated: Date()
            )
            contactExclusionData[key] = exclusionInfo
        }

        Logger.info("Updated contact exclusion data for \(contacts.count) contacts")

        // Post notification that contact exclusion data has been updated
        NotificationCenter.default.post(
            name: NSNotification.Name("contactExclusionDataDidUpdate"),
            object: nil
        )
    }

    /// Check if a contact should be excluded from disappearing message updates
    func shouldSkipDisappearingMessageUpdate(for contactNumber: String) -> Bool {
        guard let exclusionInfo = contactExclusionData[contactNumber] else {
            return false // No exclusion data, allow updates
        }

        return exclusionInfo.isBot || exclusionInfo.hasDisappearingTimeoutException
    }

    /// Check if a thread should be excluded from disappearing message updates
    func shouldSkipDisappearingMessageUpdate(for thread: TSThread) -> Bool {
        guard let contactThread = thread as? TSContactThread else {
            return false // Not a contact thread, allow updates
        }

        let contactNumber = contactThread.contactAddress.phoneNumber
        guard let contactNumber = contactNumber else {
            return false // No phone number, allow updates
        }

        return shouldSkipDisappearingMessageUpdate(for: contactNumber)
    }

    // MARK: - Setup

    static func setupInternalContactSystem() {
        let manager = ArmourInternalContactManager.shared
        manager.syncInternalContacts { error in
            if let error = error {
                Logger.error("Initial contact sync failed: \(error)")
            } else {
                Logger.info("Contact system initialized successfully")
            }
        }

        // Set up privilege update observer to trigger disappearing message updates
        manager.setupPrivilegeUpdateObserver()
    }

            /// Set up privilege update observer to trigger disappearing message updates
        func setupPrivilegeUpdateObserver() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userPrivilegesDidUpdate),
                name: NSNotification.Name("userPrivilegesDidUpdate"),
                object: nil
            )

            // Also listen for the clear disappearing message timers notification
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clearAPIControlledDisappearingMessageTimers),
                name: NSNotification.Name("clearAPIControlledDisappearingMessageTimers"),
                object: nil
            )

            // Listen for contact exclusion check requests from DisappearingMessagesConfigurationStore
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleContactExclusionCheck),
                name: NSNotification.Name("checkContactExclusion"),
                object: nil
            )
        }

        /// Handle privilege updates by forcing disappearing message configuration updates
        @objc private func userPrivilegesDidUpdate(_ notification: Notification) {
            Logger.info("[ContactExclusion] 🔍 FILTER_TAG: User privileges updated, checking disappearing message configurations")

            // Get the current API timer value
            let currentAPITimer = UserPrivilegeAccess.disappearingMessageTimer
            Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Current API timer value: \(currentAPITimer) hours")

            // Force update all disappearing message configurations from API privileges
            // This ensures that when disappearMessageTimer changes (e.g., from 48 to 0),
            // all configurations are properly updated
            SSKEnvironment.shared.databaseStorageRef.asyncWrite { tx in
                var updatedCount = 0

                // Get all threads and update their configurations
                let threads = TSThread.anyFetchAll(transaction: SDSDB.shimOnlyBridge(tx))
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Found \(threads.count) threads to update")

                for (index, thread) in threads.enumerated() {
                    Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Updating thread \(index + 1)/\(threads.count): \(thread.uniqueId)")

                    if DependenciesBridge.shared.disappearingMessagesConfigurationStore.updateFromAPIIfNeeded(
                        for: .thread(thread),
                        tx: tx
                    ) {
                        updatedCount += 1
                        Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Successfully updated thread: \(thread.uniqueId)")
                    } else {
                        Logger.info("[ContactExclusion] 🔍 FILTER_TAG: No update needed for thread: \(thread.uniqueId)")
                    }
                }

                if updatedCount > 0 {
                    Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Updated \(updatedCount) disappearing message configurations after privilege change")
                } else {
                    Logger.info("[ContactExclusion] 🔍 FILTER_TAG: No disappearing message configurations were updated")
                }
            }
        }

        /// Handle the clear API-controlled disappearing message timers notification
        @objc private func clearAPIControlledDisappearingMessageTimers(_ notification: Notification) {
            Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Received clear API-controlled disappearing message timers notification")

            // Get the current API timer value to verify it's still 0
            let currentAPITimer = UserPrivilegeAccess.disappearingMessageTimer
            Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Current API timer value: \(currentAPITimer) hours")

            guard currentAPITimer == 0 else {
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: API timer is no longer 0 (\(currentAPITimer)), skipping clear operation")
                return
            }

            // Clear all API-controlled disappearing message timers
            SSKEnvironment.shared.databaseStorageRef.asyncWrite { tx in
                var clearedCount = 0

                // Get all threads
                let threads = TSThread.anyFetchAll(transaction: SDSDB.shimOnlyBridge(tx))
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Found \(threads.count) threads to check for API-controlled timers")

                for (index, thread) in threads.enumerated() {
                    Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Checking thread \(index + 1)/\(threads.count): \(thread.uniqueId)")

                    if self.clearAPIControlledTimerForThread(thread, tx: tx) {
                        clearedCount += 1
                        Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Successfully cleared timer for thread: \(thread.uniqueId)")
                    } else {
                        Logger.info("[ContactExclusion] 🔍 FILTER_TAG: No timer cleared for thread: \(thread.uniqueId)")
                    }
                }

                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Final result - Cleared \(clearedCount) API-controlled disappearing message timers")

                // Post notification that configurations were updated
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("disappearingMessageConfigurationsCleared"),
                        object: nil
                    )
                }
            }
        }

        /// Clear API-controlled timer for a specific thread
        ///
        /// FIXED: This method now properly clears API-controlled timers when disappearMessageTimer: 0
        /// The previous approach tried to restore "local" configs, but these were often the same
        /// as the current config due to previous API overwrites, causing the comparison to fail.
        ///
        /// New approach: Force create a cleared configuration (disabled, 0 duration, local version)
        /// when an API-controlled timer is found and the API timer is 0.
        private func clearAPIControlledTimerForThread(_ thread: TSThread, tx: DBWriteTransaction) -> Bool {
            // Check if this thread should be excluded from disappearing message updates
            if shouldSkipDisappearingMessageUpdate(for: thread) {
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Thread \(thread.uniqueId) is excluded from disappearing message updates (bot or disappearingTimeoutException)")
                return false // Skip this thread due to exclusion
            }

            let dmStore = DependenciesBridge.shared.disappearingMessagesConfigurationStore
            let currentConfig = dmStore.fetch(for: .thread(thread), tx: tx) // Use fetch to get persisted config

            Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Checking thread: \(thread.uniqueId)")
            Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Current config: \(currentConfig?.description ?? "nil")")

            guard let configToClear = currentConfig else {
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: No config found for thread: \(thread.uniqueId), nothing to clear")
                return false // No config found, nothing to clear
            }

            Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Thread \(thread.uniqueId) - timerVersion: \(configToClear.timerVersion), isEnabled: \(configToClear.isEnabled), durationSeconds: \(configToClear.durationSeconds)")

            // Check if this thread has an API-controlled timer (timerVersion == 1)
            if configToClear.timerVersion == 1 && configToClear.isEnabled {
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Found API-controlled timer for thread: \(thread.uniqueId)")

                // CRITICAL FIX: When API timer is 0, we need to force clear the API-controlled timer
                // The previous approach of trying to restore "local" config was flawed because:
                // 1. The "local" config may have been overwritten by previous API calls
                // 2. fetchOrBuildDefault returns the same config that's already stored
                // 3. This causes the comparison to fail and no update happens
                //
                // Solution: Force create a new cleared configuration when API timer is 0
                let clearedConfig = OWSDisappearingMessagesConfiguration(
                    threadId: thread.uniqueId,
                    enabled: false, // Disable disappearing messages when API timer is 0
                    durationSeconds: 0, // Set to 0 seconds
                    timerVersion: 0 // Reset to local version (not API-controlled)
                )

                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Creating cleared config: \(clearedConfig.description)")
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Old config was: timerVersion: \(configToClear.timerVersion), isEnabled: \(configToClear.isEnabled), durationSeconds: \(configToClear.durationSeconds)")
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: New config will be: timerVersion: \(clearedConfig.timerVersion), isEnabled: \(clearedConfig.isEnabled), durationSeconds: \(clearedConfig.durationSeconds)")

                // Always update when clearing API-controlled timer
                clearedConfig.anyUpsert(transaction: SDSDB.shimOnlyBridge(tx))
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Successfully cleared API-controlled timer for thread: \(thread.uniqueId)")
                return true

            } else {
                Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Thread \(thread.uniqueId) does not have API-controlled timer (timerVersion: \(configToClear.timerVersion), isEnabled: \(configToClear.isEnabled))")
            }

                    return false
    }

    // MARK: - Contact Exclusion Check Handler

    /// Handle contact exclusion check requests from DisappearingMessagesConfigurationStore
    /// This method responds to notifications when the store needs to check if a contact
    /// should be excluded from disappearing message updates
    @objc private func handleContactExclusionCheck(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let phoneNumber = userInfo["phoneNumber"] as? String else {
            Logger.error("[ContactExclusion] Invalid contact exclusion check notification - missing phoneNumber")
            return
        }

        Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Received contact exclusion check for phone number: \(phoneNumber)")

        // Check if this contact should be excluded using the existing data-driven method
        let shouldExclude = shouldSkipDisappearingMessageUpdate(for: phoneNumber)

        Logger.info("[ContactExclusion] 🔍 FILTER_TAG: Contact exclusion result for \(phoneNumber): \(shouldExclude)")

        // Post a response notification with the result
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("contactExclusionCheckResponse"),
                object: nil,
                userInfo: [
                    "phoneNumber": phoneNumber,
                    "isExcluded": shouldExclude
                ]
            )
        }
    }

    /// Check if a contact should be excluded from disappearing message updates
    /// This method checks the contact exclusion data for the given address
    private func shouldExcludeContactFromDisappearingMessageUpdates(_ address: SignalServiceAddress) -> Bool {
        // Get the phone number from the address
        guard let phoneNumber = address.phoneNumber else {
            Logger.info("[ContactExclusion] No phone number for address \(address), allowing disappearing message updates")
            return false
        }

        // Check if this contact should be excluded based on stored exclusion data
        let shouldExclude = shouldSkipDisappearingMessageUpdate(for: phoneNumber)

        if shouldExclude {
            Logger.info("[ContactExclusion] Contact \(phoneNumber) is excluded from disappearing message updates")
        } else {
            Logger.info("[ContactExclusion] Contact \(phoneNumber) is allowed to receive disappearing message updates")
        }

        return shouldExclude
    }
}

// MARK: - Extensions

extension Notification.Name {
    static let internalContactsDidUpdate = Notification.Name("InternalContactsDidUpdate")
    static let contactExclusionDataDidUpdate = Notification.Name("contactExclusionDataDidUpdate")
}
