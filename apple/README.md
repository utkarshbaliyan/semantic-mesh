# Mac ↔ iPhone nearby messaging

Native SwiftUI app for macOS 14+ and iOS 17+. Keep Wi-Fi and Bluetooth enabled and the apps open. Messaging works without internet, within local wireless range. It cannot reach someone 100 km away. Android uses a different transport and cannot connect to the Apple app yet.

## Version 0.4: one complete update

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
- Sessions are encrypted. Identities and usernames are self-claimed, without signed accounts or end-to-end identity authentication. Compare device IDs in person. This is a prototype, not a secure replacement for an established messenger.
- JSON frames remain capped at 16 KiB, text at 2,000 UTF-16 units, message store at 5,000 live envelopes, groups at 100 and contacts at 500. Clocks must roughly agree. Storage errors disable sending rather than erase history.

## Verification

```sh
apple/scripts/test-core.sh
apple/scripts/build-mac.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path apple
```

The 23 core checks cover the original protocol/relay behavior, contact gates, persistence, owner-only group changes, conflicting/stale revisions, removed-member rejection, membership audiences, attachment integrity/path/size/quota checks, delayed media receipts, group receipts and emoji bounds. Native Mac and unsigned iPhone builds are checked separately; GitHub Actions also compiles the iOS Simulator target.

Real group delivery, microphone recording, photo-picker behavior and media playback still need physical-device testing. UI automation was unavailable on the development Mac. The core's simulated three-node relay does not prove physical mesh routing, and the chat UI does not relay messages.

## Physical acceptance test

1. Update both apps. Start their networks, accept a chat request, send text plus emojis in both directions.
2. Send a short voice recording, an audio file and a video in both directions. Check playback and that delivery appears after the file finishes transferring.
3. Stop one device's network, send a file from the other, then restart/reconnect within one hour. Check that only one message appears and playback works.
4. With three real devices, accept chat requests between every pair. Create a group, reconnect everyone to the creator, then send text and media from each member. Confirm only group members receive them.
5. Remove a member, reconnect all devices to the creator and confirm they show **Removed** and cannot compose. Confirm remaining members can exchange new messages. Previously delivered files may remain until expiry.
6. Reject a request and confirm no chat connection appears. Try an unsupported file or a file over 20 MiB; it should be rejected. Deny microphone permission and confirm recording does not begin.
7. To prove internet independence, disable mobile data and disconnect the router's internet uplink, then repeat. For infrastructure-free testing, leave Wi-Fi enabled but disconnect joined networks, Ethernet and VPN. Keep both apps foregrounded; do not use the Simulator as a radio peer.

Apple's current documentation deprecates Multipeer Connectivity in favor of Network framework. The transport is isolated for later replacement. [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity), [resource transfer](https://developer.apple.com/documentation/multipeerconnectivity/mcsession/sendresource(at:withname:topeer:withcompletionhandler:)), [recording permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)).
