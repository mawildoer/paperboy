# Paperboy Bluetooth protocol (versions 1 and 2)

Service `8E400001-7B2A-4B1F-9C5D-5A1EF0C0DE01`

| Characteristic | UUID ending | Properties | Direction |
|---|---|---|---|
| RX | `…0002…` (`8E400002-7B2A-4B1F-9C5D-5A1EF0C0DE01`) | write, write without response (encrypted) | phone → device |
| TX | `…0003…` (`8E400003-7B2A-4B1F-9C5D-5A1EF0C0DE01`) | notify (encrypted) | device → phone |

The link is bonded and encrypted (LE Secure Connections, Just Works). Each write or notification
is one frame: one type byte, then the payload. Integers are little-endian. An article id is 8
bytes (the first 8 bytes of SHA-256 of the article's canonical URL).

Phone → device:

| Type | Name | Payload |
|---|---|---|
| 0x01 | HELLO | protocol version u8 (1 or 2), unix time u32 |
| 0x02 | LIST | none |
| 0x10 | PUT_BEGIN | id[8], size u32, crc32 u32, time u32, source len u8 + bytes, title len u8 + bytes, author len u8 + bytes |
| 0x11 | PUT_DATA | raw bytes (sent without response) |
| 0x12 | PUT_END | none |
| 0x20 | DELETE | id[8] |
| 0x30 | BYE | none |

Device → phone:

| Type | Name | Payload |
|---|---|---|
| 0x81 | HELLO_ACK | protocol version u8, battery percent u8, free space in MB u32 (0xFFFFFFFF = not measured yet), firmware version string (rest of the frame) |
| 0x82 | LIST_ITEMS | repeated: id[8], flags u8 (bit 0 = read) |
| 0x83 | LIST_END | total count u16 |
| 0x90 | PUT_READY | status u8 |
| 0x91 | PUT_PROGRESS | bytes consumed so far u32 |
| 0x92 | PUT_RESULT | status u8 |
| 0xA0 | DELETE_RESULT | status u8 |

Status: 0 ok, 1 busy, 2 no space, 3 storage error, 4 checksum mismatch, 5 bad request, 6 exists.

Flow control: the phone never sends more than 8192 bytes past the last PUT_PROGRESS value. The
device sends PUT_PROGRESS each time another 4096 bytes are consumed, and once at the end.
After an SD write failure it drains and acknowledges the remaining transfer, then returns
PUT_RESULT storage error. Only a successful PUT_RESULT confirms storage. Articles are limited to 8 MiB.
CRC-32 is the zlib polynomial over the whole file. An interrupted transfer may leave
`incoming.tmp`, which the next PUT_BEGIN overwrites. Failed completed transfers remove the temporary
file and attempt to remove any newly renamed EPUB if indexing fails; SD faults can prevent cleanup.

A sync session: HELLO → LIST → for each article the device lacks: PUT_BEGIN / PUT_DATA… / PUT_END
→ DELETE for articles the phone has retired → BYE. After BYE the Library (the Paperboy Home screen)
keeps an existing connection for further sessions. After a quiet interval, the Library briefly stops
the radio to reconcile its index, then resumes sync. Opening a book, another screen, or Wi-Fi also
stops the radio to release its memory.


## Bluetooth firmware updates

The existing bonded, encrypted link carries an optional firmware-update extension;
article protocol version 1 remains unchanged. The app downloads the X3 binary and
SHA256SUMS from this fork's HTTPS GitHub release and checks the SHA-256 digest.
Release assets are trusted through the owner's GitHub account and HTTPS, not an
independent firmware signing key.

| Phone frame | Payload | Device reply |
|---|---|---|
| 0x40 FIRMWARE_BEGIN | size u32, zlib crc32 u32 | 0xC0, status u8 |
| 0x41 FIRMWARE_DATA | raw bytes | 0xC1, bytes consumed u32 |
| 0x42 FIRMWARE_END | none | 0xC2, validation status u8 |
| 0x43 FIRMWARE_COMMIT | none | 0xC3, acceptance status u8 |
| 0x44 FIRMWARE_ABORT | none | no reply |

The 8192-byte window and 4096-byte progress interval match article transfers.
Maximum firmware size is 0x640000 bytes, matching the current app slots. Additional
statuses: 7 means USB power or at least 30% battery is required; 8 means the existing
firmware validator rejected the image. Firmware commands require an authenticated,
bonded connection permitted by the existing pairing policy.

One transfer reuses the article receiver/file handle and stages on SD at
`/.crosspoint/paperboy-firmware.bin`. No whole-image MCU allocation is introduced.
CRC, full ESP image integrity, chip, and board checks run before commit. A commit
acknowledgment means accepted, not installed. After a 400 ms notification grace
period BLE is stopped, then the existing flasher revalidates the image, writes the
inactive slot, switches boot selection only after success, and reboots. The phone
must reconnect and read the expected, changed firmware version before reporting
success. The running slot, article files, and progress caches are not overwritten.
This mechanism does not provide automatic rollback of an image that later crashes.

Before commit is accepted, abort, disconnect, leaving the eligible screen, or a
30-second stalled transfer abandons staging. After accepted commit, abort frames
are ignored and a disconnect does not cancel installation. Leaving the eligible
screen can still stop the operation before flashing; version verification detects
that the requested update did not complete. The SD file may survive power loss but is never auto-installed;
the next firmware begin replaces it. Rejected/interrupted transfers do not change
boot selection. The first firmware with this extension requires USB installation.

## Library timestamps

Article index rows add an optional sixth TSV field: arrival Unix seconds.
Existing `id, publicationTime, source, title, author` rows remain readable with an
unknown arrival time. Arrival uses HELLO's phone time plus elapsed monotonic time
at the successful article transfer; it does not set the system clock. Older rows
and books fall back to FAT modification time and then retained discovery order. Packed FAT wall time is normalized to Unix seconds using the configured timezone for comparison; raw FAT values still serve cache freshness checks.
Library toggles through Touched, Added, and Published, newest first. Reading a file no
longer pins it above timestamp order. Undated books sort last under Published
(newest first). Reading progress is preserved in every view.

Timestamp discovery reads the article TSV twice into a rebuild-only, fallible
16-byte-per-entry snapshot (maximum 64 KiB for 4096 article entries). It is sorted
by article ID for logarithmic lookups without SD I/O during the library walk and
released when the rebuild returns. Read/allocation failure preserves the existing
index. This adds temporary rebuild memory, not a resident library metadata cache.
Automatic Library refresh and automatic sleep stay deferred while firmware is
receiving, validated, or committed. A stalled transfer clears this hold after
30 seconds; successful OTA reboots into Home/Library so the phone can reconnect.


## Protocol 2: metadata-only bumps

A new phone sends HELLO version 2. New firmware returns version 2 for such a
phone, and version 1 for old phones. Version 2 phones accept version 1 for basic
article sync and firmware updates; they keep bump requests queued until firmware
supports them. Existing article frames are unchanged.

| Type | Name | Payload |
|---|---|---|
| 0x21 | TOUCH | article id[8], nonzero phone bump nonce u32 |
| 0xA1 | TOUCH_RESULT | status u8 |

After uploads and before deletes, a phone sends pending touches only for articles
present on the reader and still wanted there. Successful acknowledgment clears
only the matching queued nonce; a newer tap remains queued. Nonces are ordered
across phone taps, including taps within one second. Repeated or older nonces do
not promote the article again, even after a later local open. The phone sends no
EPUB bytes, resets no reading position, and does not change load/read state or
Added/Published values. Load an article before bumping it. New firmware increments
its store-generation signal so an idle Library refreshes the ordering.

Firmware keeps a clock-independent sequence per path, persisted with a reserved
counter. Opening a successfully rendered book or article also touches it. The
three reader views are Touched, Added, Published, newest first. The sleep screen
reuses the Paperboy artwork as a 1,800-byte monochrome bitmap. Generate it from
`src/images/PaperboyIcon.png` using `scripts/generate_paperboy_logo.py`.
