# Push Notification Registration Flow in Signal for iOS

This document outlines the process of how the Signal iOS app registers for push notifications. It is divided into two sections: a non-technical overview and a detailed technical explanation.

## Non-Technical Explanation

Push notifications are the alerts that pop up on your phone's screen to let you know you have a new message in Signal. For this to work, the Signal app needs to talk to Apple's Push Notification service (APNs). Here's a simple breakdown of how it happens:

1.  **Asking for Permission:** The first time you open Signal, it asks for your permission to send you notifications. You have to agree to receive these alerts.
2.  **Getting a Special Address:** Once you give permission, the app asks Apple for a unique, anonymous address for your device. This is like a special mailing address that only Apple knows how to deliver to. This address is called a "device token."
3.  **Sharing the Address with Signal:** The app receives this device token from Apple and then sends it to Signal's servers.
4.  **Ready to Receive Notifications:** Now, when someone sends you a message, Signal's servers don't send the message directly to your phone. Instead, they tell Apple's service, "Hey, send a notification to this address." Apple's service then finds your device and delivers the alert.

This process ensures that Signal doesn't need to be constantly running in the background, which saves your battery. It's a secure and efficient way to make sure you get your messages right away.

## Technical Explanation

The push notification registration process is managed primarily by the `PushRegistrationManager` class, with the `AppDelegate` serving as the initial entry point for system callbacks. The entire flow is asynchronous and relies heavily on Promises to manage the callbacks and data flow.

### 1. Kicking off the Registration

The process is initiated by calling the `requestPushTokens(forceRotation:timeOutEventually:)` method on the `PushRegistrationManager` singleton.

```swift
// Signal/Notifications/PushRegistrationManager.swift

public func requestPushTokens(
    forceRotation: Bool,
    timeOutEventually: Bool = false
) -> Promise<ApnRegistrationId> {
    Logger.info("")
    return Promise.wrapAsync {
        await self.registerUserNotificationSettings()
    }.then { (_) -> Promise<ApnRegistrationId> in
        #if targetEnvironment(simulator)
        if TSConstants.isUsingProductionService {
            throw PushRegistrationError.pushNotSupported(description: "Production APNs isn't supported on simulators.")
        }
        #endif

        return self
            .registerForVanillaPushToken(
                forceRotation: forceRotation,
                timeOutEventually: timeOutEventually
            ).map { [self] vanillaPushToken in
                // We need the voip registry to handle voip pushes relayed from the NSE.
                createVoipRegistryIfNecessary()
                return ApnRegistrationId(apnsToken: vanillaPushToken)
            }
    }
}
```

### 2. Requesting User Authorization

The `requestPushTokens` method first calls `registerUserNotificationSettings()` to ensure the app has the user's permission to display notifications.

```swift
// Signal/Notifications/PushRegistrationManager.swift

public func registerUserNotificationSettings() async {
    await SSKEnvironment.shared.notificationPresenterRef.registerNotificationSettings()
}
```

### 3. Registering with APNs

Once authorization is confirmed, `registerForVanillaPushToken(forceRotation:timeOutEventually:)` is called. This method is responsible for initiating the registration with Apple's Push Notification service (APNs).

```swift
// Signal/Notifications/PushRegistrationManager.swift

private func registerForVanillaPushToken(
    forceRotation: Bool,
    timeOutEventually: Bool
) -> Promise<String> {
    AssertIsOnMainThread()
    Logger.info("")

    // ... (promise creation logic)

    if forceRotation {
        UIApplication.shared.unregisterForRemoteNotifications()
    }
    UIApplication.shared.registerForRemoteNotifications()

    // ... (promise handling logic)
}
```

The key call here is `UIApplication.shared.registerForRemoteNotifications()`. This is a system call that tells iOS to request a device token from APNs.

### 4. Receiving the Device Token

When the device successfully registers with APNs, the system calls the `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` method in the `AppDelegate`.

```swift
// Signal/AppLaunch/AppDelegate.swift

func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    AssertIsOnMainThread()

    if didAppLaunchFail {
        return
    }

    Logger.info("")
    AppEnvironment.shared.pushRegistrationManagerRef.didReceiveVanillaPushToken(deviceToken)
}
```

The `AppDelegate` then passes the `deviceToken` to the `PushRegistrationManager` by calling `didReceiveVanillaPushToken(_:)`.

### 5. Handling the Token in PushRegistrationManager

The `didReceiveVanillaPushToken(_:)` method in `PushRegistrationManager` takes the token and resolves the promise that was created in `registerForVanillaPushToken`.

```swift
// Signal/Notifications/PushRegistrationManager.swift

@objc
public func didReceiveVanillaPushToken(_ tokenData: Data) {
    guard let vanillaTokenFuture = self.vanillaTokenFuture else {
        Logger.warn("System volunteered a push token even though we didn't request one. Syncing.")
        Task {
            do {
                try await SyncPushTokensJob(mode: .normal).run()
                Logger.info("Done syncing push tokens after system volunteered one.")
            } catch {
                Logger.error("Failed to sync push tokens after system volunteered one.")
            }
        }
        return
    }

    vanillaTokenFuture.resolve(tokenData)
}
```

This resolution propagates up the promise chain, and the original caller of `requestPushTokens` receives the `ApnRegistrationId` containing the token. This token is then sent to the Signal server to be associated with the user's account.

### Error Handling

If the registration fails, the system calls `application(_:didFailToRegisterForRemoteNotificationsWithError:)` in the `AppDelegate`, which in turn calls `didFailToReceiveVanillaPushToken(error:)` in the `PushRegistrationManager` to reject the promise and handle the error.

```swift
// Signal/AppLaunch/AppDelegate.swift

func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    AssertIsOnMainThread()

    if didAppLaunchFail {
        return
    }

    Logger.warn("")
    #if DEBUG
    AppEnvironment.shared.pushRegistrationManagerRef.didReceiveVanillaPushToken(Data(count: 32))
    #else
    AppEnvironment.shared.pushRegistrationManagerRef.didFailToReceiveVanillaPushToken(error: error)
    #endif
}
```

### VoIP Notifications

The `PushRegistrationManager` also sets up a `PKPushRegistry` to handle VoIP notifications, which are used for calls. This is a separate but related flow that uses the same underlying principles.
