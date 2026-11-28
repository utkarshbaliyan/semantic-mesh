# Semantic Mesh

Offline device-to-device messaging prototype for Android (Bluetooth) and Mac/iPhone (Apple Multipeer Connectivity). Messages relay across nearby devices with no internet, SIM or cloud. The Android and Apple apps share the same message envelope but cannot talk to each other yet. The immediate goal is two-phone messaging, then three-phone relaying. No AI, LoRa, cloud, SIM, or internet permission is included.

## Apple prototype

The Apple app supports nearby usernames, chat requests, saved contacts, owner-managed groups, audio/video attachments, voice recording and emojis. For Mac↔iPhone testing, see [Apple setup and offline test instructions](apple/README.md). Apple uses a separate native transport with the same envelope. Android↔Apple interoperability is not implemented.

## Android prototype

The Android app now matches the Apple feature set over Bluetooth Classic: editable usernames with inline validation, chat requests, saved contacts, direct chats, owner-managed groups that any device can create, voice recording, audio/video attachments and delivery receipts. Like the Apple app, messages travel over direct approved links only; other people's messages are not relayed.

## Implemented (Android)

- Secure RFCOMM listener and outgoing connections; nearby discovery and paired-device list.
- Link handshake: each side announces its device ID and username; mutual contacts reconnect without a new request, everyone else needs an accepted chat request. One link per person.
- Shared envelope with the Apple app (same JSON fields): text, receipts, group updates, media descriptors and media-ready requests; one-hour expiry, eight-hop limit, 16 KiB frames.
- Owner-managed groups (up to 16 people), with membership updates that reach removed members too.
- Attachments up to 20 MB (200 MB stored), sent in 8 KiB chunks and accepted only after size and SHA-256 match.
- SQLite message persistence, ID deduplication and replay of live messages on connection and every 15 seconds.

This is an engineering prototype, not a verified emergency communication system. Receipt means another app stored a report; it does not mean a human read or verified it.

## Build

Use Android Studio with JDK 17 or 21 and Android SDK 35. The pinned Gradle wrapper downloads build dependencies on first use; app operation is offline afterwards.

```sh
./gradlew testDebugUnitTest assembleDebug lintDebug
```

Install `app/build/outputs/apk/debug/app-debug.apk` on Android 8+ phones. Keep the app visible and screens awake during tests. Android 8–11 require location permission and may require the system Location toggle for discovery. Android 12+ require Nearby Devices permissions.

## Verification

Local SDK 35 build passed: `testDebugUnitTest assembleDebug lintDebug`; 16 unit tests passed (envelope rules plus simulated multi-device chats, groups created from every device, and verified media transfer), lint had no errors. The Bluetooth handshake, chunked file transfer, recording and playback have not yet been tested on physical Android phones. GitHub Actions repeats checks and uploads the debug APK.

## Two phones

1. Disable mobile data and Wi-Fi on both phones; enable Bluetooth.
2. On both: set a username (3–24 lowercase letters, numbers or `_`, starting with a letter) and tap Save; then tap Start network and grant permissions.
3. On B: Make discoverable. On A: Scan nearby, tap Connect on B, and accept the pairing prompt on both.
4. On A: Send chat request; on B: Accept. Both now list each other under Contacts.
5. Send text, a recorded voice message and a short video both ways. Verify "Delivered to app" and that media plays.
6. Kill/reopen the app; verify stored messages remain and that reconnecting does not ask for a new chat request.

## Three phones

Connect and accept chat requests for every pair (A–B, B–C, A–C). On each phone in turn, Create group with the other two, then send a message: the other two should receive it and the sender should see "Delivered to 2 members". See [device test plan](docs/device-testing.md).

## Constraints

- Discovery/connection is manual. No automatic reconnect, background service, or guaranteed delivery deadline.
- Retry uses full live-store replay, bounded to 5,000 envelopes and 16 KiB/frame. This is simple and inefficient; inventory synchronization and per-peer queues come next.
- Blocking writes can delay the single protocol worker. Slow-peer isolation, backpressure and connection timeouts are needed before load testing.
- Clocks must roughly agree; expiry uses wall time. No clock synchronization yet.
- Secure Bluetooth pairing protects individual links. There is no end-to-end encryption or signed identity: device IDs and usernames are self-asserted, so compare device IDs in person before accepting a chat request.
- Stable node UUID lives in private preferences; reinstalling resets it. History expires from forwarding after one hour.
- Chat rules live in `MeshNode`, separate from the Bluetooth transport and the Activity, and are unit-tested without a device. Multi-hop relaying was removed to match the Apple app; messages need a direct link.

## Next gates

1. Build and install; collect two-device reliability results.
2. Prove A→B→C with B-off negative control and disconnected store-and-forward.
3. Add inventory sync, retry limits, queue isolation, identity authentication and lifecycle-independent routing.
4. Only then add structured incident reports, reviewed offline extraction and speech.

## API references

- [Android Bluetooth connection model](https://developer.android.com/develop/connectivity/bluetooth/connect-bluetooth-devices)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Pinned Android Gradle plugin compatibility](https://developer.android.com/build/releases/agp-8-9-0-release-notes)
