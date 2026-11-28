# Mac ↔ iPhone nearby messaging

Native SwiftUI app for macOS 14+ and iOS 17+. Keep Wi-Fi and Bluetooth enabled and the apps open. Messaging works without internet. Text can now hop across other people's devices (multi-hop mesh), so range grows with the number of connected devices in between. It still cannot reach someone 100 km away without a chain of devices or a carrier who travels there within the hour. Android uses a different transport and cannot connect to the Apple app yet.

## Version 0.6: identities, QR add, nicknames

- **Every person shows as `@username#TAG`.** The tag is the first four hex characters of a SHA-256 of their signing key — short, stable and hard to spoof. It appears in the chat list, chat header, Nearby, Settings and group members, and is shown nearby **before** you connect (the signing key is advertised in discovery and verified against the key announced on connect; a mismatch is rejected).
- **Add verified contacts with a QR code or link.** Settings → **My QR code** shows a code (and an `sm://add?...` link) encoding your identity and keys. On iPhone/iPad, **Scan a code** opens the camera; on Mac, paste the link. Contacts added this way are pinned as **verified** and carry a blue seal badge — no need to meet on the mesh first.
- **Private nicknames.** In Chat info you can set a local display name for a contact; it overrides their chosen username everywhere in the UI and is only stored on your device.
- **Durable, encrypted storage.** Messages, receipts, relay frames and the contact/group books now live in one SQLite database (`mesh.sqlite`). Message text and frame payloads are encrypted at rest with a key kept in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); on ad-hoc-signed Mac builds where the Keychain is unavailable it falls back to a protected key file and says so in the log. Existing 0.5 JSON files are migrated once on first launch, then deleted.
- **Day-long delivery, lasting history.** Chat history is kept until you delete it; queued messages survive app restarts and keep retrying/relaying until delivered or expired. The delivery window is configurable in Settings (default 3 days, up to 7; 5-minute clock-skew tolerance). Per-chat **Disappearing messages** (Off / 24 h / 7 days / 90 days) and **Delete chat** are in Chat info.
- **Bigger, managed storage.** Media files stay capped at 20 MB each; the total media quota is now 1 GB. The relay cache holds up to 2,000 frames / 50 MB and, when full, evicts the oldest frames carried for others first — never your own undelivered frames or frames addressed to you. Settings → **Storage** shows media and relay-cache usage with buttons to clear each.
- Version 0.6 uses discovery protocol `chat=4` and does not see 0.5 or earlier devices. Update every device.

## Version 0.5: multi-hop mesh

- **New messenger layout on Mac, iPhone and iPad.** A chat list (contacts and groups, newest first, with last-message previews and a nearby indicator) beside the open chat on Mac/iPad, push navigation on iPhone. Toolbar: **Find people**, **New group**, **Settings**.
- **Every chat has the full composer:** attach audio/video (and Photos video on iPhone/iPad), emoji, text, and a mic button that turns into a recording bar with timer, cancel and send. Message bubbles show time and a status icon (clock = queued, mesh icon = being relayed, check = delivered); long-press or right-click for details.
- **Chat info:** contact device ID and safety code, or group members, owner and member management, plus the chat's media.
- **Settings:** account (username), security codes, mesh on/off and status, limits, and the network log.

- **Relay through other devices.** If a contact is not directly connected, text, delivery receipts and group membership updates are sealed into an end-to-end encrypted, signed frame. Any connected device running v0.5 stores and forwards it (up to 8 hops, for up to 1 hour). A device that carries a message and later meets the recipient delivers it (store-and-forward).
- **End-to-end protection.** Each device has long-term Curve25519 keys (`node-keys.json`). Keys are exchanged automatically over the first direct v0.5 connection and pinned (trust on first use); a later key change is rejected. Relays only see sender ID, recipient ID, expiry and hop count, never the content. Compare the **Safety code** under your username in person to rule out an impersonated first connection.
- Contacts show **Via mesh** once keys are exchanged. Outgoing messages show **In the mesh** while being carried. The header shows how many messages you carry for others.
- Audio/video files are not relayed. They still need a direct connection.
- Relays only use links you already approved with **Request chat**. Strangers' devices do not join automatically yet.
- v0.5 uses a new discovery version and does not see v0.4 devices. Update every device.

### Test multi-hop with 3 devices

1. Install v0.5 on Mac, iPhone and iPad. Start the network on all three and accept chat requests for every pair (Mac↔iPhone, Mac↔iPad, iPhone↔iPad). The log shows "Mesh keys saved" for each contact.
2. Quit and reopen the app on iPhone and iPad (this drops their direct link). Start the network on both, then reconnect each **only to the Mac**. Do not reconnect iPhone↔iPad.
3. On iPhone, open the iPad chat (shows **Via mesh**) and send text. The iPad receives it and its log shows "Received through the mesh (2 hops)". The iPhone shows **Delivered to app** once the receipt comes back through the Mac, and the Mac header shows it is carrying messages.
4. Store-and-forward: stop the network on the iPad, send from iPhone (shows **In the mesh**), then start the iPad network and reconnect it to the Mac. It should arrive exactly once.

## Version 0.4

- Local usernames, explicit chat requests, saved contacts and direct conversations.
- Named groups, up to 16 members including the creator. The creator adds/removes members and renames the group.
- Audio files, video files and recorded voice messages in direct and group chats.
- Audio/video playback, Unicode emojis and an emoji shortcut row.

Install this version on **both devices**. Older versions use a different discovery capability and do not appear as compatible contacts. Updating the same bundle identifier preserves your existing device identity and contacts.

## Run on Mac and iPhone

