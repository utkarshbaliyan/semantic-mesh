# Physical-device acceptance tests

Record manufacturer/model, Android version, battery mode, permission state, system Location state, and app commit. Keep screens awake. Never infer RF range from a fixed distance: walls, interference and hardware alter it.

| Test | Evidence required |
|---|---|
| Two-phone offline | No SIM/data/Wi-Fi; Bluetooth enabled; 20 unique messages each direction; matching IDs and app receipts |
| Pairing declined | App remains usable; clear connection failure; later retry works |
| Permission declined | No crash; Start can request again; permanent denial handled via system settings |
| Chat request | A requests B; B accepts → both list each other; B rejects → A sees "declined" and can retry |
| Reconnect | After an accepted request, kill both apps and reconnect: no new request needed |
| Three-phone group | Links A–B, B–C, A–C; each phone creates a group with the other two; every message reaches both others, "Delivered to 2 members" |
| No relay | Only A–B and B–C linked; A's direct message to C is not delivered through B |
| Media | Voice recording, audio file and video (≤20 MB) each way; plays on receiver; tampered/partial transfer never shown as delivered |
| Username | Invalid name shows the rule in red; valid rename updates connected contacts without disconnecting |
| Duplicate replay | Wait through three 15-second sync cycles; no duplicate text in UI |
| Restart | Kill/reopen receiver; persisted IDs prevent duplicate insertion |
| Expiry | An expired frame is not displayed or forwarded; sender/receiver clocks recorded |
| Malformed frame | Invalid JSON, version, ID, kind, hop or oversize length is rejected; valid reconnect still works |
| Radio interruption | Bluetooth off/on does not crash app; restart Activity and listeners and reconnect |

Status: no physical-device results recorded. The app has no background reliability promise. Complete the table with measured results before calling the MVP stable.
