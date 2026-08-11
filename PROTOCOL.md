# Garmin ActiveCaptain / Helm protocol notes

This document collects everything this project has reverse-engineered
about the wire protocols the official Garmin ActiveCaptain mobile app
uses to talk to a chartplotter over the local network. None of this is
officially documented by Garmin — it comes from analyzing real network
traffic between the app and a real plotter, cross-checked against real
device behavior through live testing, with some fields pinned down only
after many captures across several independent devices and app
installs.

The touch/video remote-control protocol (port 51200) and the pairing
flow (port 80) were originally reverse-engineered by
[Mrkvak/helm-linux](https://github.com/Mrkvak/helm-linux); this project
ported that work to Dart and extended it with everything below port
51200 — the route/waypoint catalog (port 50615) and route sync (port
50610) channels, which have no prior public documentation anywhere.

Everything here reflects the current, best-known state — including
noting which fields are still not understood, and which values are
guesses rather than confirmed facts. Where a past investigation session
took a wrong turn before landing on the right answer, that's noted
briefly as a warning against re-deriving the same dead end, not as a
full history.

## Service discovery (mDNS)

The plotter advertises several mDNS service types on the local network:

| Service type | Purpose |
|---|---|
| `_helmcp._tcp` | The Helm touch/video remote-control session (port 51200) |
| `_garmin-bl-id._tcp` / `_garmin-mrn-cred._tcp` | On-board HTTP pairing service (port 80) — the two names are used interchangeably by different plotter firmware versions |

## Pairing (port 80, HTTP)

Before a touch/video session will be granted, this machine must be
registered as a known device ("bl-id") with the plotter, and that
device's permission role must allow control.

1. Discover the pairing service via mDNS (above).
2. `PUT /garmin/bl-ids/<tag>` with a small hand-rolled protobuf message,
   `MobileDeviceIdentity`:
   ```
   message MobileDeviceIdentity {
     required string device_identifier = 1;  // a random UUIDv4, generated once and persisted
     required uint32 client_generated_token = 2;  // a random 32-bit value, generated once and persisted
     optional string device_name = 3;
   }
   ```
   `<tag>` is `base64(client_generated_token as 4 bytes LE ++ 02 01 00 00)`
   with `=` padding stripped. A successful `PUT` returns HTTP 202 and the
   plotter's own screen shows "a new ActiveCaptain user was added".
3. `PUT /garmin/bl-ids/<tag>/set-role` with JSON body
   `{"role": "guest"|"owner"|"dealer"}`.
4. On the plotter itself, the global App-permission for this device must
   be set to "View and Control" before a touch session will be granted —
   this is a manual, on-device step pairing alone cannot skip.

The identity (`device_identifier`, `client_generated_token`, `tag`)
should be persisted by the caller and reused across runs — re-running
step 2 with a fresh identity creates a *new* ActiveCaptain user entry on
the plotter every time.

Once paired, the touch/video session (below) is authorized purely by
the plotter recognizing this device's pairing — no token or credential
is passed at that layer.

## Touch/video remote control (port 51200)

### Outer frame format

Every message on this connection uses the same simple framing:

```
[u16 type LE][u16 0xBEEF][u32 length LE][payload, `length` bytes]
```

`0xBEEF` is a fixed magic value present in every frame; a receiver
resyncs to the next `EF BE` byte pair on any framing corruption.

### Handshake

```
C->S  tHello     (0x083f)  payload = 0x9531 as u16 LE (a fixed 2-byte tag)
C->S  tToken     (0x0aa9)  payload = 8 random bytes (an opaque session token, never interpreted by the plotter)
C->S  tSubscribe (0x1648)  payload = u32 LE index, sent once per index in `subscribeIndices` (see below)
C->S  tAcquire   (0x1644)  payload = empty — requests a touch control context
S->C  tContext   (0x1645)  payload = [u32 1][u32 touch_ctx_id] — grants a 4-byte context id, or never arrives if permission isn't "View and Control"
```

`subscribeIndices` — sent once per index, in this exact order, matching
what the real app sends:

```dart
const subscribeIndices = [
  0x0b, 0x00, 0x01, 0x06, 0x08, 0x0a, 0x03, 0x04, 0x05,
  0x09, 0x01, 0x08, 0x00, 0x0a, 0x02, 0x0c,
];
```

Only `0x0b` is understood to mean anything specific (it selects the
plotter as the subscribe target); the rest subscribe to various
data/pages the app's own UI needs and are replayed verbatim rather than
reconstructed individually — their per-index meaning is not confirmed.

### Touch/pinch input (`tTouch`, `0x164c`)

Coordinates are normalized `[0, 1]` and encoded as Q16.16 fixed point
(`round(v * 65536)`, clamped to `[0, 65536]`).

Single-finger frame (24 bytes):

```
[4-byte ctx][u32 count=1][u8 track_id=0][u32 x][u32 y][u32 down][3 zero bytes padding]
```

Two-finger pinch frame (40 bytes), used for pinch-to-zoom:

```
[4-byte ctx][u32 count=2]
[u8 track_id=0][u32 x0][u32 y0][u8 down0]
[u8 track_id=1][2 zero bytes][u32 x1][u32 y1][u8 down1]
[9 zero bytes padding]
```

A tap is press-then-release with a short delay; a drag is press, a
sequence of move frames, then release; a zoom gesture is a sequence of
pinch frames with the finger gap growing (zoom in) or shrinking (zoom
out) over several steps.

### Keepalive — why it's needed and what to send

Without *some* ongoing activity on this connection after the touch
context is granted, the plotter kills the RTSP video stream after
roughly 30 seconds — regardless of how healthy the video connection
itself looks. This isn't a video-channel keepalive requirement; it's a
whole-session keepalive that happens to also gate the video stream.

What to send: **not** a synthetic no-op touch frame (an earlier
approach) — a real device report showed the plotter tracks "last touch
position" across the whole session including synthetic frames, so a
synthetic touch shortly before a real tap made that tap register as the
tail end of a drag instead of a clean press, requiring a double-tap to
register.

What the real app actually sends (confirmed by a targeted capture: 13
consecutive 5.000-second-interval bursts with zero drift while the
screen was untouched): three `tSubscribe` (`0x1648`) frames every 5
seconds, re-subscribing to indices `8, 10, 6` — already part of the
initial handshake's index list. Being a different frame type than
`tTouch` entirely, this can't interact with touch/cursor state, so it
has none of the synthetic-touch approach's side effects.

### Video

The plotter serves H.264 video over RTSP at
`rtsp://<host>:554/helm_1280x720.h264` — a fixed, well-known URL, not
negotiated anywhere in the touch-session handshake.

## Route/waypoint sync — upload (port 50610)

A separate channel from everything above, used when the app pushes a
GPX-imported route directly to the plotter. Nothing about this exists
in any prior public documentation of this protocol family.

The main touch/video session briefly hints this channel exists: right
after its handshake, one of the `tSubscribe` replies (`0x1649`) echoes a
small payload (`[u32 9][u32 8][u16][u16]`) whose meaning was never
pinned down, but actual sync traffic was observed exclusively on this
separate connection, never on port 51200 itself — and not present at
all in a capture of a cloud-only GPX import that never touched the
plotter's local network.

### Handshake

Same outer framing as the touch/video channel (`[u16 type][u16
0xBEEF][u32 length][payload]`), but with its own `tHello` tag: instead
of the touch channel's fixed `0x9531`, this channel's `tHello` payload
is the port number itself (`50610` as `u16` LE) — sent as the very
first frame, before the plotter has said anything back, suggesting the
port is meant as a fixed, well-known service address rather than
something dynamically negotiated.

```
C->S  tHello     (0x083f)  payload = 50610 as u16 LE
C->S  tToken     (0x0aa9)  payload = 8-byte session token (same shape as the touch channel's)
C->S  tSyncBegin (0x08b7)  payload = 0x02 (1 byte) — meaning unconfirmed, always this exact value
S->C  tSyncAck   (0x08b8)  payload = 0x01 (1 byte) — grants the sync
C->S  tSyncData  (0x08b9)  payload = the encoded route, see below
S->C  tSyncDone  (0x08bb)  payload = empty — plotter accepted it
```

### `tSyncData` payload layout

A fixed 158-byte preamble, followed by one **283-byte fixed-size record
per waypoint**, followed by a 34-byte trailer.

**The preamble** is mostly replayed byte-for-byte as a template — its
detailed field-by-field meaning beyond two length fields isn't fully
understood — except two `u16 LE` fields that scale with the total
payload size: byte offset 3 (`totalPayloadLength - 11`) and byte offset
18 (`totalPayloadLength - 26`), confirmed by diffing two real captures
with different point counts.

**Each waypoint record** (283 bytes, relative to the record's own
start):

| offset | size | content |
|---|---|---|
| 0x00 | 15 | route name (first record only), Latin-1, zero-padded/truncated |
| 0x0f | 4 | total point count in the route, `u32` LE (first record only) |
| 0x18 | 1 | a route-level marker byte, identical across every record in one route but different between the two known real captures (`0x00` for a 4-point route, `0x03` for an 8-point one) — meaning not derived from just two data points; this implementation always emits `0x00`, the only value confirmed to work live |
| 0x19 | 4 | latitude, Garmin semicircle `int32` (`round(degrees * 2^31 / 180)`) |
| 0x1d | 4 | longitude, same encoding |
| 0x21 | 16 | a per-waypoint value that looks UUID-shaped (differs on every waypoint, never zero, never repeated) — exact format not independently confirmed |
| 0x31 | 10 | waypoint name, Latin-1 (confirmed via a captured "ø" stored as the single byte `0xf8`, not 2-byte UTF-8 — this field is genuinely single-byte-per-character, not UTF-8 truncated mid-sequence) |
| 0x4f | 11 | fixed bytes, identical across every waypoint in every capture seen so far — plausibly a symbol/display-option field, not decoded further |
| 0x5a | 4 | sync timestamp, `u32` LE seconds since the Garmin/GPS epoch (1989-12-31T00:00:00Z) |

Everything else in the record is zero.

The **first record's** leading ~25 bytes (before the latitude field)
are laid out completely differently from every later record's — not the
same fields at shifted offsets, but two unrelated fixed byte sequences,
because the first record additionally carries the route's own name and
point count.

**The trailer** (34 bytes after the last record): a fixed 30-byte
prefix (`ffffffff` + 15 zero bytes + `01 00 0a 00 00 00`), followed by a
4-byte checksum. The checksum is plain CRC-32/IEEE (the same polynomial
and algorithm as `zlib.crc32`/PNG/gzip), computed over
`payload[1 : payload.length - 10]` — i.e. everything except the
payload's first byte and its last 10 bytes — encoded little-endian.
Verified to exactly reproduce two independent real captures' checksums.

### Names outside Latin-1

Names are encoded as Latin-1 (ISO-8859-1); nothing wider than that was
ever seen in a real capture, so there's no confirmed fallback for names
containing characters outside `U+0000`–`U+00FF`.

## Route/waypoint/track catalog (port 50615)

A completely separate channel from route sync — lists the objects
stored on the plotter and downloads/deletes individual ones. This is
also the channel the official app uses when a user syncs a
plotter-created route down into the app.

### Outer framing

```
[4-byte magic "MSG*" = 4d 53 47 2a][u32 LE length][payload]
```

Each payload's own inner structure is `[u32 LE topicId][u16 LE
msgType][...]`.

### Topics

`topicId` identifies which dataset a message concerns:

| Topic | Value | Notes |
|---|---|---|
| `topicWaypoints` | `0x1c` | Stable, hardcoded — confirmed identical across independent captures on different days |
| `topicRoutes` | `0x1d` | Same |
| `topicTrack` | `0x04` | The plotter's saved-track catalog — identified by fetching a real object on this topic and finding track-specific JSON fields (`dpth`/`temp`/`start`) not present on routes/waypoints |
| (unnamed) | `0x29` | Registered as part of the connection preamble on every connection; purpose not understood, replayed as a confirmed-necessary prerequisite |

Two other topic groups are registered by the real app's **second,
auxiliary connection** (see below) but aren't otherwise decoded:
`0x09, 0x0e, 0x0f, 0x11, 0x14, 0x1e, 0x22, 0x24, 0x2a`.

### Message types

| Name | Value | Direction |
|---|---|---|
| `tRegisterTopic` | `0x01` | C→S |
| `tRegisterTopicReply` | `0x0a` (sometimes `0x09`, both accepted) | S→C |
| `tCatalogSync` | `0x0b` | C→S |
| `tGetObject` | `0x0c` | Either direction (see below) |
| `tGetObjectReply` | `0x0d` | Either direction |
| `tGetObjectError` | `0x0e` | S→C — same fixed 8-byte body as `tRegisterTopicReply`, no correlation id of its own |
| `tCatalogSyncReply` | `0x0f` | S→C |
| `tDeleteEntry` | `0x02` | C→S, fire-and-forget, no reply |
| (feature-announcement) | `0x08` | Either direction, on the auxiliary connection only |

### Connection preamble and topic registration

A fresh connection must register `0x29` (sub=2) then `0x04` (sub=10)
**before** registering `topicRoutes`/`topicWaypoints`, in that order, or
the plotter rejects everything with an immediate `FIN`. Neither topic's
purpose is understood beyond this ordering requirement.

`tRegisterTopic`'s body: `[0x0a][u16 sub][8-byte correlationId]`. `sub`
is a per-topic constant, not per-request: `2` for `0x29`/`topicRoutes`,
`3` for `topicWaypoints`, `10` for `topicTrack`.

Registration replies don't need to be awaited before sending further
requests — the real app registers every topic it's about to use
back-to-back, with no reply awaited in between, and the plotter's own
registration replies routinely arrive *after* the client has already
sent everything, sometimes after the actual data reply. Blocking on a
registration reply before proceeding reproduces a class of silent
hangs.

A connection needs periodic keepalive traffic (the same `0x29`
registration-tag/`0x07` frame, roughly every 5 seconds) for its entire
lifetime, or the plotter closes it after ~20–25 seconds of inactivity —
independent of whether any catalog request is outstanding.

### Catalog sync (`tCatalogSync`/`tCatalogSyncReply`)

This is part of a generic, reusable digest-based merge/replication
mechanism the plotter uses internally for more than just
routes/waypoints — `topicId` is this mechanism's dataset id. The merge
is **two-way**: while a digest is being processed, the plotter can send
its own `tGetObject` request back on the same topic (asking for a
specific version, not a UUID) and won't send its own
`tCatalogSyncReply` until that's answered. A client must auto-reply by
echoing the plotter's request back as a `tGetObjectReply`.

**Requesting the full catalog from scratch (the common case — "I know
nothing yet")** uses a distinct, much shorter request shape than a
non-empty sync: 15 bytes total, a 1-byte length field, an 8-byte
correlation id, and a fixed 6-byte tail `05 02 01 00 09 00` — no
per-record-count header, no version field in the request body at all.
Live-confirmed to return the plotter's complete catalog (103 real
entries in one test) with no error.

**`tCatalogSyncReply`'s body** contains, after its own length prefix and
echoed correlation id, a flat list of fixed 26-byte records:

```
offset 0    : 1 byte  — varies per record, meaning unconfirmed
offset 1..5 : 5 bytes — varies per record, meaning unconfirmed
offset 6..9 : 4 bytes — fixed marker 02 07 11 10 on every record seen
offset 10..25: 16 bytes — the object's UUID
offset 26..31: 6 bytes — the object's own version-stamp (see "Version-stamp encoding" below), same LEB128-tagged format as the delete message's `del_vstamp` field
```

Right after the record list's own header (specifically, right after an
8-byte server-assigned "remote_ver" value — see below), the reply
carries a **real vs. total object count** field:
`<leb128 byte-length> 02 01 <leb128 realCount> 09 <leb128 extraCount>`,
where `realCount + extraCount` equals the raw record count. The catalog
can list more raw records than genuinely fetchable objects — a batch
request that includes one of the "extra" records simply gets no reply
at all. `realCount` is confirmed to match what a user can count on the
plotter's own screen.

### GetObject (`tGetObject`/`tGetObjectReply`)

**Single-object request:**

```
C->S tGetObject      payload = [u32 topicId][u16 0x000c][u16 len]
                               [u64 correlationId]
                               [01 01 01 01 07 11 10][16-byte UUID]
