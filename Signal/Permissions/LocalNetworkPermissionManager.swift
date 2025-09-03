//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MultipeerConnectivity
import SignalServiceKit

// A helper class to request local network permissions.
//
// This is done by briefly starting and stopping a `MCNearbyServiceBrowser`,
// which will trigger the iOS permission prompt if the permission has not
// yet been granted.
//
// This is a bit of a hack, but it's the only way to request this permission
// without having to instantiate the entire `DeviceTransferService`.
//
// See: https://developer.apple.com/forums/thread/663268
class LocalNetworkPermissionManager: NSObject, MCNearbyServiceBrowserDelegate {

    private var browser: MCNearbyServiceBrowser?
    private var completion: (() -> Void)?

    func requestLocalNetworkAuthorization(completion: @escaping () -> Void) {
        self.completion = completion

        // We need to hold a strong reference to the browser, so we assign it to a property.
        let peerId = MCPeerID(displayName: UUID().uuidString)
        browser = MCNearbyServiceBrowser(peer: peerId, serviceType: "sgnl-permission")
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        // The permission prompt is shown asynchronously. We'll stop browsing after a short
        // delay, which is enough time for the prompt to be displayed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.browser?.stopBrowsingForPeers()
            self.browser = nil
            self.completion?()
            self.completion = nil
        }
    }

    func needsLocalNetworkAuthorization() -> Guarantee<Bool> {
        // For now, we always show the permission prompt.
        return .value(true)
    }

    // MARK: - MCNearbyServiceBrowserDelegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Do nothing
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Do nothing
    }
}
