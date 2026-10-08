# Mac ↔ iPhone offline prototype

Native SwiftUI app for macOS 14+ and iOS 17+. It uses Multipeer Connectivity to discover and connect nearby Apple devices without a cloud service. Keep Wi-Fi and Bluetooth enabled. Mobile data and internet access are unnecessary during app operation.

The Apple version uses the same v1 JSON envelope as Android. **The Apple and Android apps cannot connect to each other yet**: their radio transports differ. A future shared BLE or Wi-Fi transport/bridge is needed.

## Usernames and contact chats (0.3.0)

Update and run **both** Apple apps, then:

1. Enter your username in **Your profile** and press **Save**.
2. Press **Start network** on both devices.
3. Search for the other username under **Find people nearby**; compare the eight-character device ID if names match.
4. Press **Request chat** on one device. The other person chooses **Accept** or **Reject**.
5. After acceptance and connection, select the saved contact and send text in their chat.
6. Reconnect accepted contacts from Nearby after a restart. Messages to offline contacts queue for up to one hour.

Usernames are local aliases, not globally registered accounts or login credentials. Duplicate usernames are allowed and kept separate by device UUID. There is no global search, account recovery or multi-device account synchronization. Profiles and accepted contacts persist locally; unanswered requests are live session invitations and expire.

The contact UI sends only to the selected, approved session peer. It rejects messages from unaccepted contacts, mismatched sender identities and other recipients before storage or receipt generation. It also checks incoming receipts against the original outgoing message. It does **not** relay contact conversations through other devices; the original mesh engine remains available separately for broadcast/routing work. Both devices need the updated chat build; earlier broadcast-only versions will not appear in chat discovery. Session encryption is enabled, but UUIDs/usernames remain self-claimed and are not cryptographically authenticated.

Fourteen core checks pass, including profile persistence, duplicate names, contact acceptance gates, recipient/source filtering, directed receipts and queued delivery. Native Mac compilation and unsigned iPhone-device compilation pass. Physical acceptance/rejection and three-device chat isolation still require device testing.

## Run on this Mac

The local Apple Silicon development build is at `output/Semantic Mesh.app` (generated, not checked into Git).

```sh
apple/scripts/build-mac.sh
open 'apple/output/Semantic Mesh.app'
```

Start the network and allow Local Network access if macOS requests it. If discovery fails after declining, enable the app in System Settings → Privacy & Security → Local Network, then Stop/Start.

The downloadable Mac ZIP is ad-hoc signed for development, not notarized. The local source build avoids downloading the binary. Install/run the app from a stable location; moving or rebuilding ad-hoc signed applications can affect macOS permission handling.

## Install on iPhone 16

A Mac command-line build cannot install an iPhone app. Use full **Xcode compatible with your phone's iOS version**; Xcode is not installed on the development Mac used for this change.

1. Install Xcode from Apple and complete its first launch setup.
2. Open `apple/SemanticMesh.xcodeproj` in Xcode.
3. Select scheme **SemanticMesh** (the **SemanticMeshMac** scheme is the Mac app).
4. Connect the unlocked iPhone by USB and accept the Trust prompt.
5. In Xcode Settings → Apple Accounts, sign in with your Apple ID. In target SemanticMesh → Signing & Capabilities, select your Personal Team and enable automatic signing. Use a unique bundle identifier if Xcode requests it.
6. Choose your iPhone as the run destination. Enable Developer Mode when Xcode requests it, following the phone's restart/confirmation prompts.
7. Press Run. On iPhone, start the network and allow Local Network access. Keep the app open and the screen awake.

A personal Apple account is sufficient for local development signing; personal-team provisioning has restrictions and may need renewal. Signing/build setup can require internet, while the installed app's messaging works offline.

Official instructions: [run on a physical device](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices), [enable Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## First real offline test

1. Start the app on Mac and iPhone. Keep Wi-Fi and Bluetooth ON; turn iPhone mobile data OFF.
2. Start network on both. On one device, find the other's `Mesh-xxxxxxxx` name and press Connect. Accept the invitation on the other device. Invite from only one side at a time.
3. Wait until both show one connected peer.
4. Send `Mac test 1` and `iPhone test 1`. Compare ID prefixes. The sender should show “Stored by 1 peer(s)”.
5. To prove internet independence, test with the router's internet uplink disconnected. A shared LAN test proves offline operation but still uses network infrastructure.
6. To test infrastructure-free Apple peer-to-peer operation, disconnect both devices from joined Wi-Fi networks while leaving Wi-Fi enabled; also disconnect Mac Ethernet/VPN and disable iPhone mobile data. Repeat discovery and messaging. Do not turn Wi-Fi off as in the Android Bluetooth test.
7. Stop the iPhone network. Send from Mac; it should remain locally stored. Restart/reconnect the iPhone within one hour; it should receive the same ID exactly once. A repeat receipt or duplicate text should not appear.
8. Quit/reopen both apps and reconnect; verify persisted messages and receipts.

Do not count the iOS Simulator as a physical peer for radio acceptance tests. Keep a record of device/OS versions, connectivity settings, message IDs and failures. On iPhone, going into the background stops this prototype's network; return and press Start again. Messages remain stored.

## Implementation and limits

- Separate transport, envelope, persistent store and routing engine. JSON frames are capped at 16 KiB; text at 2,000 UTF-16 units to match Android; IDs are UUIDs.
- One-hour wall-clock expiry, eight-hop bound, durable ID deduplication. Clocks must roughly agree.
- Atomic JSON file storage capped at 5,000 live envelopes. Node identity and messages are excluded from backups. Corrupt storage disables sending instead of silently erasing history.
- App receipts report that another app persisted the message. They do not mean a human read it or verified its contents.
- Encrypted sessions (`.required`) and explicit invitation approval. No end-to-end signatures, authenticated node identity, trusted groups or revocation. Nearby names and receipts may be forged.
- Live messages are replayed upon connection and every 15 seconds. Full-store replay is deliberately simple and inefficient; per-peer inventory sync and backpressure are future work.
- Broadcast multi-hop in the core engine is application-level flooding, not a guarantee that Multipeer Connectivity exposes a chosen physical radio topology. Three-node core simulation passes; physical three-device routing is unverified.
- The UI shows the latest 100 live text messages; the store retains up to its cap.
- Apple's current documentation deprecates Multipeer Connectivity in favor of Network framework. This implementation is isolated so a replacement transport can retain the protocol.

## Checks

```sh
apple/scripts/test-core.sh      # 8 portable checks; requires only Apple Command Line Tools
apple/scripts/build-mac.sh      # native Mac UI + transport compilation
swift test --package-path apple # XCTest suite; requires full Xcode with XCTest available
```

The original eight local core checks covered: Android JSON compatibility, forwarding invariants, bounds/invalid data, persistence/dedup/expiry, three-node simulated relay/receipts, disconnected forwarding, and no forwarding after expiry or hop eight. Mac compilation and development signature verification passed. Local UI automation failed; interactive launch, real wireless discovery and Mac↔iPhone delivery are unverified. The [GitHub Apple check](https://github.com/utkarshbaliyan/semantic-mesh/actions/runs/37364315123) passed the XCTest suite, Mac build and iPhone Simulator compilation. Physical iPhone installation still needs your Apple signing team.

[Apple peer-to-peer networking](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview), [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity), [session encryption/deprecation](https://developer.apple.com/documentation/multipeerconnectivity/mcsession/encryptionpreference).