S->C tGetObjectReply payload = [u32 topicId][u16 0x000d][u16 len]
                               [u64 correlationId] (echoed back)
                               [some fixed bytes incl. a 05 07 11 10 marker + the same UUID again]
                               [gzip-compressed JSON, rest of payload]
```

**The 8-byte "correlation id" is not freely choosable** — it must be the
exact `remote_ver` value the server assigned in the immediately
preceding `tCatalogSync`'s reply (found at a fixed position right after
that reply's own echoed correlation id). Sending any other value gets
`tGetObjectError` back.

**Batch request** (`fetchObjects`, many uuids at once — confirmed to
work unchunked up to at least several hundred uuids in one request, no
practical batch-size limit found):

```
rest = leb128(len(A)) ++ A
A    = correlationId(8) ++ leb128(len(B)) ++ B
B    = 01 01 ++ leb128(uuids.length) ++ uuids.length × (01 07 11 10 ++ uuid(16))
```

The reply bundles one gzip+JSON blob per requested uuid, concatenated
with no separator between members.

**Decompressed object JSON:**

```json
{"name": "...", "uuid": "...", "auto_name": bool,
 "proto_ver": 2, "min_proto_ver": 1, "vstamp": 12345,
 "points": [{"lon": <int32>, "lat": <int32>}, ...]}
