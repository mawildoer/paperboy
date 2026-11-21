# Paperboy Bluetooth protocol (version 1)

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
| 0x01 | HELLO | protocol version u8 (=1), unix time u32 |
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
→ DELETE for articles the phone has retired → BYE. After BYE the device turns the radio off on Home; on Articles it keeps an existing connection for further sessions.
