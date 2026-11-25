# Semantic Mesh

Offline device-to-device messaging prototype for Android (Bluetooth) and Mac/iPhone (Apple Multipeer Connectivity). Messages relay across nearby devices with no internet, SIM or cloud. The Android and Apple apps share the same message envelope but cannot talk to each other yet. The immediate goal is two-phone messaging, then three-phone relaying. No AI, LoRa, cloud, SIM, or internet permission is included.

## Apple prototype

The Apple app supports nearby usernames, chat requests, saved contacts, owner-managed groups, audio/video attachments, voice recording and emojis. For Mac↔iPhone testing, see [Apple setup and offline test instructions](apple/README.md). Apple uses a separate native transport with the same envelope. Android↔Apple interoperability is not implemented.

## Implemented

- Bluetooth Classic secure RFCOMM listener and outgoing connections; nearby discovery and paired-device list.
- UUID device identity, versioned length-prefixed JSON frames, timestamps, one-hour expiry, eight-hop limit.
- SQLite message persistence, ID deduplication, application-level receipt messages.
- Flooding across connected peers and replay of live stored messages on connection and every 15 seconds.
- Foreground UI for permissions, discovery, connections, text and receipt logs.

This is an engineering prototype, not a verified emergency communication system. Multiple simultaneous links and actual delivery must be tested on physical phones. Receipt means another app stored a report; it does not mean a human read or verified it. Messages are broadcasts; receipts name their intended recipient.

## Build

Use Android Studio with JDK 17 or 21 and Android SDK 35. The pinned Gradle wrapper downloads build dependencies on first use; app operation is offline afterwards.

```sh
./gradlew testDebugUnitTest assembleDebug lintDebug
```

Install `app/build/outputs/apk/debug/app-debug.apk` on Android 8+ phones. Keep the app visible and screens awake during tests. Android 8–11 require location permission and may require the system Location toggle for discovery. Android 12+ require Nearby Devices permissions.

## Verification

Local SDK 35 build passed: `testDebugUnitTest assembleDebug lintDebug`; five protocol tests passed, lint had no errors. Physical-device transport, storage/replay and routing acceptance tests remain unperformed. GitHub Actions repeats checks and uploads the debug APK.

## Two phones

1. Disable mobile data and Wi-Fi on both phones; enable Bluetooth. Removing SIMs is an additional useful test.
2. On both: Start, grant permissions, enable Bluetooth if requested, then press Start again.
3. On B: Make discoverable. On A: Scan nearby, choose B, accept Android's pairing prompt on both.
4. Send distinct messages both directions. Verify matching message-ID prefixes and receipts.
5. Kill/reopen the app; verify stored messages remain. Restart listeners and reconnect manually.

## Three phones

Start listeners on A/B/C. Make B discoverable. Connect A to B, then C to B. Never connect A directly to C. Send from A; C should log hops=2 and A should get receipts from B and C. Run the negative control: close B; a new A message must not reach C. Reopen B and reconnect to verify delayed delivery. See [device test plan](docs/device-testing.md).

## Constraints

- Discovery/connection is manual. No automatic reconnect, background service, or guaranteed delivery deadline.
- Retry uses full live-store replay, bounded to 5,000 envelopes and 16 KiB/frame. This is simple and inefficient; inventory synchronization and per-peer queues come next.
- Blocking writes can delay the single protocol worker. Slow-peer isolation, backpressure and connection timeouts are needed before load testing.
- Clocks must roughly agree; expiry uses wall time. No clock synchronization yet.
- Secure Bluetooth pairing protects individual links. There is no end-to-end encryption, signed identity, trusted-group authorization or revocation. Relays can read reports and forge identities/receipts.
- Stable node UUID lives in private preferences; reinstalling resets it. History expires from forwarding after one hour.
- Protocol and Bluetooth transport are separate source components; the initial orchestration resides in the Activity. Extract a lifecycle-independent engine before adding another transport or background operation.

## Next gates

1. Build and install; collect two-device reliability results.
2. Prove A→B→C with B-off negative control and disconnected store-and-forward.
3. Add inventory sync, retry limits, queue isolation, identity authentication and lifecycle-independent routing.
4. Only then add structured incident reports, reviewed offline extraction and speech.

## API references

- [Android Bluetooth connection model](https://developer.android.com/develop/connectivity/bluetooth/connect-bluetooth-devices)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Pinned Android Gradle plugin compatibility](https://developer.android.com/build/releases/agp-8-9-0-release-notes)