```

`lon`/`lat` use the same Garmin semicircle encoding as the route-sync
channel; tracks use `"id"` instead of `"name"` and carry extra `dpth`/
`temp`/`start` fields per point.

### Version-stamp encoding

Several fields across this protocol (a topic's `remote_ver`, an
object's `vstamp`) share the same packed bitfield shape:

```
value = (seq: u32 << 32) | sub: u32
sub   = randomByte: u8 | (productNumber: u4 << 8) | (deviceUnitId: u20 << 12)
```

`productNumber` is `0` in every value this client generates (no real
Garmin product number is known), but a real plotter-issued value was
independently observed carrying `13` there — don't assume `0` is
structurally required, only that it's what this client currently emits.
`deviceUnitId` is a real per-device hardware identity value this client
has no legitimate way to know; it's stood in for by an arbitrary
process-stable random value. **Live-isolation-tested**: the plotter
does not validate this identity field against any previously-known
device for the delete path — any 20-bit value works.

Where a `newVer`/incremented value is needed, `seq` is the previous
value's `seq` incremented by exactly 1 (confirmed across every real
delete capture available, no exceptions), and `sub`'s random byte /
device-identity bits are freshly drawn — the real app does the same,
so there is no "correct" reproducible value to match, only the right
shape.

### Deleting a catalog entry (`tDeleteEntry`, `0x02`)

A dedicated, fire-and-forget message — **not** wrapped in
`tCatalogSync`/`tGetObject`, and confirmed to get no reply from the
plotter in any real capture or live test. **Live-confirmed working**
against a real plotter, independently three times across different
routes and connection configurations.

Wire format (all offsets relative to the body right after
`[4-byte topicId LE][2-byte msgType LE]`):

```
byte[0]      "outer length" tag — a self-referential unsigned LEB128
             vint encoding the exact byte length of everything from
             byte[1] to the end of the message, INCLUDING this tag
             field's own encoded width. Solved by finding a fixed
             point of `value = totalMessageLength - lebByteLength(value)`.
             Confirmed against 4 distinct real (totalLen -> tagValue)
             pairs from two independent physical devices: 49->48,
             50->49, 260->258, 805->803.
