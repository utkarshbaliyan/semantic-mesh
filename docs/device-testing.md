# Physical-device acceptance tests

Record manufacturer/model, Android version, battery mode, permission state, system Location state, and app commit. Keep screens awake. Never infer RF range from a fixed distance: walls, interference and hardware alter it.

| Test | Evidence required |
|---|---|
| Two-phone offline | No SIM/data/Wi-Fi; Bluetooth enabled; 20 unique messages each direction; matching IDs and app receipts |
| Pairing declined | App remains usable; clear connection failure; later retry works |
| Permission declined | No crash; Start can request again; permanent denial handled via system settings |
| Three-phone path | Only A–B and B–C links; C logs hop 2 for A's message |
| Relay negative control | Close B; new A message never appears at C until B returns |
| Store and forward | A→B, disconnect A, restart B, B→C; C receives same ID once |
| Duplicate replay | Wait through three 15-second sync cycles; no duplicate text in UI |
| Restart | Kill/reopen receiver; persisted IDs prevent duplicate insertion |
| Expiry | An expired frame is not displayed or forwarded; sender/receiver clocks recorded |
| Hop bound | Frame arriving at hop 8 is stored, never sent onward |
| Malformed frame | Invalid JSON, version, ID, kind, hop or oversize length is rejected; valid reconnect still works |
| Radio interruption | Bluetooth off/on does not crash app; restart Activity and listeners and reconnect |

Status: no physical-device results recorded. The app has no background reliability promise. Complete the table with measured results before calling the MVP stable.