Your existing Xcode signing team can stay as configured. Open `SemanticMesh.xcodeproj`, choose **SemanticMesh**, select your unlocked iPhone and press Run once. Keep Developer Mode enabled and your developer certificate trusted. Allow Local Network permission; microphone permission is requested when you first record a voice message.

For the Mac, use the **SemanticMeshMac** Xcode scheme, or run:

```sh
apple/scripts/build-mac.sh
open 'apple/output/Semantic Mesh.app'
```

The generated Mac application and ZIP are development builds, ad-hoc signed and not notarized. Use a stable app location for permission handling. Xcode setup/signing may need internet; installed messaging does not.

If you need to set up another iPhone: add your Apple ID in Xcode Settings → Apple Accounts, select your Personal Team under the SemanticMesh target's Signing & Capabilities, connect/trust the phone, enable Developer Mode and run. [Apple device setup](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).

## Use the features

1. Save a username, press **Start network** on both devices, find the other person nearby and press **Request chat**. They accept. Select the saved contact to chat.
2. Press **Create group**, give it a name and select accepted contacts. The group appears on members' devices when they connect to the creator.
3. As creator, select the group and press **Add / remove members**. Check or uncheck people, then save.
4. Use **Audio file** or **Video file** to choose an attachment. On iPhone, **Photos video** selects a clip from your photo library without granting access to the whole library.
5. Tap **Record voice**, grant microphone access, then **Send recording**. **Cancel recording** discards it. Recording stops automatically after two minutes and sends the result.
6. Tap **Play audio/video** in a received or sent message. Use the emoji row or your normal emoji keyboard.

Groups send directly to their current members. Each pair of members must have accepted a chat request and connect nearby to exchange messages; the creator does not relay their conversations. Members should connect to the creator first to receive the current membership revision. No global username registration, account recovery or cross-device account synchronization is implemented. Duplicate usernames remain distinct by device UUID.

## Limits and delivery behavior

- Supported audio extensions: m4a, mp3, aac, wav, caf. Video: mp4, mov, m4v. Playback also depends on the file's codec.
- Each file is capped at 20 MiB; local attachment storage at 200 MiB. Voice recordings use AAC. Up to two file transfers run per device at a time; other transfers retry.
- Messages and attachments expire after one hour, including sent and received history. Expired media files are cleaned up. Groups and contacts persist.
- Offline messages queue until reconnection within that hour. On iPhone, moving the app into the background stops networking and cancels a recording. Return and press Start network again.
- A media receipt is generated after the complete file is stored and its size and SHA-256 digest match the metadata. A receipt means delivered to an app, not read by a person.
- The creator sends versioned membership updates to current and removed members. Removed members cannot send/receive new group traffic once the update is applied. Disconnected devices can retain an older membership view until they reconnect with the creator; instantaneous offline revocation is impossible here. Already delivered messages/files cannot be recalled.
- Changing membership stops replay of queued messages from the previous revision. The composer shows this in delivery status; send a new message after the update if needed.
- Direct sessions are encrypted by Multipeer. Relayed frames are end-to-end encrypted (X25519 + ChaCha20-Poly1305) and signed (Ed25519) with keys pinned on first direct contact. There is no forward secrecy yet, and the first key exchange is only as trustworthy as that direct link; compare safety codes in person. Usernames are self-claimed. This is a prototype, not a secure replacement for an established messenger.
- JSON frames remain capped at 16 KiB, text at 2,000 UTF-16 units, message store at 5,000 live envelopes, groups at 100 and contacts at 500. Clocks must roughly agree. Storage errors disable sending rather than erase history.

## Verification

```sh
apple/scripts/test-core.sh
apple/scripts/build-mac.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path apple
```

The 28 core checks cover sealed-frame encryption and tamper rejection, four-node chain delivery without backflow, carrier store-and-forward, forged-frame dropping, key pinning, the original protocol/relay behavior, contact gates, persistence, owner-only group changes, conflicting/stale revisions, removed-member rejection, membership audiences, attachment integrity/path/size/quota checks, delayed media receipts, group receipts and emoji bounds. Native Mac and unsigned iPhone builds are checked separately; GitHub Actions also compiles the iOS Simulator target.

Real group delivery, microphone recording, photo-picker behavior and media playback still need physical-device testing. UI automation was unavailable on the development Mac. Simulated relays do not prove physical mesh routing; use the 3-device test above.

## Physical acceptance test

1. Update both apps. Start their networks, accept a chat request, send text plus emojis in both directions.
2. Send a short voice recording, an audio file and a video in both directions. Check playback and that delivery appears after the file finishes transferring.
3. Stop one device's network, send a file from the other, then restart/reconnect within one hour. Check that only one message appears and playback works.
4. With three real devices, accept chat requests between every pair. Create a group, reconnect everyone to the creator, then send text and media from each member. Confirm only group members receive them.
5. Remove a member, reconnect all devices to the creator and confirm they show **Removed** and cannot compose. Confirm remaining members can exchange new messages. Previously delivered files may remain until expiry.
6. Reject a request and confirm no chat connection appears. Try an unsupported file or a file over 20 MiB; it should be rejected. Deny microphone permission and confirm recording does not begin.
7. To prove internet independence, disable mobile data and disconnect the router's internet uplink, then repeat. For infrastructure-free testing, leave Wi-Fi enabled but disconnect joined networks, Ethernet and VPN. Keep both apps foregrounded; do not use the Simulator as a radio peer.

Apple's current documentation deprecates Multipeer Connectivity in favor of Network framework. The transport is isolated for later replacement. [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity), [resource transfer](https://developer.apple.com/documentation/multipeerconnectivity/mcsession/sendresource(at:withname:topeer:withcompletionhandler:)), [recording permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)).