bytes[1:9]   8-byte previous remote_ver for this topic (see
             "Version-stamp encoding" above) — the real, server-synced
             value from this topic's most recent tCatalogSync reply.
bytes[9:17]  8-byte NEW remote_ver this delete establishes — seq is
             prevRemoteVer.seq + 1, exactly.
byte[17]     length byte = exact number of bytes remaining from
             byte[18] onward.
bytes[18:23] `01 07 <A> 03 <B>`, where `A = 23 + lebLen`, `B = 21 + lebLen`,
             and `lebLen` is the exact byte length of the `del_vstamp`
             field's own LEB128 encoding (0 if `del_vstamp` is
             omitted). This is a general framing pattern this
             protocol's message-serialization layer uses — the bytes
             describe how big the rest of this specific message is,
             not a session-local counter (an earlier theory that it
             increments per delete was a coincidence of a
             too-small sample).
bytes[23:27] `02 07 11 10` — `02` = present-optional-field count
             (1 if del_vstamp is omitted, 2 if present), `07 11 10` =
             the mandatory uuid field's own tag/size/length prefix:
             `07` = `(fieldId=0 << 3) | 7` (a field tag with an
             "overflow, size given separately" pattern), `11` = 17
             (the field's own overflow byte count), `10` = 16 (the
             actual uuid byte length that follows).
