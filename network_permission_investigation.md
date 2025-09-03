# Local Network Permission Investigation

## Finding
The local network permission is requested for the "Device Transfer" feature, which allows a user to transfer their Signal account from an old device to a new one over the local network.

## Trigger
The code responsible for this is located in the `Signal/DeviceTransfer/DeviceTransferService.swift` file. Specifically, the initialization of `MCNearbyServiceBrowser` and `MCNearbyServiceAdvertiser` classes from Apple's `MultipeerConnectivity` framework triggers the permission request. These classes use Bonjour to discover and advertise services on the local network.

The permission message is defined in `Signal/Signal-Info.plist` under the `NSLocalNetworkUsageDescription` key. The Bonjour service type is also defined in this file under the `NSBonjourServices` key.
