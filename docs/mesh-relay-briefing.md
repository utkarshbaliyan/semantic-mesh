# SemanticMesh — relay & long-distance briefing

*A self-contained context doc. Paste this into a Claude app chat to discuss the
technology and design trade-offs. It reflects the real code as of branch
`claude/blissful-dijkstra-85oa2g`.*

---

## What SemanticMesh is

An offline, peer-to-peer chat app for Apple (Mac, iPhone, iPad) and Android.
No servers, no internet, no accounts. Devices find each other over
**Bluetooth + local Wi-Fi** using Apple's **MultipeerConnectivity** framework
(Android has an equivalent). Two people who meet once become "friends" and
after that reconnect automatically whenever they're near each other with the
app open.

Core design principles:
- **No infrastructure.** Everything is device-to-device.
- **End-to-end encryption.** Only the two endpoints can read a message.
- **Ephemeral.** Messages and files expire after 1 hour.
- **Trust on first use (TOFU).** The first time you connect directly to someone,
  you pin their public keys. Later key changes are rejected (anti-impersonation).

## The crypto (what's actually in the code)

- Each device has long-term **Curve25519** keypairs: one for signing, one for
  key agreement (`NodeKeys` in `apple/Core/Relay.swift`).
- Contacts exchange public keys over the first direct link and pin them
  (`ContactBook.pin`, in `apple/Core/MessageStore.swift`). A 6-byte fingerprint
  ("safety code") lets two people compare keys in person.
- Messages are **sealed** with ChaCha20-Poly1305 using a shared secret derived
  via HKDF from the two devices' agreement keys, and **signed** with the
  sender's signing key (`SealedFrame.seal`).
- A sealed frame exposes only routing fields (`from`, `to`, `created`,
  `expires`, `hops`) to carriers. The payload is opaque to everyone but the
  recipient.

## How long-distance "hops" already work

This is built and active on the Apple side (`RelayRouter`, `RelayStore`,
`SealedFrame` in `apple/Core/Relay.swift`; wired via `MeshModel.deliver` and
`MeshModel.relayed`).

Mechanism — **epidemic store-and-forward** (a classic delay-tolerant network):

1. You send text to a friend who is **not** directly connected.
2. Your device wraps it in a sealed frame addressed to that friend and stores
   it locally.
3. **Any** nearby SemanticMesh device — not just your friends — picks up the
   frame and carries it. Carriers can't read it; they just relay it.
4. Each carrier offers the frame once to every other device it meets, except
   the one it got it from and the original sender (prevents loops/backflow).
5. When a device that holds the frame meets the **recipient** directly, it
   delivers it and the recipient opens it.

Key properties and limits, straight from the code:
- **Carry across time, not just space.** Frames persist in `RelayStore` for up
  to **1 hour** (`capacity = 500` frames). So a person can pick up a frame in
  one place and physically carry it to another cluster minutes later —
  "sneakernet"/courier delivery. This is the real long-distance path.
- **Hop cap of 8** (`hops` field, `forwarded()` throws past 8).
- **Dedup + delivery suppression.** A frame already seen, or already
  acknowledged by the recipient, stops propagating.
- **Signature check.** If a carrier knows the sender's keys, it verifies the
  signature and drops forgeries rather than carrying them.
- **Text only over the relay.** Files/media need a **direct** connection
  (too big to flood through the mesh).

So "long distance" today = a chain of app-running devices, either connected at
the same moment or bridging across time as people move. It is **not** instant
delivery across a city — it's bounded by how many devices run the app and how
they move.

## The big question: can we relay through phones that DON'T have the app?

Short answer: **No — not on iOS or Android, and not something we should try to
do covertly.** This is the central constraint, worth understanding clearly.

Why it's technically impossible:
- You **cannot run any code on a phone that hasn't installed and opened
  participating software.** That software needs the user to grant Bluetooth /
  Local Network permission. There is no OS API — by security design — that lets
  app A make stranger's phone B store and forward arbitrary bytes.
- A non-participating phone simply ignores you. BLE *beacons* can broadcast a
  few bytes that any scanner in range could see, but (a) the other side still
  needs a scanning app, (b) it's public to everyone nearby, (c) it can't do
  addressed store-and-forward.

Why the thing you're imagining seems to exist:
- **Apple Find My / AirTag offline finding** does relay through strangers'
  iPhones. But that works *only* because Apple built it into iOS itself. No
  third-party app can tap into that network for messaging. We can't replicate
  it without being Apple.

Why we wouldn't do it even if we could:
- Silently using someone's battery, radio, and device to carry data they never
  agreed to carry is abuse territory — app stores reject it, and it's not
  something to build covertly. The honest version is consent-based: "install
  the app and your phone helps carry sealed messages," which is exactly how the
  relay already works.

**Conclusion:** extending reach is an *adoption + node-density + background
relaying* problem, not a hidden trick we're missing. Every hop must be a device
running SemanticMesh (or an interoperable app), with its owner's consent.

## Legitimate ways to extend reach (the real menu)

1. **Background BLE relaying.** Today MultipeerConnectivity barely runs when the
   app is backgrounded, so a phone only relays while the app is open and in the
   foreground. Rewriting the transport on **Core Bluetooth** with background
   modes would let phones keep carrying frames with the app closed/backgrounded.
   This is the single biggest multiplier on reach — and the hardest work.
   (iOS background BLE has real constraints: throttled scanning, no local-name
   in background advertisements, etc.)
2. **Dedicated relay nodes.** Leave a spare phone or a Mac on in a central spot
   as an always-on repeater. Quick, legitimate, extends a fixed area.
3. **Internet bridge fallback.** An optional relay server that forwards *already
   sealed* frames when no device-to-device path exists. The server can't read
   anything (end-to-end crypto holds), but it breaks the pure-offline model.
4. **Tune the existing relay.** Longer carry window / bigger store, surface
   relay status in the UI, smarter dedup — make the hops you already have more
   effective before bigger architectural changes.

## Good questions to explore in the Claude app

- What's the realistic node density needed for city-scale delivery, and what do
  real mesh deployments (Bridgefy, Briar, GoTenna, Scuttlebutt, disaster/protest
  networks) actually achieve?
- How hard is iOS background BLE really, and what's the minimum viable version?
- Delay-tolerant networking (DTN) theory: epidemic vs. spray-and-wait vs.
  PRoPHET routing — is plain epidemic the right choice at scale, or does it
  flood too much?
- Privacy/metadata: carriers see `from`/`to` identities in the clear. Is that
  acceptable, or do we need onion-style routing / sealed sender?
- Battery and abuse limits for volunteer carriers.
- Interop: could we talk to an existing mesh protocol instead of being an island?

## Current status (for context)

- Apple: friends auto-reconnect via signed invitations; mesh auto-starts on
  launch/foreground. Multi-hop relay is active.
- Android: feature parity with Apple's chat, but multi-hop relay was removed to
  match an earlier Apple state and the auto-reconnect work hasn't been ported.
- No internet relay server exists yet.