bytes[27:43] the 16-byte target UUID.
bytes[43:]   the optional `del_vstamp` field: `<tag byte><LEB128
             bytes>`. The tag byte is `(fieldId << 3) | lebLen` —
             `del_vstamp` is fieldId=1 (the field right after uuid),
             so e.g. a 5-byte LEB128 value gets tag `(1<<3)|5 = 0x0d`,
             NOT the bare length `0x05`. **This tag-byte encoding was
             the single remaining bug that made every earlier delete
             attempt fail silently** — sending fieldId=0 there made
             the field collide with the uuid field from the plotter's
             own decoder's point of view, discarding the whole
             message with no error, no rejection, and no visible
             lockout. The del_vstamp *value* itself is a freshly
             incremented version of the object's own last-known
             vstamp (seq+1, fresh random sub) — not a checksum and
             not the object's vstamp reused verbatim.
```

### The auxiliary connection

The real app keeps a **second**, separate connection to port 50615
open for the entire lifetime of a session, alongside the main
route-catalog connection — including through an observed real delete.
It registers a different set of topics (see above) directly, with
**no** `0x29`/`0x04` preamble at all (unlike the main connection), and
periodically exchanges feature-announcement messages (`msgType 0x08`)
on those topics — the plotter announces each registered feature by a
human-readable name inside the payload (e.g. "OneChart",
"QuickDraw-Upload", "DepthLogs-Download"), and the real app answers each
with its own reply echoing a correlation id back and a fixed 32-byte
tail.

This connection's actual necessity for a successful delete is
unresolved — extensive live testing both with and without it present
was inconclusive, confounded by the plotter's own reply-reliability
behavior (see below). It was not present in the connection that
achieved a confirmed-working delete, so it is not required for that
specific operation, at least not on the plotter tested against.

### A note on plotter reply reliability

Live testing found the plotter can become unresponsive ("no reply")
after certain requests, sometimes for an extended period, sometimes
clearing on an immediate retry. This is a real, observed operational
characteristic of the physical device tested against, not a specific
protocol detail — don't assume a single "no reply" result means a
wire-format bug; a fresh retry is usually the fastest way to tell the
two apart.
