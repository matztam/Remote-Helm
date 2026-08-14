/// Route/waypoint/track catalog download — lists the objects stored on the
/// plotter and fetches individual ones, so they can be exported as GPX (the
/// download counterpart of `route_sync.dart`'s upload).
///
/// This has no prior documentation anywhere — the whole protocol described
/// in this file was reverse-engineered by analyzing traffic between the
/// real ActiveCaptain app and a real plotter. Two initial captures were
/// used: one with a route named "ZZZZZZ" (73 routes / 118
/// waypoints / 1 track total on that plotter) and a second, cleaner one
/// with a route named "YYYY", cross-checked against a full GPX export of
/// the same plotter's data (`vstamp`/`uuid`/coordinates matched
/// byte-for-byte); many more captures across several independent
/// devices/app-installs followed as specific fields needed pinning down.
///
/// ### It's a completely different channel from the upload one
///
/// Route upload (`route_sync.dart`) uses port 50610 with the same `0xBEEF`
/// framing as the touch/control session. This is unrelated: it's on port
/// [routeCatalogPort] (50615), and uses its own outer framing —
/// `MSG*` (`4d 53 47 2a`) magic bytes + `u32 LE` length + payload — with yet
/// another, inner message structure: `[u32 LE topicId][u16 LE msgType][...]`.
///
/// ### Topics are fixed, not session-negotiated
///
/// [topicRoutes] (0x1d) and [topicWaypoints] (0x1c) are stable, hardcoded
/// values — confirmed identical across two entirely independent captures on
/// different days. They are *not* per-connection sequence numbers (a
/// separate `ActiveCaptain-to-vessel` topic string/id pair, part of a
/// different registration mechanism entirely, was checked and does not
/// correlate).
///
/// ### Topic registration (msgType [tRegisterTopic]) and the connection
/// preamble
///
/// [tCatalogSync]/[tGetObject] on a fresh connection are
/// rejected outright (the plotter replies with an immediate `FIN`, no
/// data) unless the connection first registered [topicRoutes]/
/// [topicWaypoints] via `tRegisterTopic`. That alone wasn't enough,
/// though — live testing kept getting rejected until the *exact* sequence
/// seen in the real captures was replayed: **every capture examined
/// registers two other topics, `0x29` (sub=2) then `0x04` (sub=10), before
/// ever touching [topicRoutes]/[topicWaypoints] on the same connection.**
/// Once [_ensurePreamble] replays that pair first, registering
/// [topicRoutes]/[topicWaypoints] itself stopped being rejected. Neither
/// `0x29` nor `0x04`'s purpose is understood — they're replayed as an
/// opaque prerequisite, confirmed necessary by testing, not explained.
///
/// `tRegisterTopic`'s body: `[0x0a][u16 sub][8-byte correlationId]`, where
/// `sub` is [_registerTopicSub] (confirmed constant per topic, not
/// per-request — 2 for `0x29`/[topicRoutes], 3 for [topicWaypoints], 10
/// for `0x04`). The reply's `msgType` was **not** consistent between the
/// original capture (`0x0a`) and live re-testing weeks later against the
/// same real plotter (`0x09`) — [_registerTopic] accepts either rather
/// than treating the mismatch as an error, since nothing about the reply's
/// payload is understood well enough to validate beyond "something with
/// this topic id came back."
///
/// ### Catalog sync: a generic digest/merge framework
///
/// [tCatalogSync] (`0x0b`)/[tGetObject] (`0x0c`) are part of a
/// generic, reusable digest-based merge/replication framework the plotter
/// uses internally for several kinds of data, not something specific to
/// routes/waypoints. [topicId] is this framework's **dataset id**.
///
/// `tRegisterTopic` (`0x01`) doubles as this framework's own "register
/// this dataset" step — not a separate init message. The server only
/// accepts a digest (`tCatalogSync`) once the connection's dataset state
/// has advanced past registration and the plotter itself has decided a
/// merge is needed — an unregistered or not-yet-ready topic silently
/// ignoring a digest is exactly what accounted for a long stretch of
/// "no digest style merge" symptoms early in this investigation.
///
/// **The blocking bug**: [_registerTopic] used to `await` the
/// registration reply before doing anything else. Re-checking that
/// against fresh real captures showed the real app never does that — a
/// real client send burst looks like (topic, msgType) pairs sent
/// back-to-back with **no reply awaited in between**:
/// ```
/// C->S: INIT(0x04) INIT(0x1c) INIT(0x1d) INIT(0x29)
///       tCatalogSync(0x1c) tCatalogSync(0x1d)
///       tGetObject(0x1c) tGetObject(0x1d)
///       ...keepalives...
/// S->C: (nothing at all until the whole burst above is sent)
///       tRegisterTopicReply(0x1c) tRegisterTopicReply(0x1d)
///       tGetObject(0x1c) tGetObject(0x1d)   -- yes, the plotter also
///                                              sends 0x0c *to* the client;
///                                              this is a two-way merge,
///                                              not a plain download
///       tCatalogSyncReply(0x1c) tCatalogSyncReply(0x1d)
///       tGetObjectReply(0x1c) tGetObjectReply(0x1d)
/// ```
/// The plotter's own registration reply consistently arrives **after**
/// the client has already sent everything, sometimes after the digest
/// reply itself. [fetchCatalog] blocking on that reply before sending
/// the digest was waiting for an ordering the plotter never produces —
/// this is now fixed: [_registerTopic] fires and forgets, and
/// [fetchCatalog] registers **both** [topicWaypoints] and [topicRoutes]
/// up front regardless of which one is being fetched, matching every
/// real capture examined (even sessions that only end up syncing one of
/// the two still register both first). [fetchObject] is untouched — it
/// was already confirmed working live with the old blocking-wait
/// behavior, and there's no capture evidence that ordering is wrong for
/// it specifically, only for [fetchCatalog].
///
/// ### The catalog record format
///
/// The flat list of 26-byte `[6 unknown bytes][02 07 11 10 marker]
/// [16-byte UUID]` records this file parses is confirmed correct against
/// real traffic — re-extracting a real 101-record [tCatalogSync] request
/// byte-for-byte from a capture confirms every record is exactly 26 bytes
/// with the marker at a fixed sub-offset, no exceptions:
/// ```
/// offset 0    : 1 byte  — varies per record, meaning unconfirmed
/// offset 1..5 : 5 bytes — varies per record, meaning unconfirmed
/// offset 6..9 : 4 bytes — fixed marker 02 07 11 10 on every record seen
/// offset 10..25: 16 bytes — the object's UUID
/// ```
///
/// ### The merge is two-way
///
/// Replaying a real, complete captured [tCatalogSync] payload (2660 bytes,
/// 101 real UUID records, only the correlation id patched) against a real
/// plotter — after the registration-timing fix above — got a real
/// [tCatalogSyncReply] back (2703 bytes, all 101 route UUIDs recovered).
/// This confirms the merge is bidirectional — mid-merge, the plotter sent
/// its **own** [tGetObject] request back on the same topic, asking for a
/// specific version, not a UUID (body shape `0c <8-byte version> 03 01 01
/// 00`, byte-for-byte the same as this client's own real captured
/// `0x0c`/`0x0d` pair) and would not send its own [tCatalogSyncReply]
/// until that was answered. [fetchCatalog] and the debug helpers below now
/// auto-reply by echoing the plotter's own request back as a
/// [tGetObjectReply] — confirmed live to unblock the exchange.
///
/// ### The empty-catalog (N=0) request
///
/// A capture of a genuine first-ever sync — a fully reset app, left to
/// sync once against a plotter it had never seen before — showed that
/// requesting an "everything, starting from nothing known" catalog uses a
/// **structurally different** request from a non-empty [tCatalogSync]:
/// only **15 bytes** total, with a **1-byte** length field (not 2), an
/// 8-byte correlation id, and a fixed 6-byte tail (`05 02 01 00 09 00`) —
/// no per-record-count header field, no `remote_ver` field in the request
/// body at all. All three registered topics in that capture sent
/// byte-identical bodies (differing only in the correlation id), and it
/// got a real [tCatalogSyncReply] back. [fetchCatalog] replays this exact
/// byte pattern.
///
/// **Confirmed live**: the connection stayed open, the server-initiated
/// [tGetObject] mid-merge was answered correctly, a real
/// [tCatalogSyncReply] came back, and [fetchCatalog] returned **103 real
/// catalog entries** — no error, no rejection. This closed what was, for a
/// long stretch of this investigation, the central open question — an
/// earlier hand-fitted "records × constant + intercept" formula for the
/// non-empty request's header fields does not extend to the empty case,
/// which turned out to need this entirely different, much shorter shape
/// instead.
///
/// ### GetObject (msgType [tGetObject]/[tGetObjectReply])
///
/// Once an object's GUID is known (from the catalog, or a caller-supplied
/// one), it's fetched individually:
/// ```
/// C->S tGetObject      payload = [u32 topicId][u16 0x000c][u16 len]
///                                [u64 correlationId]
///                                [01 01 01 01 07 11 10][16-byte UUID]
/// S->C tGetObjectReply payload = [u32 topicId][u16 0x000d][u16 len]
///                                [u64 correlationId] (same value echoed back)
///                                [some fixed bytes incl. a 05 07 11 10
///                                 marker + the same UUID again]
///                                [gzip-compressed JSON, rest of payload]
/// ```
/// The decompressed JSON (confirmed byte-exact against real GPX-exported
/// coordinates for both captured routes):
/// ```json
/// {"name": "...", "uuid": "...", "auto_name": bool,
///  "proto_ver": 2, "min_proto_ver": 1, "vstamp": 12345,
///  "points": [{"lon": <int32>, "lat": <int32>}, ...]}
/// ```
/// `lon`/`lat` are Garmin semicircle-encoded (`degrees = value * 180 / 2^31`
/// — the inverse of `route_sync.dart`'s `_toSemicircle`), verified to
/// match a real GPX export's coordinates to within floating-point rounding
/// (~1e-11 degrees) for both captured routes (4 and 8 points).
///
/// ### ⚠ Known gaps
///
/// - **[fetchCatalog]'s N=0 (empty known-list) request is confirmed
///   working live** — see this file's top doc comment's "The empty-catalog
///   (N=0) request" section for the byte format and how it was found. The
///   record layout (26 bytes, fixed `02 07 11 10` marker at sub-offset 6)
///   is re-confirmed against three independent real captures — 101, 102,
///   and 103 records — with zero exceptions; the registration-timing fix,
///   the bidirectional [tGetObject] merge exchange, and the background
///   keepalive fix ([_keepaliveTimer]) all confirmed working together in
///   one successful live run. [tCatalogSyncReply]'s own reply-header
///   fields beyond what's used here are still not fully decoded — it
///   carries at least 3 consecutive 8-byte fields after its header, one of
///   which is very likely the version a client would need for a *repeat*
///   sync, not investigated further since [fetchCatalog] doesn't persist
///   state across calls.
/// - [fetchObject] (fetching a single object once its UUID is already
///   known some other way) *is* confirmed working live against a real
///   plotter, once [_registerTopic] is called first — this part of the
///   protocol is solid.
/// - No track was ever fetched in either capture — only routes and
///   waypoints are confirmed to work through [fetchObject].
/// - The exact meaning of the catalog record's first 6 bytes (before the
///   `02 07 11 10` marker) isn't understood; only the trailing UUID is used.
/// - Waypoint-only objects' JSON shape (a single `{"lon","lat"}` pair
///   without a `points` list, or a `points` list of length 1?) was not
///   directly observed — both captures only ever fetched a route object.
///   [fetchObject] handles both a `points` array and top-level `lon`/`lat`
///   defensively, but this is a guess, not a confirmed fallback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'route_sync.dart' show RoutePoint;

export 'route_sync.dart' show RoutePoint;

/// The route/waypoint/track catalog & download service's own port —
/// observed fixed at this value in both captures.
const int routeCatalogPort = 50615;

const List<int> _msgMagic = [0x4D, 0x53, 0x47, 0x2A]; // "MSG*"

const int topicWaypoints = 0x1c;
const int topicRoutes = 0x1d;

/// The plotter's saved-track catalog — **identified live 2026-08-07**.
/// This is the same topic previously only known as the mysterious third
/// preamble topic (`_preambleTopics`), long suspected (see this file's top
/// doc comment) but never confirmed to carry anything useful — earlier
/// investigation found syncing it *in addition to* [topicRoutes]/
/// [topicWaypoints] was actively harmful ([debugSyncOtherTopics] is `false`
/// by default because of this), so it was never explored as a catalog in
/// its own right. Confirmed by fetching a real captured `tGetObjectReply`
/// on this topic and finding the decompressed JSON's `id` field
/// (`"03-AUG-22"`) matched a real track name the user confirmed existed on
/// the plotter, with `points` entries carrying `dpth`/`temp`/`start`
/// fields routes/waypoints don't have. Unlike [topicRoutes]/
/// [topicWaypoints], a single-track-object reply had only ONE gzip member
/// (5000 points) rather than many small ones, consistent with plotters
/// typically holding only one or a few tracks at a time versus dozens of
/// routes/waypoints.
const int topicTrack = 0x04;

const int tRegisterTopic = 0x01;
const int tRegisterTopicReply = 0x0a;
const int tCatalogSync = 0x0b;
const int tCatalogSyncReply = 0x0f;
const int tGetObject = 0x0c;
const int tGetObjectReply = 0x0d;

/// A second, error-shaped reply to [tGetObject], discovered via live
/// testing against a real plotter: the same request that earlier got a
/// real [tGetObjectReply] instead got this — same fixed 8-byte body as
/// [tRegisterTopicReply] (`08 00 00 00 00 00 00 00`), no correlation id.
/// Exact meaning unconfirmed (no successful retry after seeing it), but
/// its shape (same as the "something went differently" pattern of
/// [tRegisterTopicReply]) and the fact it replaces the expected reply
/// strongly suggest a rejection/not-found rather than a transient glitch.
/// [fetchObject] treats it as a hard failure rather than continuing to
/// wait for a [tGetObjectReply] that will now never arrive.
const int tGetObjectError = 0x0e;

/// Deletes a single catalog entry (route/waypoint) — a dedicated
/// fire-and-forget message, **not** [tCatalogSync]. Discovered and
/// byte-for-byte confirmed against 3 independent real captures of the
/// official app deleting a route (2026-08-08) — see [deleteEntry]'s doc
/// comment for the full wire format derivation.
const int tDeleteEntry = 0x02;

/// The fixed tag byte at the start of a [tRegisterTopic] request's body —
/// constant across every registration seen in both captures.
const int _registerTopicTag = 0x0a;

/// The "sub" field (a u16 after [_registerTopicTag]) confirmed constant
/// *per topic id*, not derived from anything a client would compute: 2 for
/// [topicRoutes], 3 for [topicWaypoints], and (already known from
/// [_preambleTopics], now also usable for [_registerTopic] callers)
/// 10 for [topicTrack]. Meaning otherwise unconfirmed — see this file's
/// top doc comment.
///
/// **Auxiliary topics added 2026-08-09**, extracted byte-for-byte from the
/// real app's SECOND parallel connection in the `dc548113` capture (the
/// one carrying periodic feature-announcement traffic, never fully
/// decoded — see this file's top doc comment) which runs for the entire
/// lifetime of a session alongside the main route-catalog connection,
/// including through an observed real delete: `0x09`->100, `0x0e`->9,
/// `0x0f`->9, `0x11`->1, `0x14`->2, `0x1e`->2, `0x22`->1, `0x24`->3,
/// `0x2a`->2. See [RouteCatalogConnection.registerAuxiliaryTopics].
const Map<int, int> _registerTopicSub = {
  topicRoutes: 2,
  topicWaypoints: 3,
  topicTrack: 10,
  0x09: 100,
  0x0e: 9,
  0x0f: 9,
  0x11: 1,
  0x14: 2,
  0x1e: 2,
  0x22: 1,
  0x24: 3,
  0x2a: 2,
};

/// Every topic the real app's second, auxiliary connection registers
/// alongside the main route-catalog connection — see [_registerTopicSub]'s
/// doc comment for where these came from.
const List<int> auxiliaryTopics = [0x09, 0x0e, 0x0f, 0x11, 0x14, 0x1e, 0x22, 0x24, 0x2a];

/// The fixed marker preceding a UUID in a catalog record (see this file's
/// top doc comment).
const List<int> _catalogUuidMarker = [0x02, 0x07, 0x11, 0x10];

/// The fixed marker preceding a UUID in a [tGetObject] request — different
/// from [_catalogUuidMarker], confirmed identical across both captures.
const List<int> _getObjectRequestMarker = [0x01, 0x01, 0x01, 0x01, 0x07, 0x11, 0x10];

/// The fixed 6-byte tail of a [tCatalogSync] N=0 (empty-list) request body,
/// byte-for-byte from the real capture that resolved [RouteCatalogConnection.
/// fetchCatalog]'s N=0 request (see this file's top doc comment) — shared by
/// every place that sends this exact request shape.
const List<int> _catalogSyncN0Tail = [0x05, 0x02, 0x01, 0x00, 0x09, 0x00];

const int _kCatalogRecordSize = 26;

/// Parses [CatalogEntry] records out of a [tCatalogSyncReply] body,
/// scanning for [_catalogUuidMarker] rather than decoding every header
/// byte — see [RouteCatalogConnection._fetchCatalog]'s doc comment.
/// [topic] is stamped onto every returned entry; it does not affect
/// parsing (the same record layout is used regardless of which topic the
/// reply came from — confirmed against `0x4`'s own single-entry
/// [tCatalogSyncReply] as well as [topicWaypoints]'/[topicRoutes]' much
/// larger ones).
///
/// **The trailing 6 bytes after each UUID (found live 2026-08-08) are
/// that entry's own `vstamp`** — the exact same 1-byte-length-prefixed
/// unsigned LEB128 format [RouteCatalogConnection.deleteEntry]'s
/// `del_vstamp` trailer uses (confirmed: decoding a real capture's
/// trailing bytes, e.g. `0d bd ea c4 de 39`, as
/// length-byte-then-LEB128 gives a plausible large integer, and the
/// length byte follows the same `len(payload)+7` convention already
/// known from the delete trailer). This means the plotter already tells
/// the client every catalog entry's `vstamp` in the same reply that
/// lists its UUID — a real client-driven delete doesn't need (and, per a
/// real capture, never sends) a separate per-object [tGetObject] just to
/// learn it.
List<CatalogEntry> _parseCatalogEntries(Uint8List body, int topic) {
  final entries = <CatalogEntry>[];
  var i = 0;
  while (i + _kCatalogRecordSize <= body.length) {
    final markerOff = i + 6;
    if (_bytesEqual(Uint8List.sublistView(body, markerOff, markerOff + 4), Uint8List.fromList(_catalogUuidMarker))) {
      final uuidBytes = Uint8List.sublistView(body, markerOff + 4, markerOff + 4 + 16);
      final trailerOff = markerOff + 4 + 16;
      final vstamp = _decodeCatalogEntryVstamp(body, trailerOff);
      entries.add(CatalogEntry(uuid: _formatUuid(uuidBytes), topic: topic, vstamp: vstamp));
      i += _kCatalogRecordSize;
    } else {
      i++; // resync: header/record boundary isn't fully understood
    }
  }
  return entries;
}

/// The inverse of [_parseCatalogEntries]: builds a non-empty [tCatalogSync]
/// request body listing [known] entries' `[vstamp, uuid]` pairs, in the
/// exact wire format [_parseCatalogEntries] already parses out of a
/// [tCatalogSyncReply] — **reverse-engineered 2026-08-13** from a real
/// capture (`0d2f840f`, a plotter user-data reset followed by a real
/// ActiveCaptain backup restore) whose client-sent, non-empty
/// [tCatalogSync] request bodies parsed cleanly with [_parseCatalogEntries]'s
/// own marker-scan algorithm (75 real route uuids, 128 raw waypoint
/// records, 1 track record, zero exceptions) — confirming the request uses
/// the identical 26-byte-record shape as the reply, not a separate format.
///
/// Real capture's outer structure (`topic`/`type` header omitted, this
/// function returns only the bytes after those 6 bytes):
/// ```
/// [2-byte-LEB128 outerLen][8-byte correlationId][2-byte-LEB128 innerLen]
/// [0x02 0x01][LEB128 count]
/// [record]×count   -- each record: [0x0d][≤6-byte LEB128 vstamp]
///                     [0x02 0x07 0x11 0x10][16-byte uuid]
/// ```
/// `outerLen`/`innerLen` each count only the bytes strictly after their own
/// field — **not** self-referential (unlike some other length fields in
/// this file, e.g. [RouteCatalogConnection._solveSelfReferentialLeb128Length]'s
/// callers): confirmed against the real capture, where `outerLen`'s decoded
/// value exactly equalled the byte count from right after the `outerLen`
/// field to the message's end (and likewise for `innerLen`), with no
/// adjustment for either field's own encoded width.
///
/// The vstamp length byte is `actualLebLength(vstamp) + 8` —
/// **corrected 2026-08-14**, after re-examining the one real-capture
/// record (the request's very first) that used `0x09` instead of the
/// `0x0d` every other of the 74 remaining records used, which Update 33
/// had left unresolved (couldn't reconcile it as either the declared
/// upper bound or the actually-consumed length under the `-7`-offset
/// formula [_decodeCatalogEntryVstamp]'s doc comment describes for the
/// DECODE side). That record's own `vstamp` decoded to `1`, whose LEB128
/// encoding is exactly 1 byte — `1 + 8 = 9 = 0x09`, matching exactly; the
/// other 74 records' `vstamp`s all needed the full 5-byte LEB128 encoding
/// typical of large real version-stamps — `5 + 8 = 13 = 0x0d`, also
/// matching exactly. Both real examples agree on `+8`, not the decode
/// side's `+7` (that formula only has to work as a safe upper bound for
/// parsing, per its own doc comment — it was never claimed to be the
/// exact encode-side rule). A `null`/missing `vstamp` (an entry
/// [_parseCatalogEntries] couldn't decode one for) is sent as `0` rather
/// than omitted — untested — but keeps every entry in [known]
/// representable rather than silently dropping it from the request.
///
/// [correlationId] is spliced in directly (not solved for) — its own
/// 8-byte width, fixed regardless of value, is all the length math below
/// needs to account for.
Uint8List _buildCatalogSyncBody(List<CatalogEntry> known, Uint8List correlationId) {
  final records = BytesBuilder(copy: false);
  for (final entry in known) {
    final vstampBytes = _leb128(entry.vstamp ?? 0);
    records
      ..add([vstampBytes.length + 8])
      ..add(vstampBytes)
      ..add(_catalogUuidMarker)
      ..add(_parseUuid(entry.uuid));
  }
  final recordBytes = records.toBytes();

  final inner = BytesBuilder(copy: false)
    ..add(const [0x02, 0x01])
    ..add(_leb128(known.length))
    ..add(recordBytes);
  final innerBytes = inner.toBytes();

  // innerLen counts only innerBytes -- correlationId sits BEFORE the
  // innerLen field and isn't part of what it counts.
  final innerLenBytes = _leb128(innerBytes.length);

  final afterOuterLen = BytesBuilder(copy: false)
    ..add(correlationId)
    ..add(innerLenBytes)
    ..add(innerBytes);
  final afterOuterLenBytes = afterOuterLen.toBytes();
  // outerLen counts everything after the outerLen field itself
  // (correlationId + innerLenBytes + innerBytes).
  final outerLenBytes = _leb128(afterOuterLenBytes.length);

  return Uint8List.fromList([...outerLenBytes, ...afterOuterLenBytes]);
}

/// Decodes one catalog entry's trailing `vstamp` field at [offset] in
/// [body] — see [_parseCatalogEntries]'s doc comment for the format
/// (1-byte length, `len(payload)+7`, followed by that many unsigned
/// LEB128 bytes). Returns null rather than throwing on anything
/// unexpected (a record layout this file doesn't fully understand
/// shouldn't take down catalog parsing entirely) — callers needing a
/// `vstamp` (like [RouteCatalogConnection.deleteEntry]) fall back to
/// fetching the object individually when this is null.
///
/// **`lengthByte - 7` is an upper bound on the varint's byte count, not
/// its exact length — fixed 2026-08-08** after every single live catalog
/// entry (including the very first raw record, ruling out any
/// `validCount`-trim involvement) failed to decode and fell back to
/// [RouteCatalogConnection.fetchObject], something the real app never
/// does before a delete. A real captured delete trailer (`0d 9f f1 ce 92
/// 71`) has `lengthByte=0x0d` (`payloadLen=6` by the old formula) but its
/// LEB128 continuation bit actually clears on the 5th payload byte, not
/// the 6th — standard LEB128 decoding (stop at the first byte with the
/// continuation bit clear) already produces the right value; the old
/// code additionally required that stop to land exactly on
/// `payloadLen - 1` and returned null otherwise, which is the bug.
int? _decodeCatalogEntryVstamp(Uint8List body, int offset) {
  if (offset >= body.length) return null;
  final lengthByte = body[offset];
  final maxPayloadLen = lengthByte - 7;
  if (maxPayloadLen < 1 || offset + 1 + maxPayloadLen > body.length) return null;
  var value = 0;
  var shift = 0;
  for (var i = 0; i < maxPayloadLen; i++) {
    final b = body[offset + 1 + i];
    value |= (b & 0x7f) << shift;
    shift += 7;
    if (b & 0x80 == 0) {
      return value; // standard LEB128: stop at the first byte with the continuation bit clear
    }
  }
  return null; // ran out of bytes without a terminating (continuation-bit-clear) byte
}

/// One entry from the plotter's object catalog: enough to show in a list
/// and to fetch the full object on demand via [fetchObject].
class CatalogEntry {
  final String uuid;
  final int topic;

  /// This entry's own plotter-assigned version-stamp, decoded straight
  /// from the [tCatalogSyncReply] record — see [_parseCatalogEntries]'s
  /// doc comment. Null if this record's trailing bytes didn't decode as
  /// expected (rare/unconfirmed shape, not normally expected against a
  /// real plotter).
  final int? vstamp;

  const CatalogEntry({required this.uuid, required this.topic, this.vstamp});

  bool get isRoute => topic == topicRoutes;
  bool get isWaypoint => topic == topicWaypoints;
}

/// A fully-downloaded route/waypoint object, decoded from [fetchObject]'s
/// gzip+JSON reply.
class DownloadedObject {
  final String name;
  final String uuid;
  final List<RoutePoint> points;

  /// The object's own `"vstamp"` field from the plotter's JSON reply (see
  /// this file's top doc comment's "GetObject" section) — the plotter's
  /// own version-stamp for *this specific object*, as opposed to
  /// [RouteCatalogConnection]'s per-topic `remote_ver`. Null if the reply
  /// didn't include one (shouldn't normally happen for a real object, but
  /// nothing here assumes it's always present). Used by [RouteCatalogConnection.
  /// deleteEntry] as `del_vstamp`, on the theory that the plotter wants to
  /// know the client's request reflects a specific, already-known object
  /// version rather than an arbitrary/newer-than-the-catalog claim like
  /// the topic's own `remote_ver` would be.
  final int? vstamp;

  const DownloadedObject({required this.name, required this.uuid, required this.points, this.vstamp});
}

class RouteCatalogException implements Exception {
  final String message;
  const RouteCatalogException(this.message);
  @override
  String toString() => 'route catalog: $message';
}

/// A catalog change the plotter pushed to this connection on its own,
/// without this client having asked — see [RouteCatalogConnection.pushes]'
/// doc comment for the full background. Either an add/update (carries the
/// full [DownloadedObject]) or a delete (carries only the removed uuid).
sealed class CatalogPush {
  final int topic;
  const CatalogPush(this.topic);
}

class CatalogPushUpdate extends CatalogPush {
  final DownloadedObject object;
  const CatalogPushUpdate(super.topic, this.object);
}

class CatalogPushDelete extends CatalogPush {
  final String uuid;
  const CatalogPushDelete(super.topic, this.uuid);
}

/// Builds one outer `MSG*` frame: `[MSG*][u32 LE length][payload]`.
Uint8List _buildMsgFrame(List<int> payload) {
  final out = Uint8List(8 + payload.length);
  out.setRange(0, 4, _msgMagic);
  ByteData.view(out.buffer).setUint32(4, payload.length, Endian.little);
  out.setRange(8, 8 + payload.length, payload);
  return out;
}

/// A parsed inner message: `[u32 LE topicId][u16 LE msgType][...rest]`.
class _InnerMessage {
  final int topicId;
  final int msgType;
  final Uint8List rest;
  const _InnerMessage(this.topicId, this.msgType, this.rest);
}

/// Parses as many complete outer `MSG*` frames as possible from [buf],
/// returning the decoded inner messages and how many bytes were consumed.
({List<_InnerMessage> messages, int consumed}) _parseMsgFrames(Uint8List buf) {
  final messages = <_InnerMessage>[];
  var off = 0;
  final n = buf.length;
  while (off + 8 <= n) {
    if (buf[off] != _msgMagic[0] ||
        buf[off + 1] != _msgMagic[1] ||
        buf[off + 2] != _msgMagic[2] ||
        buf[off + 3] != _msgMagic[3]) {
      break; // not resyncing: a corrupt stream here means the connection is unusable anyway
    }
    final length = ByteData.sublistView(buf, off + 4, off + 8).getUint32(0, Endian.little);
    if (off + 8 + length > n) break;
    final payload = Uint8List.sublistView(buf, off + 8, off + 8 + length);
    if (payload.length >= 6) {
      final topicId = ByteData.sublistView(payload, 0, 4).getUint32(0, Endian.little);
      final msgType = ByteData.sublistView(payload, 4, 6).getUint16(0, Endian.little);
      messages.add(_InnerMessage(topicId, msgType, Uint8List.sublistView(payload, 6)));
    }
    off += 8 + length;
  }
  return (messages: messages, consumed: off);
}

/// **Not a free-form counter — found 2026-08-08** by reverse engineering
/// the plotter's own version-stamp packing logic, after
/// thirteen live deletes with a plain `1, 2, 3, ...` counter (this file's
/// previous implementation) all structurally sent fine but never actually
/// removed the entry. Every real captured `tRegisterTopic`'s 8-byte
/// "correlation id" decodes as a version-stamp value: `(seq << 32) |
/// sub`, with `seq` always `0xfe` (254) — and `sub`'s upper 24 bits
/// (`[8:32)`: product
/// number + unit id) an app-device-specific constant, confirmed identical
/// (`0x6c296` in the `unitId` sub-field) across all 4 real registration
/// messages in one capture AND the same real capture's own delete
/// message's `newRemoteVer` — i.e. the phone app's version-stamp device
/// constant is the same value in both places, not a coincidence. This
/// client has no confirmed real device identity to derive that constant
/// from. [debugClientUnitId] lets a caller (e.g. `helm_cli.dart`) plug in
/// this connection's paired [HelmIdentity]'s own `client_generated_token`
/// as a plausible stand-in — plausible because the plotter already knows
/// that value from HTTP pairing (see `credential.dart`) and it's the only
/// device-specific 32-bit-ish value this library has at all — on the
/// theory that the plotter might only accept writes from a version-stamp
/// device id it recognizes from pairing. Falls back to one arbitrary-but-
/// fixed-per-process 20-bit value when not set. Reused everywhere a
/// version-stamp-shaped value is needed ([_registerTopic]'s correlation
/// id, [deleteEntry]'s `newRemoteVer`) — matching the real protocol's
/// *shape* even when the exact device-identity bits are a guess.
int? debugClientUnitId;
int get _clientUnitId => (debugClientUnitId ?? _clientUnitIdFallback) & 0xFFFFF;
final int _clientUnitIdFallback = Random().nextInt(0x100000) & 0xFFFFF;

int _syncVerStampSeq = 0xfe;

/// A per-topic "dataset version stamp", stable for the lifetime of this
/// running process (module-level, not per-[RouteCatalogConnection]) —
/// **inferred 2026-08-14** from the real app's observed registration
/// behavior: across many real captures, a given topic's [tRegisterTopic]
/// correlation id was always the same value, never freshly random,
/// including across separate connections and app restarts days apart.
/// That's only explainable if the real app generates this value once ever
/// (the first time it's needed) and persists it locally from then on,
/// rather than picking a new one per connection.
/// The real app registers each topic/dataset with a version stamp read
/// from its own on-disk database — generated once, ever, then reused
/// forever after (across reconnects AND app restarts, since it's
/// persisted locally). This client has no on-disk persistence yet, so
/// this only replicates the "stable within one running process" part:
/// generated once per topic, the first time [_registerTopic] needs one,
/// then reused for every later registration of that same topic on any
/// later [RouteCatalogConnection] for the rest of this process's
/// lifetime — unlike [_nextCorrelationId], which is called fresh (a new
/// value) every time.
///
/// **Why this matters**: live testing found a non-empty/differential
/// [tCatalogSync] (see [_buildCatalogSyncBody]) reliably got no reply at
/// all from a real plotter, even after confirming every other structural
/// detail (framing, record format, even reusing the registration's own
/// correlation id within one connection — see
/// [_registrationCorrelationIdByTopic]) was correct. The remaining gap:
/// every connection this client ever made picked a brand-new random
/// registration value, never the same value twice — but the real
/// mechanism's whole point is a STABLE per-topic identity a plotter can
/// recognize across a client's connections. A registration correlation id
/// that's different every time can never look "already known" to the
/// plotter, no matter what a later differential sync's uuid list claims.
final Map<int, Uint8List> _stableTopicVersionStamp = {};

/// Where [_stableVersionStampFor] persists its per-topic values across
/// process restarts — **added 2026-08-14 to test the Update 45 hypothesis
/// that in-process-only stability isn't enough**: the real app's
/// equivalent value survives app restarts (stored in its own SQLite
/// database, see [_stableTopicVersionStamp]'s doc comment), but every
/// previous version of this field only survived within one running
/// process. A caller (e.g. `test_manual/` scripts, or eventually the UI
/// layer) may override this before the first [_registerTopic] call to
/// point at a real persistent location; defaults to a fixed path under
/// the system temp directory purely so this can be tested via repeated
/// `flutter test` process runs without needing UI-layer plumbing yet —
/// **not the final intended storage location**, which should be a proper
/// app-data path chosen by the caller (see `credential.dart`'s own doc
/// comment on leaving persistence to the caller, the same pattern this
/// should probably follow once the hypothesis is confirmed).
String debugStableVersionStampFilePath = '${Directory.systemTemp.path}/remote_helm_stable_version_stamps.json';

Map<int, Uint8List>? _stableVersionStampDiskCache;

Map<int, Uint8List> _loadStableVersionStampsFromDisk() {
  if (_stableVersionStampDiskCache != null) return _stableVersionStampDiskCache!;
  final file = File(debugStableVersionStampFilePath);
  final result = <int, Uint8List>{};
  if (file.existsSync()) {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final entry in json.entries) {
        result[int.parse(entry.key)] = Uint8List.fromList((entry.value as List).cast<int>());
      }
    } on Object {
      // Corrupt/unreadable file -- start fresh rather than crash; a new
      // value will be generated and overwrite it on next save.
    }
  }
  _stableVersionStampDiskCache = result;
  return result;
}

void _saveStableVersionStampsToDisk(Map<int, Uint8List> values) {
  _stableVersionStampDiskCache = values;
  final file = File(debugStableVersionStampFilePath);
  final json = {for (final entry in values.entries) entry.key.toString(): entry.value.toList()};
  try {
    file.writeAsStringSync(jsonEncode(json));
  } on Object {
    // Best-effort -- a failure to persist just means the next process
    // run picks a fresh value, same as before this existed.
  }
}

/// Clears the in-memory caches [_stableTopicVersionStamp]/
/// [_stableVersionStampDiskCache] without touching disk -- **for test
/// isolation only**. Without this, once any test in a `flutter test`
/// process populates these process-wide caches, every later test in the
/// same run silently reuses those values regardless of
/// [debugStableVersionStampFilePath] being changed, since the in-memory
/// maps are separate from (and take priority over) the file.
void debugResetStableVersionStampCache() {
  _stableTopicVersionStamp.clear();
  _stableVersionStampDiskCache = null;
}

/// Returns [topic]'s stable version stamp (see
/// [_stableTopicVersionStamp]'s doc comment), generating and caching one
/// via [_nextCorrelationId] the first time it's needed. **Persisted to
/// disk since 2026-08-14** (see [debugStableVersionStampFilePath]) so the
/// value survives across separate process runs, not just within one —
/// loads any previously-saved values on first access, and immediately
/// saves whenever a new topic's value is generated.
Uint8List _stableVersionStampFor(int topic) {
  if (_stableTopicVersionStamp.isEmpty) {
    _stableTopicVersionStamp.addAll(_loadStableVersionStampsFromDisk());
  }
  final existing = _stableTopicVersionStamp[topic];
  if (existing != null) return existing;
  final fresh = _nextCorrelationId();
  _stableTopicVersionStamp[topic] = fresh;
  _saveStableVersionStampsToDisk(_stableTopicVersionStamp);
  return fresh;
}

/// A version-stamp-shaped 8-byte value — see the doc comment above
/// [_clientUnitId] for how this was reverse-engineered. `seq` starts at
/// `0xfe` and increments by 1 per call, matching the real packing logic.
/// `sub`'s low 8 bits are a fresh random byte per call, matching what
/// actually gets packed on the wire; bits `[8:12)` (the
/// product-number nibble) are left `0`, since this isn't a real Garmin
/// product and no real value is known.
Uint8List _nextCorrelationId() {
  final seq = _syncVerStampSeq;
  _syncVerStampSeq = seq >= 0xfffffeff ? 0xff : seq + 1;
  final randByte = Random().nextInt(0x100);
  final sub = (randByte & 0xFF) | ((_clientUnitId & 0xFFFFF) << 12);
  final value = (BigInt.from(seq) << 32) | BigInt.from(sub);
  final out = Uint8List(8);
  ByteData.view(out.buffer).setUint64(0, value.toInt(), Endian.little);
  return out;
}

/// A short-lived connection to [routeCatalogPort], handling the outer
/// `MSG*` framing and inner `[topicId][msgType]` dispatch. One instance
/// per catalog-browsing session; call [close] when done.
class RouteCatalogConnection {
  final Socket _socket;
  final _rxBuf = BytesBuilder(copy: false);
  final StreamController<_InnerMessage> _messages = StreamController.broadcast();
  late final StreamSubscription<Uint8List> _sub;
  Timer? _keepaliveTimer;
  StreamSubscription<_InnerMessage>? _appMsgReplySub;

  /// The most recent `remote_ver` [_syncCatalog] got back for each topic
  /// on this connection — see [_syncCatalog]'s doc comment for what this
  /// is and why every [tGetObject] (single or batch) needs to echo it
  /// back rather than send a freely-chosen value. Populated by
  /// [_fetchCatalog]/[fetchCatalog]; read by [fetchObject] so a caller
  /// doesn't need to separately track and pass this through by hand for
  /// the single-object path the way [fetchObjects] requires of batch
  /// callers.
  final Map<int, Uint8List> _remoteVerByTopic = {};

  /// Topics [deleteEntry] has already run its merge-completion batch
  /// download for on this connection — see [deleteEntry]'s doc comment on
  /// why that download (not just a plain [tCatalogSync]) is needed before
  /// a delete is accepted, and why it only needs to happen once per
  /// topic per connection, not before every single delete: the download
  /// primes server-side merge/digest state for the *topic*, not for the
  /// specific delete about to be sent, so a second delete on the same
  /// topic/connection shortly after a first one doesn't need to repeat it.
  final Set<int> _mergePrimedTopics = {};

  /// In-flight "make sure [topic] has a `remote_ver`" future, if any —
  /// see [fetchObject]'s doc comment. Prevents concurrent [fetchObject]
  /// calls for the same topic (the exact pattern a catalog-browsing UI
  /// that lazily fetches each visible row's name produces) from each
  /// independently seeing [_remoteVerByTopic] still empty and racing to
  /// send their own redundant [tCatalogSync] on the same connection —
  /// confirmed live 2026-08-07 that this happened and coincided with the
  /// real plotter's "User data sharing is disabled" lockout.
  final Map<int, Future<void>> _syncInFlightByTopic = {};

  /// Tail of the per-topic [fetchObject] request queue — see
  /// [_enqueueGetObject]'s doc comment for why this exists. `null` means no
  /// [fetchObject] call is currently queued/in-flight for that topic.
  final Map<int, Future<void>> _getObjectQueueByTopic = {};

  /// Catalog changes the plotter pushed to this connection unprompted —
  /// see [pushes]' own doc comment.
  final StreamController<CatalogPush> _pushes = StreamController.broadcast();

  /// **Reverse-engineered 2026-08-13** from a real capture (`0b32f738`) of
  /// the official app with a `RouteCatalogConnection`-equivalent
  /// connection already open while a route was drawn directly on the
  /// plotter's own screen (not through any app at all): the plotter sent
  /// a fresh `msgType=0x2` message on `topicRoutes` — the exact same wire
  /// shape [addOrUpdateWaypoint]/[addOrUpdateRoute] send, just in the
  /// opposite direction — **on its own initiative, with no request from
  /// this connection at all**, once for every incremental change (each
  /// new point added, then again for the final rename): six messages
  /// total for one route, all sharing one uuid with cleanly chained
  /// `prevRemoteVer`/`newRemoteVer` pairs, exactly like a client's own
  /// sequential writes would.
  ///
  /// **This is the real mechanism behind how the official app stays in
  /// sync without ever re-querying the plotter** — see this file's top
  /// doc comment and the memory system's investigation notes for the
  /// full trail: multiple real captures independently confirmed the app
  /// never sends a second [tCatalogSync] on a topic after its first one
  /// per connection, no matter how long it stays open or how many
  /// changes happen (its own writes AND changes made directly on the
  /// plotter, outside the app entirely, both showed up this way). A
  /// second sync attempted by this client to "catch up" after a write —
  /// even on a brand-new connection — was found live to be unreliable at
  /// this catalog's size (see `deleteEntry`'s connection-reuse notes and
  /// the memory system's `plotter-timeout-lockout` history for the
  /// pattern). Listening here instead of re-syncing is not just closer to
  /// the real app's behavior; it's the only approach confirmed not to
  /// risk that failure mode.
  ///
  /// Fires one [CatalogPushUpdate] (full object, from the same gzip+JSON
  /// shape [fetchObject]'s reply uses) per incoming add/update, or one
  /// [CatalogPushDelete] (uuid only) per incoming delete — distinguished
  /// by whether the message has a gzip payload at all, the same way
  /// [deleteEntry]'s own wire format lacks one. Never closes on its own;
  /// closes when this connection does ([close]).
  Stream<CatalogPush> get pushes => _pushes.stream;

  RouteCatalogConnection._(this._socket) {
    _sub = _socket.listen(
      (chunk) {
        if (debugTrace) {
          // ignore: avoid_print
          print('DEBUG recv ${chunk.length} bytes: ${chunk.take(60).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
        }
        _rxBuf.add(chunk);
        final buf = _rxBuf.toBytes();
        final result = _parseMsgFrames(buf);
        _rxBuf.clear();
        _rxBuf.add(buf.sublist(result.consumed));
        for (final m in result.messages) {
          if (debugTrace) {
            // ignore: avoid_print
            print('DEBUG parsed msg topic=0x${m.topicId.toRadixString(16)} type=0x${m.msgType.toRadixString(16)} len=${m.rest.length}');
          }
          _messages.add(m);
          // Every message on [_messages] is something the PLOTTER sent —
          // this client's own sends never loop back through this stream —
          // so any `tDeleteEntry`-shaped (msgType 0x02) message here is
          // necessarily plotter-initiated, never an echo of this client's
          // own addOrUpdateWaypoint/addOrUpdateRoute/deleteEntry call.
          if (m.msgType == tDeleteEntry) {
            _handleIncomingPush(m);
          }
        }
      },
      onError: (Object e) {
        if (debugTrace) {
          // ignore: avoid_print
          print('DEBUG socket error: $e');
        }
        _messages.addError(e);
      },
      onDone: () {
        if (debugTrace) {
          // ignore: avoid_print
          print('DEBUG socket closed (onDone)');
        }
        _messages.close();
      },
      cancelOnError: true,
    );
  }

  /// Debug/investigation flag: when true, [RouteCatalogConnection] prints
  /// every raw send/receive to stdout. Off by default; only meant for
  /// `bin/helm_cli.dart catalog-debug` while chasing the still-unconfirmed
  /// [fetchCatalog] N=0 header shape (see this file's top doc comment).
  static bool debugTrace = false;

  /// Debug/investigation flag: when false, [_fetchCatalog] skips syncing
  /// every *other* registered topic before [topic] itself (see
  /// [_fetchCatalog]'s doc comment for why it was originally added).
  ///
  /// **Off by default since 2026-08-06.** Live testing that day found
  /// syncing `0x4` — not just slow, but never getting a reply at all,
  /// even with a 60s timeout — while skipping it entirely let
  /// [fetchCatalog] and the full batch-download cycle for
  /// [topicWaypoints] succeed immediately and reliably, repeatedly. This
  /// contradicts the real capture (where the app does sync `0x4`), but
  /// live behavior against the real plotter is the deciding factor here:
  /// whatever made `0x4`'s sync necessary in the capture, it's actively
  /// harmful against this plotter as of this testing. Kept as a flag
  /// (rather than deleting the other-topics code entirely) in case a
  /// future plotter/firmware needs it back — flip to `true` to restore
  /// the original real-capture-matching behavior.
  static bool debugSyncOtherTopics = false;

  static Future<RouteCatalogConnection> connect(
    String host, {
    int port = routeCatalogPort,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return RouteCatalogConnection._(socket);
  }

  /// Sends one inner message. [lengthFieldBytes] is 1 for [tGetObject] and 2
  /// for [tCatalogSync] — confirmed different widths in the capture (a
  /// [tGetObject] request's byte right after [msgType] was the exact
  /// remaining-byte-count as a single `u8`, while [tCatalogSync]/its reply
  /// use a `u16` there — not unified into one convention because there's no
  /// evidence it's actually the same field reinterpreted, just a
  /// coincidentally-similar position). [rest] must start with the 8-byte
  /// correlation id (every reply is matched back to it).
  /// [lengthOverride] lets a caller write a value into the length field
  /// other than the literal `rest.length` — needed for [tCatalogSync],
  /// whose length-shaped field isn't actually a byte count of what follows
  /// (see [fetchCatalog]'s doc comment).
  void _send(int topicId, int msgType, int lengthFieldBytes, List<int> rest, {int? lengthOverride}) {
    final inner = Uint8List(6 + lengthFieldBytes + rest.length);
    final bd = ByteData.view(inner.buffer);
    bd.setUint32(0, topicId, Endian.little);
    bd.setUint16(4, msgType, Endian.little);
    final lengthValue = lengthOverride ?? rest.length;
    if (lengthFieldBytes == 1) {
      inner[6] = lengthValue;
    } else if (lengthFieldBytes == 2) {
      bd.setUint16(6, lengthValue, Endian.little);
    }
    // lengthFieldBytes == 0: no length field at all — used for the plain
    // keepalive frame (msgType 0x07), which the capture showed as just
    // [topicId][msgType], nothing else.
    inner.setRange(6 + lengthFieldBytes, 6 + lengthFieldBytes + rest.length, rest);
    if (debugTrace) {
      // ignore: avoid_print
      print('DEBUG send topic=0x${topicId.toRadixString(16)} type=0x${msgType.toRadixString(16)} len=${inner.length} bytes=${inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    }
    try {
      _socket.add(_buildMsgFrame(inner));
    } on SocketException {
      // The connection may already be closed/destroyed by the time a
      // background keepalive (see [_keepaliveTimer]) fires — that's a
      // normal race, not something callers need to see, since [_send]
      // itself is fire-and-forget and any caller actually waiting on a
      // reply will already get a proper [RouteCatalogException] from
      // [_awaitReply] once the socket's `onDone`/error closes [_messages].
    }
  }

  /// Waits for a [tGetObjectReply]/[tGetObjectError] reply specifically,
  /// whose correlation id sits right after their own **LEB128** length
  /// prefix rather than at a fixed byte offset.
  ///
  /// A fixed `correlationIdOffset` happened to look correct for every
  /// [tGetObjectReply] capture examined at first only because that prefix
  /// was 2 bytes in each of them (any decompressed object over ~127
  /// bytes needs a 2-byte LEB128 length, and every captured route/
  /// waypoint reply was that big) — not because the offset is actually
  /// fixed. A small enough object (or the batch case's overall reply
  /// size falling under the same boundary) uses a 1-byte prefix instead
  /// and would silently fail to match. Confirmed via the LEB128 analysis
  /// that resolved the batch [tGetObject] request format (see
  /// [fetchObjects]'s doc comment) — the request side has the identical
  /// prefix, so the reply mirrors it.
  ///
  /// **[tGetObjectError] has no correlation id of its own** — confirmed
  /// live 2026-08-06: a real error reply's body was the fixed
  /// `08 00 00 00 00 00 00 00 00` (an `08` LEB128 length byte followed by
  /// 8 zero bytes), exactly like [tRegisterTopicReply]'s own documented
  /// fixed body, regardless of what correlation id the request actually
  /// used. Matching it against [correlationId] like a real
  /// [tGetObjectReply] silently never matched, which made a real error
  /// reply look like "no reply from the plotter" after the full timeout
  /// instead of surfacing immediately — [tGetObjectError] is now matched
  /// on topic alone, the same way [_registerTopic] already treats
  /// [tRegisterTopicReply].
  Future<_InnerMessage> _awaitGetObjectReply(int topicId, Uint8List correlationId, Duration timeout) async {
    try {
      return await _messages.stream
          .firstWhere((m) {
            if (m.topicId != topicId) return false;
            if (m.msgType == tGetObjectError) return true;
            if (m.msgType != tGetObjectReply) return false;
            final (value: _, consumed: prefixLen) = _decodeLeb128(m.rest, 0);
            if (prefixLen < 0 || m.rest.length < prefixLen + 8) return false;
            return _bytesEqual(Uint8List.sublistView(m.rest, prefixLen, prefixLen + 8), correlationId);
          })
          .timeout(timeout, onTimeout: () => throw const RouteCatalogException('no reply from the plotter'));
    } on StateError {
      throw const RouteCatalogException('connection to the plotter closed before a reply arrived');
    }
  }

  /// Waits for a [tCatalogSyncReply] specifically, whose correlation id
  /// sits at `leb128PrefixLength + 1` — one byte past its own **LEB128**
  /// length prefix, not at a fixed byte offset.
  ///
  /// **Bug found and fixed 2026-08-06**: an earlier version of this file
  /// used a fixed offset of 3, which happened to be correct for every
  /// [topicRoutes]/[topicWaypoints] reply seen (both large enough that
  /// their LEB128 prefix is 2 bytes: `2 + 1 = 3`), but broke for `0x4`'s
  /// own, much smaller [tCatalogSyncReply] (a 1-byte LEB128 prefix:
  /// `1 + 1 = 2`, not 3) — the exact same class of bug already fixed for
  /// [tGetObjectReply] in [_awaitGetObjectReply], just not caught here
  /// yet because [_fetchCatalog] never used to sync `0x4` at all.
  /// Confirmed live: with the fixed offset, [_fetchCatalog] silently
  /// never matched `0x4`'s real reply and hung until timeout, even though
  /// the reply had already arrived and was being correctly parsed as a
  /// [tCatalogSyncReply] — the old fixed-offset predicate just never
  /// returned true for it.
  Future<_InnerMessage> _awaitCatalogSyncReply(int topicId, Uint8List correlationId, Duration timeout) async {
    try {
      return await _messages.stream
          .firstWhere((m) {
            if (m.topicId != topicId || m.msgType != tCatalogSyncReply) return false;
            final (value: _, consumed: prefixLen) = _decodeLeb128(m.rest, 0);
            final corrOffset = prefixLen + 1;
            if (prefixLen < 0 || m.rest.length < corrOffset + 8) return false;
            return _bytesEqual(Uint8List.sublistView(m.rest, corrOffset, corrOffset + 8), correlationId);
          })
          .timeout(timeout, onTimeout: () => throw const RouteCatalogException('no reply from the plotter'));
    } on StateError {
      throw const RouteCatalogException('connection to the plotter closed before a reply arrived');
    }
  }

  final Set<int> _registeredTopics = {};

  /// The correlation id [_registerTopic] used for each topic's own
  /// [tRegisterTopic] on this connection — **required for a non-empty
  /// [tCatalogSync], found live 2026-08-13** after two independent real
  /// captures (`0d2f840f`, `9a59f873`) both showed a topic's non-empty
  /// [tCatalogSync] request reusing the EXACT SAME 8-byte correlation id
  /// as that same topic's own [tRegisterTopic] on the same connection —
  /// not a coincidence (confirmed across 3 topics × 2 captures = 6
  /// matching pairs, and [_nextCorrelationId]'s random component makes an
  /// accidental match astronomically unlikely). Before this was
  /// understood, [_syncCatalog]'s non-empty path picked its own fresh
  /// [_nextCorrelationId] value instead — live-confirmed to get NO reply
  /// at all, twice, while the N=0 path (which has never needed this reuse)
  /// kept working normally.
  final Map<int, Uint8List> _registrationCorrelationIdByTopic = {};
  bool _didPreamble = false;

  /// Every real capture examined registered these two topics — in this
  /// order, `0x29` then `0x04` — before ever touching [topicRoutes] or
  /// [topicWaypoints], on the very same connection. Live testing against a
  /// real plotter confirmed this isn't optional color: [topicRoutes]/
  /// [topicWaypoints] registration was rejected outright (`FIN`) when sent
  /// as the first thing on a fresh connection, and started working once
  /// this preamble was sent first. Neither topic's purpose is understood
  /// (`0x29` gets a distinct `tCatalogSync`-shaped reply of its own,
  /// `0x04`'s `sub` value of 10 doesn't match any other topic seen), so
  /// they're replayed as an opaque prerequisite rather than a stub to
  /// remove — see this file's top doc comment.
  static const List<(int topic, int sub)> _preambleTopics = [(0x29, 2), (0x04, 10)];

  /// Delay between the two `0x29` keepalives in [_ensurePreamble] — a real
  /// 5 seconds against a real plotter (matching the real app's own
  /// keepalive cadence, confirmed necessary by live testing), but
  /// overridable down to zero for tests, which don't need the wall-clock
  /// wait since a fake server doesn't care about timing.
  static Duration preambleKeepaliveDelay = const Duration(seconds: 5);

  /// Delay [deleteEntry] waits after its merge-completion `fetchObjects`
  /// round-trip and before actually sending the delete. **Defaults to
  /// [Duration.zero] as of 2026-08-10** — see [deleteEntry]'s doc comment:
  /// the original 30s value was a precaution added before the real
  /// remaining delete bug was found, and live-testing with it removed
  /// confirmed it was never actually needed. Kept as an overridable field
  /// (not deleted) in case a future plotter/firmware genuinely needs a
  /// settling delay.
  static Duration deletePostMergeDelay = Duration.zero;

  /// Cadence for the ongoing background keepalive ([_keepaliveTimer]) sent
  /// for the rest of the connection's lifetime after the preamble — same
  /// 5-second interval as [preambleKeepaliveDelay] on a real plotter, but
  /// **not** tied to that field's value (which tests override down to
  /// [Duration.zero] to skip the preamble's wall-clock wait — reusing it
  /// here would turn this into a busy-loop [Timer.periodic] in every test
  /// that calls [_ensurePreamble], repeatedly writing to a socket the test
  /// may have already closed).
  static const Duration _backgroundKeepaliveInterval = Duration(seconds: 5);

  Future<void> _ensurePreamble(Duration timeout) async {
    if (_didPreamble) return;
    final correlationId = _nextCorrelationId();
    _send(0x29, tRegisterTopic, 0, [
      _registerTopicTag,
      2 & 0xff, (2 >> 8) & 0xff,
      ...correlationId,
    ]);
    // Live testing found the plotter needs a few keepalives on 0x29 (the
    // real app sends one on it roughly every 5s) before it responds
    // properly to anything else on the connection — moving straight on to
    // registering 0x04/the target topic without this left the plotter
    // never replying to *any* registration at all, causing every later
    // step to hang until timeout. Not explained, just confirmed necessary.
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(preambleKeepaliveDelay);
      _send(0x29, 0x07, 0, const []);
    }

    for (final (topic, sub) in _preambleTopics.skip(1)) {
      final corr = _nextCorrelationId();
      _send(topic, tRegisterTopic, 0, [
        _registerTopicTag,
        sub & 0xff, (sub >> 8) & 0xff,
        ...corr,
      ]);
      // Mark as registered so [_registerTopic] (called by [fetchObject]/
      // [fetchObjects]/[_fetchCatalog]) doesn't re-send a second
      // registration for a topic the preamble already registered —
      // confirmed live 2026-08-06 to matter for `0x4`: without this,
      // [fetchObjects] re-registering `0x4` from scratch left the
      // connection waiting on a registration reply that never resolved
      // the same way, and the whole call hung until timeout.
      _registeredTopics.add(topic);
      // **Bug found live 2026-08-07 fetching [topicTrack] (== 0x4, this
      // topic's real identity — see its own doc comment).** This used to
      // be a fixed 50ms delay instead of actually waiting for `0x4`'s own
      // registration reply — fine for routes/waypoints, whose own
      // [_registerTopic] calls (in [_fetchCatalog]) never wait for a
      // reply either and were never observed needing one live. But `0x4`
      // specifically was repeatedly observed live going on to fail its
      // very next step (`tCatalogSync` in [_fetchCatalog], sent right
      // after this preamble loop finishes) with no reply at all — and a
      // `--trace` log of one such failure showed the `tCatalogSync` went
      // out *before* `0x4`'s own registration reply had arrived at all
      // (unlike every observed success, where it always had). `0x4`
      // apparently needs its registration genuinely acknowledged before
      // anything else on it will get a reply, unlike routes/waypoints —
      // so actually wait here instead of guessing a fixed delay is enough.
      try {
        await _messages.stream
            .firstWhere((m) => m.topicId == topic && (m.msgType == 0x0a || m.msgType == 0x09))
            .timeout(timeout, onTimeout: () => throw const RouteCatalogException('no reply from the plotter'));
      } on StateError {
        throw const RouteCatalogException('connection to the plotter closed before a reply arrived');
      }
    }
    _didPreamble = true;

    // Live testing (2026-08-06) found the plotter closes the connection on
    // its own after ~20-25s of no further activity, even with no
    // [fetchCatalog] request outstanding — the preamble above only sends
    // two `0x29` keepalives during its own ~10s window and then stops,
    // leaving nothing keeping a longer-running connection (e.g. one
    // waiting on [fetchCatalog]'s reply) alive. Keep sending the same
    // `0x29`/`0x07` keepalive on the same cadence for the rest of the
    // connection's lifetime, matching the real app's own observed
    // behavior (see [preambleKeepaliveDelay]'s doc comment) — this may
    // also explain an earlier live [fetchCatalog] test that got no
    // [tCatalogSyncReply] and a closed connection, independent of whether
    // the request payload itself was correct.
    _keepaliveTimer = Timer.periodic(_backgroundKeepaliveInterval, (_) {
      _send(0x29, 0x07, 0, const []);
    });
  }

  /// Registers this connection for [topic] (`tRegisterTopic`/`0x01`, which
  /// is the very same wire message as the plotter's internal dataset-init
  /// step — there's no separate init step to add). Only
  /// sent once per topic per connection.
  ///
  /// **Does not wait for a reply.** This changed after analyzing
  /// the server's dispatch behavior and cross-checking it against fresh
  /// real captures (`d5ee1386`/`581a91e3`/`9d8f5d91` — see this file's top
  /// doc comment): every real client send burst registers *every* topic
  /// it's about to use back-to-back with **no wait for `0x0a`/`0x09` in
  /// between**, then immediately sends [tCatalogSync] on top — the
  /// plotter's own registration replies were observed arriving only *after*
  /// the entire request burst, sometimes after the [tCatalogSyncReply]
  /// itself. The previous version of this function blocked on a reply
  /// before doing anything else, which doesn't match that timing at all
  /// and is the most likely explanation for [fetchCatalog]'s past silent
  /// hangs — not a wrong payload, but waiting for an event in an order the
  /// plotter never produces it in.
  void _registerTopic(int topic) {
    if (_registeredTopics.contains(topic)) return;
    // Stable per-topic value, not a fresh one every connection -- see
    // _stableTopicVersionStamp's doc comment for why (a real plotter's
    // digest/merge mechanism is hypothesized to need a value it can
    // recognize as "the same client" across connections, not a fresh
    // registration id every time).
    final correlationId = _stableVersionStampFor(topic);
    _registrationCorrelationIdByTopic[topic] = correlationId;
    final sub = _registerTopicSub[topic];
    if (sub == null) {
      throw RouteCatalogException('no known registration "sub" value for topic 0x${topic.toRadixString(16)}');
    }
    _send(topic, tRegisterTopic, 0, [
      _registerTopicTag,
      sub & 0xff, (sub >> 8) & 0xff,
      ...correlationId,
    ]);
    _registeredTopics.add(topic);
  }

  /// Registers every topic in [auxiliaryTopics] on this connection —
  /// **experimental, added 2026-08-09**. The real app always keeps a
  /// SECOND, separate [RouteCatalogConnection] open for the entire
  /// lifetime of a session (registering these topics and periodically
  /// exchanging still-not-fully-decoded feature-announcement traffic on
  /// them, per this file's top doc comment) running alongside its main
  /// route-catalog connection, including through an observed real delete.
  ///
  /// **Fixed 2026-08-09**: this used to call [_ensurePreamble] first, on
  /// the assumption every connection needs the same `0x29` keepalive
  /// handshake before doing anything else. A fresh capture's aux
  /// connection (`46708` in `355eb949`) showed that's wrong for THIS
  /// connection specifically: its very first frames register
  /// [auxiliaryTopics] directly — no `0x29` `tRegisterTopic`, no `0x05`,
  /// no preamble keepalives at all before that. Only the *main*
  /// route-catalog connection does the `0x29` preamble in that same
  /// capture. Calling [_ensurePreamble] here sent bytes this connection
  /// never legitimately sends, which is suspected of being why real
  /// live tests kept seeing this connection get closed/rejected by the
  /// plotter. No keepalive is started for this connection either (the
  /// background keepalive [_ensurePreamble] would otherwise start) —
  /// still an open question whether this connection needs its own
  /// periodic traffic to stay alive long-term; not yet observed how the
  /// real app keeps it going past the topics registration itself.
  Future<void> registerAuxiliaryTopics() async {
    for (final topic in auxiliaryTopics) {
      _registerTopic(topic);
    }
    _appMsgReplySub = _autoReplyToAppMsg();
  }

  /// Answers every unsolicited feature-announcement message (`msgType`
  /// 0x08) the plotter sends on this connection's registered [auxiliaryTopics] —
  /// **experimental, added 2026-08-09**. A fresh capture (`355eb949`)
  /// showed the plotter announces each registered feature (seen as
  /// human-readable names inside the message payload — "OneChart",
  /// "QuickDraw-Upload", "DepthLogs-Download") with its own `0x08`
  /// message on that feature's topic, and the real app answers each one
  /// with its own `0x08` reply.
  ///
  /// Comparing 4 real replies byte-for-byte found only TWO bytes ever
  /// vary: an incrementing sequence number, and a per-topic "feature
  /// slot" byte (copied from the same position in the plotter's own
  /// announcement for that topic). Every other byte — including a 10-
  /// byte prefix this file's earlier draft wrongly tried to re-derive
  /// field-by-field from the (still not fully understood) inner
  /// message framing — is bit-for-bit constant across all 4 samples,
  /// so it's replayed verbatim here rather than reconstructed. The
  /// trailing 32 bytes are two 16-byte values: the PLOTTER's own
  /// announcement's last 16 bytes echoed back verbatim (confirmed by
  /// finding those exact bytes inside the announcement itself — a
  /// correlation id), then a second fixed 16-byte value that, unlike the
  /// first, never appears in anything RECEIVED from the plotter in this
  /// capture, only in what the client sends — plausibly a device/app-
  /// instance identity this client has no real value for (same
  /// situation as [_clientUnitId]). Not yet confirmed this reply is
  /// required for anything — being tried as the last unreplicated piece
  /// of the aux connection's real traffic pattern.
  StreamSubscription<_InnerMessage> _autoReplyToAppMsg() {
    var seq = 1;
    return _messages.stream.listen((m) {
      if (m.msgType != 0x08 || !auxiliaryTopics.contains(m.topicId)) return;
      if (m.rest.length < 16) return;
      final correlationId = m.rest.sublist(m.rest.length - 16);
      // Feature-slot byte: found at rest.length-35 in every real
      // announcement (verified against all 3 available: OneChart=0x00,
      // QuickDraw-Upload=0x01, DepthLogs-Download=0x06, each matching
      // what the real client echoed back in its own reply's byte 15).
      final featureSlot = m.rest.length >= 35 ? m.rest[m.rest.length - 35] : 0;
      final body = <int>[
        0x31, 0x0e, 0x03, 0x01, 0x00, 0x0f, 0x07, 0x06, 0x01, seq & 0xff,
        0x00, 0x00, 0x00,
        0x11, featureSlot,
        0x10, ...correlationId,
        0x10, ..._appMsgDeviceIdentity,
      ];
      _send(m.topicId, 0x08, 0, body);
      seq++;
    });
  }

  /// A fixed 16-byte value this client sends back as its own identity in
  /// [autoReplyToAppMsg] replies — see that method's doc comment. Not a
  /// real device identity (this client has none); kept as a plausible,
  /// process-stable placeholder shaped like the real captured value's
  /// VMware-OUI-prefixed UUID (`00:50:56`, a virtualized-NIC OUI —
  /// plausibly just whatever MAC-derived UUID the real phone's Android
  /// runtime happened to report, not something meaningful to replicate
  /// exactly).
  static const List<int> _appMsgDeviceIdentity = [
    0x6a, 0x80, 0xc5, 0x70, 0x97, 0x0a, 0x11, 0xe6,
    0xb5, 0x84, 0x00, 0x50, 0x56, 0xc0, 0x00, 0x08,
  ];

  /// While a [tCatalogSync] digest is being processed, the plotter can send
  /// its **own** [tGetObject] request back on the same topic — the "merge"
  /// in digest-based merge is two-way. It appears to block the plotter's own
  /// [tCatalogSyncReply] until answered. Its body comes in **two different
  /// shapes**, found live 2026-08-14 via a from-scratch,
  /// direction-and-reassembly-correct re-scan of every pcap on file (not
  /// just the two captures examined when the original single-shape
  /// assumption was written):
  ///
  /// 1. **Generic/fixed-tail** (`0c <8-byte version> 03 01 01 00`, no uuid
  ///    marker) — the shape this function's original doc comment described.
  ///    Echoing `m.rest` back as [tGetObjectReply] is **confirmed correct
  ///    for this shape specifically**: it's what every previously-live-
  ///    confirmed N=0 sync (Update 22 onward) actually exercised, and a
  ///    2026-08-14 live test replacing the echo with [tGetObjectError] for
  ///    this shape broke a plain N=0 sync that used to work (the plotter
  ///    responded with what looks like a topic re-registration instead of
  ///    continuing) — reverted back to echoing for this case.
  /// 2. **Uuid-carrying** (`0c <8-byte version> <len> 01 01 01 07 11 10
  ///    <16-byte uuid>`) — found in two independent pure "sync only, no
  ///    create" captures (`342c2f35`, `34d945fa`), asking about one
  ///    specific object. The real app's [tGetObjectReply] here carries
  ///    **real, different, gzip-compressed object content** — not an echo —
  ///    because the real app has that object cached locally. This client is
  ///    a pure catalog/content **downloader** — [DownloadedObject] only ever
  ///    stores decoded [RoutePoint]s, never the raw wire bytes needed to
  ///    re-serialize an object — so there is structurally no real content
  ///    this function could ever send back for a uuid-carrying request.
  ///    [tGetObjectError] (`08 00 00 00 00 00 00 00 00`, the same fixed body
  ///    a real plotter sends this client when rejecting one of *our*
  ///    [tGetObject] requests — see that constant's doc comment) is used for
  ///    this shape as the most defensible reply given the wire format, but
  ///    **still unverified**: no capture on file shows the real app ever
  ///    sending it (the real app always has the content, so it never needed
  ///    to reject), and this shape hasn't had a live test of its own yet
  ///    (the 2026-08-14 live test above only exercised the generic shape).
  ///
  /// The two shapes are told apart by searching for the `07 11 10` uuid
  /// marker in the request body — present only in shape 2.
  ///
  /// Returns a subscription the caller must cancel once done waiting for the
  /// digest reply.
  StreamSubscription<_InnerMessage> _autoReplyToServerGetObject(int topic) {
    return _messages.stream.listen((m) {
      if (m.topicId == topic && m.msgType == tGetObject) {
        final hasUuidMarker = _findBytes(m.rest, const [0x07, 0x11, 0x10]) >= 0;
        if (hasUuidMarker) {
          _send(topic, tGetObjectError, 0, const [0x08, 0, 0, 0, 0, 0, 0, 0, 0]);
        } else {
          _send(topic, tGetObjectReply, 0, m.rest);
        }
      }
    });
  }

  /// Requests the full object catalog for [topic] ([topicRoutes] or
  /// [topicWaypoints]), sending an empty "already known" list so the
  /// plotter's reply contains everything.
  ///
  /// **Confirmed correct, live, against a real plotter (2026-08-06)** —
  /// see the top doc comment's "N=0 finally confirmed" section for the
  /// full trail. Derived from a real pcap of a genuine first-ever sync
  /// (the app fully reset, then left to sync once against a plotter it
  /// had never seen before): that capture's [tCatalogSync] request (all
  /// three registered topics, `0x4`/`0x1c`/`0x1d`, sent byte-identical
  /// bodies except for the correlation id) is **structurally different
  /// from every non-empty capture examined before**: only **15 bytes**
  /// total, using a **1-byte** length field (not the 2-byte field a
  /// non-empty [tCatalogSync] uses) followed by an 8-byte correlation id
  /// and a **fixed 6-byte tail** (`05 02 01 00 09 00`). [fetchCatalog]
  /// replays this exact byte pattern, and a live test the same day
  /// returned **103 real catalog entries** with no error and the
  /// plotter's "user data sharing" setting staying enabled — the first
  /// N=0 request in this investigation's history confirmed to actually
  /// work.
  ///
  /// **Default [timeout] raised from 10s to 30s (2026-08-06)** — a real
  /// capture showed the plotter itself takes up to ~10s just to send the
  /// first [tRegisterTopicReply] after the registration/sync burst (see
  /// [_syncCatalog]'s doc comment), and a live test against a freshly
  /// reset plotter needed 30-60s total for a full sync-then-batch-
  /// download cycle to complete — 10s cut that off mid-flight and looked
  /// exactly like "no reply from the plotter" (a real, structural
  /// problem this file spent a long time chasing) even though the
  /// request/reply mechanism itself was already correct.
  /// [knownEntries] — see [_buildCatalogSyncBody]'s doc comment — makes
  /// this a non-empty/differential sync instead of the default N=0 one.
  Future<List<CatalogEntry>> fetchCatalog(
    int topic, {
    Duration timeout = const Duration(seconds: 30),
    List<CatalogEntry>? knownEntries,
  }) async {
    final result = await _fetchCatalog(topic, timeout: timeout, knownEntries: knownEntries);
    return result.entries;
  }

  /// Like [fetchCatalog], but returns every raw entry the sync reply
  /// listed, without the `validCount` trim [fetchCatalog] applies — see
  /// [_syncCatalog]'s doc comment for the known bug where that trim can
  /// drop a real, just-created entry sitting past the trim point.
  /// [deleteEntry] already relies on this same untrimmed list internally
  /// for its own uuid lookup; exposed here so external verification (e.g.
  /// [addOrUpdateWaypoint] callers checking whether a create landed) can
  /// do the same instead of trusting the trimmed view.
  Future<List<CatalogEntry>> fetchCatalogUnfiltered(int topic, {Duration timeout = const Duration(seconds: 30)}) async {
    final result = await _fetchCatalog(topic, timeout: timeout);
    return result.allEntries;
  }

  /// Shared implementation for [fetchCatalog] and [fetchCatalogAndObjects]
  /// — see [fetchCatalog]'s own doc comment for what this does and how
  /// the request/reply format was derived. Split out so
  /// [fetchCatalogAndObjects] can send its batch [tGetObject] immediately
  /// after this returns, inside the same unbroken `async` call chain, with
  /// no `await` gap back out to a caller in between (see
  /// [fetchCatalogAndObjects]'s own doc comment for why that gap mattered).
  /// Also returns [topic]'s own `remote_ver` (see [_syncCatalog]'s doc
  /// comment) so [fetchCatalogAndObjects] can pass it to [fetchObjects]
  /// without a second round trip.
  Future<({List<CatalogEntry> entries, Uint8List remoteVer, List<CatalogEntry> allEntries})> _fetchCatalog(
    int topic, {
    required Duration timeout,
    List<CatalogEntry>? knownEntries,
  }) async {
    await _ensurePreamble(timeout);
    // Every real capture registers *both* topicWaypoints and topicRoutes on
    // the same connection before syncing either one — even a session that
    // only ends up calling tCatalogSync on one of them still registers the
    // other first (confirmed in `d5ee1386`/`581a91e3`/`9d8f5d91`). Replayed
    // here since skipping it is untested and the preamble topics already
    // showed the plotter cares about this kind of exact sequencing.
    _registerTopic(topicWaypoints);
    _registerTopic(topicRoutes);
    // The fixed 6-byte tail from the real N=0 capture, byte-for-byte —
    // not decoded field-by-field (its own structure wasn't fully reverse
    // engineered), but confirmed constant across all three topics in a
    // real, successful capture, so replayed verbatim.
    const n0Tail = _catalogSyncN0Tail;

    // Every real capture sends tCatalogSync for ALL THREE registered
    // topics (0x4, topicWaypoints, topicRoutes) together before waiting on
    // any of their replies, and this used to always replay that. **As of
    // 2026-08-06 this is OFF by default** (see [debugSyncOtherTopics]):
    // live testing that day, after the real root cause (remote_ver — see
    // [_syncCatalog]'s doc comment) was already fixed, found `0x4`'s own
    // tCatalogSync reliably got NO reply at all (even with a 60s timeout)
    // on a freshly reset/restarted real plotter, while skipping it
    // entirely let [topic]'s own sync-then-batch-download cycle succeed
    // immediately and repeatably. The other, real, independently-
    // confirmed fix needed at the same time was longer default timeouts
    // (see [fetchCatalog]'s doc comment) — a real capture showed the
    // plotter itself can take ~10s just to send the first reply in a
    // sync burst, and this file's earlier default timeouts (10-20s) cut
    // that off mid-flight in a way that looked exactly like "no reply
    // from the plotter", muddying the diagnosis for a while. Both
    // needed fixing before a live batch download actually succeeded
    // end-to-end.
    final otherTopics = debugSyncOtherTopics
        ? [
            0x4,
            if (topic != topicWaypoints) topicWaypoints,
            if (topic != topicRoutes) topicRoutes,
          ]
        : const <int>[];
    for (final other in otherTopics) {
      final otherSync = await _syncCatalog(other, n0Tail, timeout: timeout);
      if (otherSync.entries.isNotEmpty) {
        try {
          // _sendBatchGetObject, not fetchObjects: this result is
          // discarded (see doc comment above), so there's no reason to
          // pay for parsing it — confirmed live 2026-08-06 that doing so
          // anyway made this step alone take well over a minute for
          // `0x4`'s real ~80KB reply.
          await _sendBatchGetObject(
            other,
            otherSync.entries.map((e) => e.uuid).toList(),
            remoteVer: otherSync.remoteVer,
            timeout: timeout,
          );
        } on RouteCatalogException {
          // Best-effort — this function's caller never asked for `other`'s
          // objects, so a failure here shouldn't fail the caller's own
          // request. Still attempted (rather than skipped) since sending
          // the batch tGetObject at all, not just getting a reply, is the
          // part hypothesized to matter.
        }
      }
    }

    return _syncCatalog(topic, n0Tail, timeout: timeout, knownEntries: knownEntries);
  }

  /// Sends [tCatalogSync] (the N=0 empty-list request — see
  /// [fetchCatalog]'s doc comment for the byte format [tail] encodes) for
  /// [topic] alone and returns its parsed [CatalogEntry] list plus the
  /// server-assigned `remote_ver` a following batch [tGetObject] on this
  /// topic must use as its own correlation-id-shaped field. Split out of
  /// [_fetchCatalog] so the same tCatalogSync-then-parse logic can run
  /// for every registered topic (see [_fetchCatalog]'s doc comment on
  /// why), not just the one a caller asked for.
  ///
  /// **`remote_ver`, not a free-form correlation id — found 2026-08-06.**
  /// Every batch [tGetObject] this file sent (including one using `0x4`'s
  /// own single real uuid, from `0x4`'s own real [tCatalogSyncReply], an
  /// as-exact-as-possible replay of the real capture) was rejected with
  /// [tGetObjectError] until this was understood. Comparing several real
  /// captures side by side showed the request's 8-byte "correlation id"
  /// field only ever gets accepted when it matches a specific value the
  /// plotter itself supplied earlier in the exchange — any other value
  /// reliably gets the rejecting [tGetObjectError] branch instead. That
  /// 8-byte field isn't a value the client is free to choose; it's a
  /// **version the server told the client to echo back**, `remote_ver`.
  /// [tCatalogSyncReply]'s own
  /// body has (at [_awaitCatalogSyncReply]'s `corrOffset`, i.e. right
  /// after the echoed request correlation id) two more consecutive 8-byte
  /// fields; the **second** of those two is the exact bytes a real batch
  /// [tGetObject] on that topic used as its own "correlation id" —
  /// confirmed byte-for-byte for both `0x4` and [topicWaypoints] in the
  /// real capture. [fetchObjects] now requires callers to pass this value
  /// in explicitly rather than picking its own via [_nextCorrelationId].
  /// [knownEntries], if non-null and non-empty, sends the non-empty
  /// differential-sync request format ([_buildCatalogSyncBody]) instead of
  /// the N=0 empty-list request [tail] encodes — see
  /// [_buildCatalogSyncBody]'s own doc comment for the wire format and how
  /// it was derived. `null`/empty keeps today's N=0 behavior exactly, so a
  /// first-ever sync on a connection/topic (nothing known yet) is
  /// unaffected by this parameter's existence.
  ///
  /// **The non-empty path's correlation id is [topic]'s own
  /// [_registerTopic] correlation id, NOT a fresh one — found live
  /// 2026-08-13.** See [_registrationCorrelationIdByTopic]'s doc comment:
  /// two independent real captures both show a topic's non-empty
  /// [tCatalogSync] reusing that same topic's [tRegisterTopic] correlation
  /// id byte-for-byte. A fresh [_nextCorrelationId] value here (this
  /// method's old behavior, still used for the N=0 path since that's never
  /// needed the reuse) got no reply at all, twice, before this fix.
  Future<({List<CatalogEntry> entries, Uint8List remoteVer, List<CatalogEntry> allEntries})> _syncCatalog(
    int topic,
    List<int> tail, {
    required Duration timeout,
    List<CatalogEntry>? knownEntries,
  }) async {
    final isDifferential = knownEntries != null && knownEntries.isNotEmpty;
    final correlationId = isDifferential && _registrationCorrelationIdByTopic.containsKey(topic)
        ? _registrationCorrelationIdByTopic[topic]!
        : _nextCorrelationId();
    final getObjectSub = _autoReplyToServerGetObject(topic);
    final _InnerMessage reply;
    try {
      if (isDifferential) {
        // [_buildCatalogSyncBody] already includes its own outer LEB128
        // length prefix and the correlation id internally, so this is sent
        // with lengthFieldBytes=0 (no separate length field) rather than
        // the fixed 1-byte field the N=0 path below uses.
        final body = _buildCatalogSyncBody(knownEntries, correlationId);
        _send(topic, tCatalogSync, 0, body);
      } else {
        final rest = <int>[...correlationId, ...tail];
        // lengthFieldBytes=1 here, not 2 — confirmed from the real N=0
        // capture, unlike every non-empty [tCatalogSync] this file has seen
        // (which all use a 2-byte length field carrying the `27*N+intercept`
        // value). [rest]'s own length (14 bytes: 8-byte correlation id + the
        // 6-byte tail) is written directly, matching the real capture's
        // `fieldA=14` exactly — no separate override needed.
        _send(topic, tCatalogSync, 1, rest);
      }
      reply = await _awaitCatalogSyncReply(topic, correlationId, timeout);
    } finally {
      await getObjectSub.cancel();
    }
    final allParsed = _parseCatalogEntries(reply.rest, topic);
    final (value: _, consumed: prefixLen) = _decodeLeb128(reply.rest, 0);
    final corrOffset = prefixLen + 1;
    final remoteVerOffset = corrOffset + 16;
    final remoteVer = reply.rest.length >= remoteVerOffset + 8
        ? Uint8List.sublistView(reply.rest, remoteVerOffset, remoteVerOffset + 8)
        : Uint8List(8); // shouldn't happen against a real plotter; zero is at least deterministic
    _remoteVerByTopic[topic] = remoteVer;

    // **Found live 2026-08-08**: the catalog can list more raw records than
    // are actually real, individually-fetchable objects — confirmed live
    // (user hand-counted exactly 75 routes on the plotter and in the app
    // UI) against a topic whose sync reply parsed 103 records. The extra
    // ~28 are structurally well-formed (unique uuids, no parse errors) but
    // aren't real objects: a single fetchObject for one of them, in
    // complete isolation, got no reply at all — the exact same symptom
    // that plagued every larger fetchObjects batch this session, because
    // any batch whose uuid list happened to include one of these entries
    // would hang. The real app already knows to skip them — its own batch
    // tGetObject requests only ever list the real ones (confirmed
    // byte-for-byte: a real capture's app requested exactly the first 75
    // routes' uuids, in catalog order, never touching the remaining 28).
    // This "real count" is a field in the sync reply itself, found by
    // reverse-diffing this exact header against the real capture: right
    // after remoteVer, there's a LEB128 byte-length field (of the
    // remaining records section), then `02 01 <leb128 realCount> 09
    // <leb128 extraCount>` — realCount + extraCount == the number of raw
    // records _parseCatalogEntries finds (75 + 28 == 103 in the capture
    // that resolved this). Falls back to keeping every parsed entry if
    // this field can't be found/decoded, so a plotter/capture where this
    // guess is wrong degrades to the old (occasionally-hanging) behavior
    // rather than silently dropping real entries.
    final validCount = _decodeValidEntryCount(reply.rest, remoteVerOffset);
    final parsed = (validCount != null && validCount <= allParsed.length) ? allParsed.sublist(0, validCount) : allParsed;
    if (debugTrace) {
      // ignore: avoid_print
      print(
        'DEBUG _syncCatalog topic=0x${topic.toRadixString(16)} reply.rest.length=${reply.rest.length} '
        'parsedEntries=${allParsed.length} validCount=$validCount usedEntries=${parsed.length} '
        'remoteVer=${remoteVer.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      );
    }
    // **Bug found live 2026-08-08**: `validCount` cuts the list off at the
    // first N entries (`sublist(0, validCount)`), on the assumption real
    // objects always sort before the non-fetchable "extra" ones in the
    // plotter's own reply. That assumption is wrong — a live test found a
    // just-created route sitting at the very END of a 111-entry raw list,
    // past a `validCount` of 70, and thus silently dropped from every
    // [fetchCatalog]/[deleteEntry] caller even though the entry is real
    // and the plotter accepted it. [allParsed] (the untrimmed list) is
    // returned alongside so callers that need to search for one specific
    // known uuid (like [deleteEntry]) can fall back to it instead of
    // trusting the trim — see [deleteEntry]'s own doc comment. The trim
    // itself is NOT fixed yet (the real rule distinguishing genuinely
    // non-fetchable entries from real ones isn't understood) — this only
    // works around its effect on lookups for one already-known uuid.
    return (entries: parsed, remoteVer: remoteVer, allEntries: allParsed);
  }

  /// Decodes the "real object count" field described in [_syncCatalog]'s
  /// doc comment, starting right after that topic's 8-byte `remote_ver`
  /// (at [remoteVerOffset] + 8 in [rest]). Returns `null` if [rest] is too
  /// short or doesn't match the expected `<leb128 len> 02 01 <leb128 n> ...`
  /// shape, so callers can fall back safely rather than trusting a
  /// misparse.
  int? _decodeValidEntryCount(Uint8List rest, int remoteVerOffset) {
    var offset = remoteVerOffset + 8;
    if (offset >= rest.length) return null;
    final (value: _, consumed: lenConsumed) = _decodeLeb128(rest, offset);
    if (lenConsumed < 0) return null;
    offset += lenConsumed;
    if (offset + 2 > rest.length || rest[offset] != 0x02 || rest[offset + 1] != 0x01) return null;
    offset += 2;
    final (value: count, consumed: countConsumed) = _decodeLeb128(rest, offset);
    if (countConsumed < 0) return null;
    return count;
  }

  /// Deletes [uuid] from [topic]'s catalog on the plotter.
  ///
  /// **✅ FULLY SOLVED AND LIVE-CONFIRMED 2026-08-09**, after roughly four
  /// calendar days of on-and-off reverse engineering across many sessions
  /// (started 2026-08-06/07). `deleteEntry(topicRoutes,
  /// '1f6e0eb6-2fc0-4721-b496-5f15c5089088')` was run against the real
  /// physical plotter (`172.16.6.0`) as a single, isolated request (no
  /// preceding probe on the same connection, to rule out the separate
  /// [[plotter-timeout-lockout]] confound — see that memory file, and the
  /// "Investigation history" section far below, for why that distinction
  /// mattered): the catalog entry count dropped from 68 to 67, and a fresh
  /// reconnect confirmed the target uuid was genuinely gone, not just
  /// missing from a stale cached view. This is the wire format and
  /// procedure that produced that result — treat everything above the
  /// "Investigation history" divider below as ground truth, not a
  /// hypothesis still being tested.
  ///
  /// ### Wire format (all offsets relative to the body right after
  /// `[4-byte topicId LE][2-byte msgType LE]`, i.e. [_send]'s `rest` with
  /// `lengthFieldBytes: 0`; `tDeleteEntry` == `0x0002`)
  /// ```
  /// byte[0]      "outer length" tag — a **self-referential unsigned
  ///              LEB128 vint** encoding the exact byte length of
  ///              everything from byte[1] to the end of the message,
  ///              INCLUDING this tag field's own encoded width. Solved via
  ///              [_solveSelfReferentialLeb128Length] (a small fixed-point
  ///              solver — see its own doc comment for the derivation and
  ///              why a naive "encode(restLength)" is off by one).
  ///              Verified against 4 distinct real (totalLen -> tagValue)
  ///              pairs from TWO independent physical devices/app
  ///              installs: 49->48, 50->49, 260->258, 805->803. This is
  ///              NOT a fixed `0x30`/`0x31` byte and NOT an `app_ver` field
  ///              — both were plausible-looking earlier theories (see
  ///              history below) that only survived as long as they did
  ///              because every early real capture happened to have a
  ///              small enough total length that the tag stayed a single,
  ///              low-value byte, masking that it was really a LEB128
  ///              vint of the message's own size.
  /// bytes[1:9]   8-byte previous `remote_ver` for this topic (LE
  ///              `(seq:u32 << 32) | sub:u32` bitfield — see
  ///              [_freshRemoteVerLikeValue]'s doc comment for the full
  ///              `sub` bit layout) — the real, server-synced value from
  ///              this topic's most recent [tCatalogSync] reply, fetched
  ///              via [_fetchCatalog] if not already cached on this
  ///              connection (or supplied directly via
  ///              [debugPrevRemoteVer] for testing).
  /// bytes[9:17]  8-byte NEW `remote_ver` this delete establishes, built by
  ///              [_freshRemoteVerLikeValue]: **`seq` is
  ///              `prevRemoteVer.seq + 1`**, exactly, confirmed across all
  ///              6 real captured deletes available (983->984, 921->922,
  ///              910->911, 868->869, 870->871, 869->870) — an earlier
  ///              theory ("differs by billions, not `+1`") was comparing
  ///              the two 8-byte values as single 64-bit integers, which
  ///              hides a `+1` on `seq` alone once you realize `seq` lives
  ///              in the *upper* 32 bits (a `+1` there moves the whole
  ///              64-bit value by roughly 2^32). `sub`'s low 20 bits are a
  ///              client/device "unit id" — reverse-engineered by studying
  ///              the plotter's own version-stamp packing logic:
  ///              `bits[0:8)` a fresh random byte, `bits[8:12)` a
  ///              product-number nibble
  ///              (empirically `0` in every real capture's OWN
  ///              client-generated value, but a real plotter-issued
  ///              `remote_ver` was independently observed carrying `13`
  ///              there instead — see the history section, "prodNum isn't
  ///              always 0" — so don't treat `0` as structurally
  ///              guaranteed, just as what this client currently emits),
  ///              `bits[12:32)` a real per-device hardware identity value
  ///              this client has no way to know a
  ///              priori. [_clientUnitId]/[debugClientUnitId] stands in for
  ///              it. **Isolation-tested and settled 2026-08-09, same day
  ///              as the trailer-tag fix below**: the first successful
  ///              live delete used `debugClientUnitId` set to a value
  ///              learned live from this same plotter's own sync replies
  ///              (`0x32d44`), which left it genuinely unclear whether that
  ///              specific value mattered or was cosmetic. A follow-up
  ///              delete (a different real route, same plotter, same code
  ///              otherwise) was run with `debugClientUnitId` left unset —
  ///              i.e. [_clientUnitIdFallback]'s ordinary random per-process
  ///              value — and **succeeded identically** (`GONE — delete
  ///              WORKED`, catalog count dropped by one again). **The
  ///              plotter does not validate `unitId` against any
  ///              previously-known device identity** — any 20-bit value
  ///              works, confirming this field is cosmetic for the delete
  ///              path specifically (the trailer-tag fix below is the
  ///              entire fix; no caller needs to set [debugClientUnitId]
  ///              for deletes to work). Kept as a random per-process value
  ///              by default; still available for callers that want a
  ///              stable identity across a session for other reasons.
  /// byte[17]     length byte (plain, non-LEB128 for the sizes seen so
  ///              far) = exact number of bytes remaining from byte[18]
  ///              onward — verified exactly against every real capture.
  /// bytes[18:23] `01 07 <A> 03 <B>`, built by [_rteDelMsgTagPrefix] —
  ///              **`A = 23 + lebLen`, `B = 21 + lebLen`**, where `lebLen`
  ///              is the exact byte length of the `del_vstamp` field's own
  ///              LEB128 encoding (0 if `del_vstamp` is omitted). This is
  ///              the message-serialization framework's own
  ///              cumulative-byte-position bookkeeping leaking into the
  ///              wire format, NOT a session-local counter (an earlier
  ///              theory, "B = A-2", only held across a too-small sample
  ///              that happened to have similarly-sized `del_vstamp`
  ///              fields — see history).
  /// bytes[23:27] `02 07 11 10` — `02` = present-optional-field count
  ///              (computed by [deleteEntry] as `1 + (del_vstamp present
  ///              ? 1 : 0)`, NOT hardcoded — a real message can have this
  ///              be `1` if the object had no known prior vstamp), `07 11
  ///              10` = the mandatory uuid field's own tag/size/length
  ///              prefix in the wire format's generic field-tagging
  ///              scheme: `07` = `(fieldId=0 << 3) | 7` (a field tag with
  ///              the "overflow, size given separately" pattern — see
  ///              [_rteDelMsgTagPrefix]'s doc comment further below),
  ///              `11` = 17 (the field's own overflow byte count),
  ///              `10` = 16 (the actual uuid byte length that follows).
  /// bytes[27:43] the 16-byte target UUID — solid, byte-verified against
  ///              every real capture and the successful live delete.
  /// bytes[43:]   the optional `del_vstamp` field. **Two independent bugs
  ///              here across the investigation, both now fixed:**
  ///              1. The *value*: NOT a checksum (every CRC16/CRC32
  ///                 variant was exhaustively ruled out — see history) and
  ///                 NOT the object's last-known vstamp verbatim. It's a
  ///                 **freshly incremented** vstamp, built by
  ///                 [_incrementVstamp]: the plotter's vstamp is a packed
  ///                 `(seq:u32 << 32) | sub:u32` bitfield — deleting
  ///                 increments `seq` by exactly 1
  ///                 and draws a **fresh random** `sub` (not reproducible,
  ///                 and not meant to be — the real app does the same).
  ///                 [_buildDeleteTrailer] takes the object's own
  ///                 pre-delete vstamp (from its catalog-entry trailer or
  ///                 `tGetObjectReply`'s `"vstamp"` field) and increments
  ///                 it this way before encoding.
  ///              2. The *tag byte* — **the actual remaining bug that kept
  ///                 every delete attempt failing silently even after (1)
  ///                 and every other field above was already byte-perfect
  ///                 against real captures.** `del_vstamp` is serialized
  ///                 as `<tag byte><LEB128 bytes>`, and the tag byte is
  ///                 **not a bare length** — it's a field tag in
  ///                 exactly the same `(fieldId << 3) | lebLen` shape as
  ///                 the uuid field's own `07` tag above. `del_vstamp` is
  ///                 `fieldId=1` (the field immediately after uuid in
  ///                 the delete message's field array), so the
  ///                 correct tag is `(1 << 3) | lebLen` — e.g. `0x0d` for
  ///                 a 5-byte LEB128 value, not `0x05`. Sending `fieldId=0`
  ///                 (the old, wrong code: `<int>[varint.length,
  ///                 ...varint]`) made this field collide with/be
  ///                 indistinguishable from the mandatory uuid field
  ///                 (itself `fieldId=0`) from the plotter's decoder's
  ///                 point of view — every previous "structurally
  ///                 byte-perfect, no exception, no lockout, but the route
  ///                 just stays" live failure is now understood to be this.
  ///              See [_buildDeleteTrailer]'s doc comment for the exact
  ///              fix and how it was found (a fresh byte-for-byte diff
  ///              against a real successful delete frame from a second,
  ///              independent device's capture).
  /// ```
  ///
  /// **No reply to await** (fire-and-forget, confirmed across every real
  /// capture and the live-confirmed successful send) and **no verification
  /// round-trip** — a real app-driven delete makes no further requests on
  /// the topic afterward. [deleteEntry] itself doesn't verify success
  /// either; callers that want to confirm should reconnect and
  /// [fetchCatalog] separately (as the live-confirming test did), since a
  /// verification query on the *same* connection right after the delete
  /// isn't something the real app ever does and hasn't been confirmed safe.
  ///
  /// ---
  /// ### Investigation history (kept for whoever next touches this
  /// protocol — the false starts are as instructive as the final answer)
  ///
  /// Reverse engineered from many real captures (PCAPdroid) of the real
  /// ActiveCaptain app deleting routes across several independent
  /// devices/app-installs, refined over roughly a dozen live-test rounds:
  ///
  /// **A previous pass at this (2026-08-07) wrongly concluded deletion was
  /// done via a full [tCatalogSync] digest-merge** (re-sending the whole
  /// catalog with the target entry missing) — that was based on a capture
  /// that happened to contain both a delete and an unrelated periodic
  /// full-resync close together, and was never actually checked
  /// byte-for-byte against a real delete request. It wasn't. **There is a
  /// dedicated delete message, [tDeleteEntry] (`0x02`), sent directly (not
  /// wrapped in [tCatalogSync]/[tGetObject]) and fire-and-forget.**
  ///
  /// **A second assumption, revised twice on 2026-08-08:** one capture (an
  /// app *restart*) showed no `tCatalogSync` at all on topicRoutes before
  /// the delete — just [_registerTopic], whose own `remote_ver`-shaped
  /// payload reappeared byte-for-byte as the delete's `prevRemoteVer`
  /// moments later. That looked like proof the sync step was skippable.
  /// **A full-app-reset capture directly contradicted that**: from a truly
  /// cold start, topicRoutes DOES get a real `tCatalogSync` +
  /// `tCatalogSyncReply` well before the delete, and *that* reply's
  /// `remote_ver` is what reappears as `prevRemoteVer`. Resolution: the
  /// restart capture's app had a *locally cached* remote_ver left over
  /// from an earlier session's real sync — this connection-scoped library
  /// has nothing equivalent to draw on across connections, so it must
  /// always sync once per connection, which is what it does.
  ///
  /// **The `byte[0]` tag went through three theories before the real one:**
  /// (a) a fixed `0x30`/first-delete vs. `0x31`/subsequent-delete marker —
  /// looked right only because every early capture's total length was
  /// small enough to fit that exact byte value by coincidence; (b) an
  /// app-version-number field reflecting the mobile app's own installed
  /// version — abandoned once a fresh capture
  /// from a second, independent device showed `byte[0]` with its
  /// continuation bit SET (`0x82`, `0xa3` — i.e. genuinely multi-byte
  /// LEB128 values, impossible for a small fixed app-version integer to
  /// produce by coincidence with two different real values); (c) **the
  /// real answer**, the self-referential outer-length LEB128 described in
  /// the wire format section above, found by solving `value =
  /// totalMessageLength - lebByteLength(value)` for all 9 real messages
  /// available at the time and getting an exact match every time.
  ///
  /// **The `18:23` prefix (`01 07 <A> 03 <B>`) went through two theories:**
  /// (a) `B = A - 2`, a small session-local counter that increments by 1
  /// across consecutive deletes — looked right across the first 4 real
  /// captures, which all happened to carry a similarly-sized `del_vstamp`;
  /// (b) **the real answer**, found via a targeted, systematic analysis
  /// of the delete message's own serialization behavior with `del_vstamp`
  /// values chosen for distinct LEB128 lengths (1,
  /// 2, 5, 10 bytes): `A = 23 + lebLen`, `B = 21 + lebLen`, confirmed
  /// byte-for-byte at every tested length. Using the stale/wrong "session
  /// counter" reading here produced a message whose internal
  /// self-description disagreed with its actual size — itself a very
  /// plausible reason early delete attempts were silently ignored.
  ///
  /// **The trailer's checksum-vs-field question was the single longest
  /// dead end in this whole investigation** (multiple sessions): every
  /// CRC16 (CCITT/IBM-reflected, both init values, both byte orders) and
  /// CRC32 (IEEE + Castagnoli, both init values, both byte orders) was
  /// exhaustively brute-forced over every possible byte window of the
  /// message and every possible offset within the trailer, across several
  /// real captures simultaneously — zero consistent match, twice,
  /// independently, in two different sessions. The real answer was that
  /// the delete message has **3 real fields, not 1**: the mandatory uuid
  /// (field 0), an optional 8-byte field internally called `del_vstamp`
  /// (field 1), and an optional 16-byte `evicted_uuid` field
  /// (field 2, never used by this method). Every earlier analysis only
  /// ever tested field 0 present with the others absent, which serializes
  /// successfully but is shorter than any real capture — hence "trailer
  /// bytes" that never reproduced from first principles.
  ///
  /// **Where `del_vstamp`'s real value comes from** (found immediately
  /// after solving its encoding, same 2026-08-08 session): every
  /// `tGetObjectReply` JSON already includes a real, plotter-assigned
  /// `"vstamp"` number for that object (documented in this file's top doc
  /// comment since the very first working version of object-fetching, but
  /// never previously connected to the delete trailer) — a server-known
  /// per-object version the client genuinely has, unlike the per-topic
  /// `remote_ver` the client has to invent since deletes get no reply to
  /// learn a server value from.
  ///
  /// **After every field above was individually solved and verified, live
  /// deletes STILL silently failed** for another full day of testing —
  /// several complete rewrites chased other candidate explanations that
  /// all turned out to be either wrong, unnecessary, or real-but-not-the-
  /// blocker:
  /// - Whether `newRemoteVer` should be `prevRemoteVer + 1` vs. a fresh
  ///   "clock-like" value vs. the plotter's own real version-stamp formula
  ///   (the last of these, `seq+1` with a random `sub`, is correct — see
  ///   the wire format section).
  /// - Whether a `fetchObjects` batch-download round-trip needs to run
  ///   between the sync and the delete to "prime" the plotter's
  ///   merge/digest state (kept in place — real captures show the real
  ///   app doing this — but not the actual blocker).
  /// - Whether a ~30s delay is needed after that batch round-trip before
  ///   the delete ([deletePostMergeDelay] — kept, matches observed real
  ///   timing, but not the actual blocker either).
  /// - Whether a second, parallel "auxiliary" TCP connection (registering
  ///   `auxiliaryTopics`, matching real captures' two-connection pattern)
  ///   is required — extensively live-tested both with and without;
  ///   inconclusive either way, confounded by the plotter's own
  ///   [[plotter-timeout-lockout]] behavior making clean A/B comparisons
  ///   hard. Not needed for the final successful delete (single connection
  ///   only), so not required, at least not for this exact scenario.
  /// - Whether an HTTP pairing/authorization step (`credential.dart`'s
  ///   `pair()`, registering this client as a known device via the
  ///   plotter's on-board `_garmin-bl-id._tcp` service) is a prerequisite
  ///   for writes specifically (reads work fine unpaired) — a plausible
  ///   theory the user explicitly declined to pursue live ("Nein, anderen
  ///   Ansatz verfolgen"); turned out to be unnecessary once the real bug
  ///   (the trailer tag byte) was found, so don't re-propose this.
  /// - **A dedicated baseline-reliability test was the key move that
  ///   un-confounded everything**: 5 consecutive, isolated
  ///   `fetchCatalog(topicRoutes)` calls (zero delete/write content, 10s
  ///   apart) showed only the very first succeeded — proving the plotter
  ///   has a real reply-suppression "lockout" after roughly one request,
  ///   independent of content (see [[plotter-timeout-lockout]]). This
  ///   explained a large fraction of *previous* "delete failed" results
  ///   (most test scripts implicitly made 2+ requests per attempt), but a
  ///   single clean delete made as the very first request after a full
  ///   lockout-recovery wait STILL failed — proving the lockout was a
  ///   real, separate confound, not *the* answer, and motivating one more
  ///   round of pure byte-level analysis instead of more live probing.
  /// - **The actual breakthrough**: a byte-for-byte comparison of this
  ///   library's own sent delete frame against a real, guaranteed-
  ///   successful delete frame from a fresh, independent second-device
  ///   capture (already on disk, not a new capture — the user had said
  ///   "captures hast du genug, mach was anderes", so this was pure
  ///   re-analysis of existing data) found every field identical except
  ///   one: the `del_vstamp` trailer's tag byte (`0x0d` in the real
  ///   capture vs. `0x05` sent by this library for the same 5-byte LEB128
  ///   value) — which decoded cleanly as `(fieldId=1 << 3) | lebLen=5`
  ///   once compared side-by-side with the already-understood uuid field's
  ///   own `(fieldId=0 << 3) | 7` tag byte. Fixing that one byte (see
  ///   [_buildDeleteTrailer]) was the final missing piece.
  /// - **Follow-up isolation test, same day**: the first successful delete
  ///   happened to also have `debugClientUnitId` set to a value learned
  ///   from this plotter's real sync replies, leaving open whether that
  ///   mattered. A second delete (different route, unit id left at its
  ///   ordinary random default) succeeded identically — settling that the
  ///   trailer-tag fix alone is sufficient and `unitId` is cosmetic for
  ///   this path. See [_freshRemoteVerLikeValue]'s doc comment above.
  Future<void> deleteEntry(
    int topic,
    String uuid, {
    Duration timeout = const Duration(seconds: 30),
    // **Bug found live 2026-08-10 (twice — the first fix was itself
    // incomplete, caught again live the same day via the UI's delete
    // button silently not working a second time).** [vstamp], when
    // supplied, must NOT unconditionally win over a fresher catalog-entry
    // vstamp this method's own re-sync just learned — a caller holding an
    // object loaded even a short time earlier can pass a `vstamp` already
    // behind the plotter's real current state, producing a `del_vstamp`
    // that no longer matches and gets silently ignored (no exception, no
    // lockout — the plotter just keeps the entry, indistinguishable from
    // every other "structurally fine, silently ignored" failure mode this
    // file has chased before).
    //
    // The rule, precisely: on the (first-delete-on-this-connection)
    // syncing path (see the `else` branch further below), this method
    // ALWAYS prefers the vstamp its own fresh sync just decoded for this
    // uuid over whatever's passed here — a caller-supplied value is only a
    // fallback if that sync's own record didn't decode one. On the
    // (subsequent-delete-on-an-already-primed-connection) fast path (see
    // the `_mergePrimedTopics` branch below), there is genuinely no fresh
    // sync to prefer, so a supplied `vstamp` IS the only usable source —
    // pass the object's own last-known `vstamp` there (e.g. from a
    // `DownloadedObject` the UI already loaded), matching what two real
    // captures of the official app deleting multiple routes on one
    // connection show it doing (it never re-learns per-object vstamps
    // from the plotter between deletes on the same connection either).
    int? vstamp,
    bool debugOmitVstampTrailer = false,
    Uint8List? debugPrevRemoteVer,
    int? debugTag,
    List<int>? debugCounterPrefix,
  }) async {
    // **Corrected again 2026-08-08, same day, after a THIRD real capture
    // (398926d6-PCAPdroid_08_Aug._12_23_571.pcap) — this one from a full
    // app reset, capturing literally everything the app does from a cold
    // start through an actual delete.** This directly contradicts the
    // previous rewrite's conclusion (drawn from `b7ee1473`, an app
    // restart but NOT a full reset): with a truly fresh app, topicRoutes
    // DOES get a real tCatalogSync + full tCatalogSyncReply (`remote_ver
    // = 424dd43299030000`) well before the delete — and that exact
    // `remote_ver` value reappears byte-for-byte as the delete's own
    // `prevRemoteVer`. **So `prevRemoteVer` IS the real, server-synced
    // remote_ver after all** — the `b7ee1473` capture's matching
    // registration-carried value was very plausibly the app's own
    // *locally cached result of an earlier session's real sync*, not
    // evidence that sync is skippable in general. `newRemoteVer` is
    // still NOT `prevRemoteVer + 1` in this 3rd capture either (differs
    // by billions again), consistent with the earlier finding that it's
    // a fresh client-side clock/counter value, unrelated to
    // `prevRemoteVer` — [_freshRemoteVerLikeValue] is kept for that one.
    // Net effect: restored the `tCatalogSync`-based `prevRemoteVer`
    // lookup (via [_fetchCatalog], reusing an already-cached remote_ver
    // when available, exactly like the pre-2026-08-08 version did), while
    // keeping the two fixes that ARE still confirmed correct by this 3rd
    // capture: `newRemoteVer` as a fresh clock-like value (not `+1`), and
    // no post-delete verification tCatalogSync (this capture's app makes
    // no further topicRoutes requests at all after the delete, for the
    // rest of the capture).
    // **`del_vstamp` source corrected 2026-08-08, same day, after a full
    // fresh-app-reset capture showed the real app never sends a per-object
    // tGetObject before deleting** (topicRoutes gets exactly one
    // tCatalogSync + reply, then the delete — see the capture-by-capture
    // account above). That only makes sense if `vstamp` is already
    // available from the sync reply itself — and it is: each catalog
    // entry's own trailing 6 bytes (previously discarded — see
    // [_parseCatalogEntries]'s doc comment) decode as a `vstamp` in the
    // exact same LEB128 format as the delete trailer. So this method now
    // gets `vstamp` from the SAME `_fetchCatalog` call it already needs
    // for `prevRemoteVer`, instead of a separate [fetchObject] round-trip
    // — which is also suspected of being what tripped the plotter's "user
    // data sharing disabled" lockout in a live test right after this fix
    // was written but before it was applied (the extra tGetObject the
    // real app never sends). [fetchObject] is now only used as a last-
    // resort fallback if the catalog entry's own vstamp somehow didn't
    // decode.
    // **`del_vstamp` is NOT the object's last-known vstamp verbatim —
    // corrected 2026-08-08, still same day, after a live comparison against
    // the full-reset capture showed the real sent `del_vstamp`
    // (30372247711) matched neither the catalog-entry-trailer vstamp nor
    // the tGetObjectReply JSON vstamp for the same object.** Comparing
    // several real delete captures byte-for-byte showed the plotter's
    // vstamp is a packed `(seq << 32) | sub` bitfield, and deleting
    // increments `seq` by 1 while drawing a fresh random 32-bit `sub` —
    // confirmed exactly against the capture (`seq` 6 -> 7). See
    // [_incrementVstamp]'s doc comment for the full derivation.
    // [_buildDeleteTrailer] now performs
    // this increment itself, so `resolvedVstamp`/`entry.vstamp` below is
    // still the object's *pre-delete* vstamp, not `del_vstamp` itself.
    Uint8List prevRemoteVer;
    var resolvedVstamp = vstamp;
    if (debugPrevRemoteVer != null && resolvedVstamp != null) {
      // **Debug/investigation path, added 2026-08-08.** Four of five real
      // captured deletes (`4ad48dae`, `b7ee1473`, `ccabc88b`, `ff52feee`)
      // show the real app sending `tRegisterTopic` on `topicRoutes`
      // followed IMMEDIATELY by the delete — no `tCatalogSync` at all on
      // that connection. Only the fifth (`398926d6`, a full app-data-reset
      // capture with no locally-persisted `remote_ver` to fall back on)
      // shows a real sync first. This strongly suggests the real app
      // normally reuses a `remote_ver` it already has cached from a prior
      // session/connection, rather than always re-syncing — something
      // this connection-scoped library can't replicate for [prevRemoteVer]
      // itself (no persistence across [RouteCatalogConnection] instances),
      // but this parameter lets a caller supply one anyway (e.g. from an
      // earlier connection's own [_fetchCatalog] in the same process) to
      // test the hypothesis without the internal sync this method
      // otherwise always performs.
      prevRemoteVer = debugPrevRemoteVer;
    } else if (_mergePrimedTopics.contains(topic) && _remoteVerByTopic[topic] != null) {
      // **Restored 2026-08-10, correctly this time.** A 2026-08-09 fix
      // removed a `_remoteVerByTopic` cache shortcut that used to live
      // here, because it skipped the `fetchObjects` merge-completion
      // round-trip entirely — including on a connection that had never
      // primed the topic at all, which is what actually broke deletes.
      // That reasoning was right for an UNPRIMED topic, but wrong to apply
      // unconditionally: two real captures of the official app deleting
      // multiple routes (one "select 3, delete together", one "delete 3
      // one at a time" with the user manually triggering each) both show
      // it reusing one connection for every delete and NEVER re-running
      // `tCatalogSync` after the first delete on that connection — not
      // even when deletes are ~10s apart with real user interaction in
      // between. `prevRemoteVer`/`newRemoteVer` chain purely client-side
      // (each delete's own `newRemoteVer` becomes the next delete's
      // `prevRemoteVer`, `seq+1` each time — confirmed byte-for-byte
      // across 3 consecutive real deletes in both captures) — the app
      // never re-learns `remote_ver` from the plotter between deletes.
      // This branch reproduces that: once [_mergePrimedTopics] confirms
      // this connection already ran the merge-completion round-trip for
      // [topic] at least once (via the `else` branch below), every
      // subsequent delete reuses [_remoteVerByTopic]'s cached value
      // instead of re-syncing. A `uuid` no longer present would previously
      // have been caught by the sync's own catalog lookup — that check is
      // skipped here (this branch has no fresh catalog to check against),
      // so deleting an already-deleted or nonexistent uuid on a primed
      // connection now sends the wire message anyway rather than throwing;
      // the plotter's own fire-and-forget handling of that case is
      // unconfirmed but not expected to be harmful (see [deleteEntry]'s
      // wire-format doc comment: unknown/mismatched uuids are simply not
      // acted on, matching every other "structurally fine, silently
      // ignored" case already documented).
      prevRemoteVer = _remoteVerByTopic[topic]!;
      // No fresh catalog sync happened on this fast path, so `vstamp` (if
      // the caller supplied one) is the ONLY source `resolvedVstamp` can
      // come from here — already assigned above via `var resolvedVstamp =
      // vstamp;`. **No further fallback if the caller passed nothing**
      // (removed live 2026-08-11, see the note further below where the old
      // `fetchObject` fallback used to be): `del_vstamp` is simply omitted
      // in that case, a genuinely valid (if less precise) message rather
      // than risking another per-object request.
    } else {
      final before = await _fetchCatalog(topic, timeout: timeout);
      // **Bug found live 2026-08-08, worked around here**: [_syncCatalog]'s
      // `entries` field is trimmed by a `validCount` heuristic that turns
      // out to wrongly drop real, valid entries sometimes (a just-created
      // route sitting at the very end of the raw list, past the trim
      // point, in one live test) — see [_syncCatalog]'s own doc comment.
      // Search [before.allEntries] (the untrimmed raw list) instead of
      // [before.entries] here, since this is a lookup for one already-known
      // uuid, not a "what should I show the user" listing where showing a
      // non-fetchable phantom entry would be the worse failure mode.
      final matching = before.allEntries.where((e) => e.uuid == uuid);
      if (matching.isEmpty) {
        throw RouteCatalogException('entry $uuid not found in the current catalog for topic 0x${topic.toRadixString(16)}');
      }
      final entry = matching.first;
      prevRemoteVer = before.remoteVer;
      // **Fixed live 2026-08-10 (again) — a fresh sync's own catalog-entry
      // vstamp must win over a caller-supplied one, not the other way
      // round.** This branch just ran a real tCatalogSync (`before`,
      // above) and so genuinely knows the plotter's current vstamp for
      // this uuid — that's strictly more current than anything a caller
      // could have learned earlier (e.g. a UI's `DownloadedObject.vstamp`
      // captured whenever that object was first loaded, possibly minutes
      // earlier). The previous line here was `resolvedVstamp ??=
      // entry.vstamp` — which only fills in `entry.vstamp` when no
      // caller-supplied `vstamp` exists, so a caller that *always* passes
      // one (like the UI's delete button, which passes
      // `object.vstamp` unconditionally) silently locked out this fresh
      // value every single time, even on this, the fully-synced path,
      // despite an earlier doc-comment claim to the contrary above. This
      // reproduces the exact silent-failure symptom this file has chased
      // multiple times before: structurally correct wire bytes, no
      // exception, no lockout, but the plotter keeps the entry — because
      // `del_vstamp` was built from a stale `entry.vstamp` while the
      // plotter had already moved on. `entry.vstamp` (this fresh sync's
      // own value) now always wins on this path when available; a
      // caller-supplied `vstamp` is only used here as a fallback if this
      // sync's own record didn't decode one.
      resolvedVstamp = entry.vstamp ?? resolvedVstamp;

      // **Added 2026-08-08, after four live deletes with the corrected
      // del_vstamp/prevRemoteVer logic above still silently failed to
      // remove the entry (structurally correct wire bytes, no error, no
      // lockout — the plotter just kept the entry).** A local tcpdump of
      // one of those failed attempts, compared byte-for-byte against the
      // real full-reset capture, showed the one remaining structural gap:
      // the real app follows its tCatalogSync/tCatalogSyncReply with a
      // full BATCH tGetObject covering every uuid in the reply
      // — a merge-completion round-trip,
      // not an optional object download — before sending the delete. This
      // library's fetchCatalog alone never did that batch fetch, so the
      // server-side merge/digest state this delete lands on was never the
      // same one the real app leaves it in. [fetchObjects] on the
      // (validCount-trimmed) [before.entries] uuid list reproduces that
      // completion round-trip; its returned objects aren't otherwise used
      // here (this method already has resolvedVstamp from the catalog
      // entry).
      //
      // **Only run once per topic per connection — added 2026-08-10.**
      // This primes server-side merge/digest state for the *topic*, not
      // for the one delete about to be sent, so a second delete on the
      // same topic/connection shortly after a first one doesn't need to
      // repeat a full batch content download of every object on the
      // topic — confirmed live: skipping it on a topic already primed
      // this same connection still deletes successfully, cutting a
      // multi-delete session (e.g. the UI's multi-select bulk delete)
      // from one full batch download per entry down to one for the
      // whole session.
      if (!_mergePrimedTopics.contains(topic) && before.entries.isNotEmpty) {
        await fetchObjects(topic, before.entries.map((e) => e.uuid).toList(), remoteVer: before.remoteVer, timeout: timeout);
        _mergePrimedTopics.add(topic);
      }

      // **`deletePostMergeDelay` (originally 30s) retired 2026-08-10.**
      // Added 2026-08-09 as a precaution: real captures show ~30s between
      // the merge-completion round-trip and the delete, and at the time
      // this was added, deletes were still failing for a then-unknown
      // reason, so the delay was kept as a "match the observed real
      // timing just in case it matters" safety margin. **It never was the
      // fix** — the actual remaining bug (found later the same day) was
      // the `del_vstamp` field-tag byte (see [_buildDeleteTrailer]'s doc
      // comment). Live-tested with this delay removed entirely after that
      // fix: deletes still succeed immediately, confirming the delay was
      // never load-bearing, just a coincidentally-timed guess that
      // happened to also be present while the real fix was still
      // unknown. [deletePostMergeDelay] is kept as a field (default now
      // [Duration.zero]) rather than deleted outright, in case a future
      // plotter/firmware genuinely needs a settling delay — but no longer
      // waited on by default.
      await Future<void>.delayed(deletePostMergeDelay);
    }
    final newRemoteVer = _freshRemoteVerLikeValue(prevRemoteVer);

    // **Removed live 2026-08-11 — this fallback was itself a live-tested
    // cause of the plotter's "User data sharing is disabled" protection
    // tripping.** This used to call [fetchObject] here as a last resort
    // when [resolvedVstamp] was still null (e.g. a catalog entry whose
    // trailer didn't decode a vstamp — happens for entries the plotter's
    // own sync still lists but that are no longer really fetchable, such
    // as one already deleted a moment earlier on a previous connection).
    // But a per-object [tGetObject] for a uuid the plotter can't
    // meaningfully answer is exactly the kind of request this file's own
    // doc comments already flagged as something the real app never sends
    // before a delete — and live-tested here to trip the protection
    // screen immediately, with no other request in flight at the time.
    // `del_vstamp` is a genuinely optional field (every real capture with it
    // omitted still parses as a structurally valid message — see
    // [_buildDeleteTrailer]'s doc comment), so the safe, structurally valid
    // choice when it's unknown is to omit
    // it entirely rather than risk an extra round-trip the plotter may not
    // handle gracefully. [resolvedVstamp] is simply left null here;
    // [_buildDeleteTrailer] already handles that case correctly.

    final targetUuidBytes = _parseUuid(uuid);

    // **body[0] — fully resolved 2026-08-09, via a fresh capture from a
    // second, independent device/app-install** (`355eb949`, a full
    // app-reset on a tablet). That capture's connection sent, in order:
    // an `rte_change` (ADD/UPDATE) on waypoints (260 bytes total), an
    // `rte_change` on routes (805 bytes total), THEN the actual
    // `rte_del` (49 bytes total) — i.e. real deletes are sometimes
    // preceded by unrelated change messages earlier in the same burst,
    // not something this method needs to replicate itself (the target
    // route's own delete is still the last, independent message). What
    // mattered for THIS field: decoding body[0] as a raw byte (as every
    // previous version of this file did) only ever looked right by
    // coincidence, because every previously-analyzed delete capture
    // happened to have `body[0] < 0x80` (no LEB128 continuation bit). The
    // two much larger change messages exposed the real shape: `body[0]`
    // has its continuation bit SET (`0x82`, `0xa3`), decoding as a real
    // multi-byte LEB128 vint (258, 803) — not an app-version field
    // after all (that theory is now retired). Solving
    // `value = totalMessageLength - lebByteLength(value)` for all 9 real
    // messages available (6 old delete captures + these 3 new ones) gives
    // an exact match every time (49->48, 50->49, 260->258, 805->803) —
    // this is the outer message envelope's own length-vint (mirroring the
    // exact same "size of what follows, including this field's own
    // encoded width" pattern already solved for [_rteDelMsgTagPrefix] and
    // the present-field count below), not a version, discriminator, or
    // session counter of any kind. [debugTag] is kept for callers that
    // want to force a specific raw value for testing, but the real value
    // is now computed, not guessed.
    final vstampTrailer = debugOmitVstampTrailer ? const <int>[] : _buildDeleteTrailer(resolvedVstamp);
    final counterPrefix = debugCounterPrefix ?? _rteDelMsgTagPrefix(vstampTrailer.isNotEmpty ? vstampTrailer.length - 1 : null);
    // **Understood 2026-08-09, not just copied from captures anymore**: this
    // leading byte is a present-field COUNT (a vint) — comparing several
    // real delete captures shows it counts every field actually present in
    // the message, mandatory or optional. The delete message has 3 possible
    // fields (uuid, del_vstamp, evicted_uuid); uuid is mandatory (always
    // present), evicted_uuid is never set by this method, so the count is 2
    // when `del_vstamp` is present and 1 when it's been omitted — previously
    // hardcoded to `0x02` regardless, silently wrong whenever
    // [vstampTrailer] ends up empty (a real, if rare, path: any object
    // without a decodable vstamp — see [_buildDeleteTrailer]'s doc
    // comment). `07 11 10` (uuid's own tag+overflow-size+data-length
    // prefix) is separately understood: `07` = `(fieldId=0 << 3) |
    // min(size,7)` with the overflow bit set (the uuid field's own
    // descriptor is 17 bytes, always >6), `11` = that
    // 17-byte overflow size itself, `10` = the UUID value's own 16-byte
    // length prefix (a length-prefixed byte string, not a bare fixed
    // array) — all reproduced byte-for-byte from consistent patterns across
    // every real capture examined, not guessed from a too-small sample.
    final presentFieldCount = 1 + (vstampTrailer.isNotEmpty ? 1 : 0);
    final tail = <int>[
      ...counterPrefix, // 01 07 <A> 03 <B> -- see _rteDelMsgTagPrefix's doc comment
      presentFieldCount, 0x07, 0x11, 0x10, // present-field count + uuid tag/size/length prefix
      ...targetUuidBytes,
      ...vstampTrailer,
    ];
    // Both the trailing tail-length field AND the leading body[0] field are
    // real LEB128 vints (see above) — [_encodeUnsignedLeb128] handles any
    // size correctly, unlike the previous single-raw-byte code, which
    // silently produced wrong bytes for any tail >= 128 bytes long (never
    // exercised live before because every real delete's tail has stayed
    // under that so far, but a structurally real bug regardless).
    final tailLenBytes = _encodeUnsignedLeb128(tail.length);
    final restAfterTag = <int>[
      ...prevRemoteVer,
      ...newRemoteVer,
      ...tailLenBytes,
      ...tail,
    ];
    // [_solveSelfReferentialLeb128Length] expects the TOTAL message length
    // (tag field included), not just [restAfterTag.length] — the tag
    // value it solves for equals [restAfterTag.length] exactly (verified
    // against all 4 distinct real totalLen/tag pairs available: 49->48,
    // 50->49, 260->258, 805->803), but reaching that fixed point requires
    // feeding the solver a total-length estimate that already accounts
    // for the tag field's own width, or it converges one short. Passing
    // `restAfterTag.length` alone (an earlier version of this line's
    // bug, caught by re-deriving the expected values from the real
    // captures independently rather than trusting a first passing test
    // run) under-solves by exactly 1.
    final totalLengthEstimate = restAfterTag.length + _encodeUnsignedLeb128(restAfterTag.length).length;
    final tagValue = debugTag ?? _solveSelfReferentialLeb128Length(totalLengthEstimate);
    final body = <int>[
      ..._encodeUnsignedLeb128(tagValue),
      ...restAfterTag,
    ];

    _send(topic, tDeleteEntry, 0, body);
    _remoteVerByTopic[topic] = newRemoteVer;

    // No reply to await (fire-and-forget, confirmed across all 3 original
    // real captures used to reverse-engineer this) and, as of 2026-08-08,
    // no verification round-trip either — a fresh real capture of an
    // actual app-driven delete showed the real app makes NO further
    // requests on this topic at all afterward, not even a read-only one.
    // An earlier version of this method ran its own post-delete
    // fetchCatalog to check the entry was really gone, on the theory that
    // fire-and-forget means this library has no other way to know it
    // worked — but that extra round-trip is itself something the real app
    // never does, and every previously-observed "delete looked like it
    // worked, then the entry came back a few minutes later" incident
    // happened on connections that (unlike the real app's) always did run
    // extra tCatalogSync traffic around the delete. Whether removing it
    // actually fixes that symptom isn't confirmed yet — this needs a
    // fresh live test, ideally checked from a *separate* later connection
    // (not this same method) after several minutes, the same way the
    // real app would only find out via its own next independent sync.
  }

  /// Creates or updates a single catalog entry (waypoint or route) on the
  /// plotter — same dedicated message as [deleteEntry] (`tDeleteEntry`,
  /// `0x02`; the plotter distinguishes add/update/delete purely by the
  /// message body, not by a different `msgType`), fire-and-forget, no
  /// reply.
  ///
  /// **Reverse-engineered 2026-08-11** from a real capture (`355eb949`) of
  /// the official app creating a waypoint ("DYVIG") and a route
  /// ("ANSTEUERUNG DYV") referencing it. Not yet live-tested against a real
  /// plotter — see this method's own doc-comment history once that
  /// happens.
  ///
  /// ### Wire format (tail, after the shared envelope described in
  /// [deleteEntry]'s doc comment: self-referential outer length tag,
  /// `prevRemoteVer`/`newRemoteVer`, LEB128 tail length)
  /// ```
  /// byte[0:2]    fixed `01 07`
  /// bytes[2:]    a LEB128 vint `A`, then `02`, then a LEB128 vint `B` —
  ///              **both self-referential byte offsets, not the
  ///              `A=23+lebLen`/`B=21+lebLen` formula [deleteEntry]'s own
  ///              trailer uses.** `B` is the exact byte distance from the
  ///              END of this tail back to the start of the present-field-
  ///              count byte below (i.e. `B = tail.length -
  ///              offsetOfFieldCountByte`), solved the same way
  ///              [_solveSelfReferentialLeb128Length] solves the outer tag
  ///              (`B` incorporates its own LEB128 width). `A = B +
  ///              lebLen(B) + 1` — confirmed exactly on both real
  ///              messages (waypoint: A=236/B=233/lebLen(B)=2; route:
  ///              A=781/B=778/lebLen(B)=2). [deleteEntry]'s own
  ///              `A=23+lebLen`/`B=21+lebLen` formula is a coincidentally-
  ///              linear special case of this same rule for a short
  ///              (fieldCount ≤ 2) delete tail, not a separate mechanism —
  ///              kept as-is there since it's already live-confirmed
  ///              working and changing it isn't worth the risk.
  /// next byte    present-field count (a plain byte here, `0x05` on both
  ///              real captures — uuid + object-vstamp + 3 more framing
  ///              fields the JSON blob itself covers, not decoded further
  ///              field-by-field).
  /// next 3 bytes fixed `07 11 10` — the mandatory uuid field's own
  ///              tag/overflow-size/length prefix, identical to
  ///              [deleteEntry]'s.
  /// next 16      the object's own UUID (this client generates a fresh
  ///              [_randomUuidBytes]-shaped one for a create; reuses
  ///              the existing uuid for an update).
  /// next 7       the object's OWN `vstamp` (not `del_vstamp` — no
  ///              increment applied here), tagged `0x0d` + up to 6 LEB128
  ///              payload bytes, zero-padded to a fixed 7-byte field —
  ///              same tag/length convention as [_parseCatalogEntries]'s
  ///              catalog-entry trailer. For a brand-new object (no prior
  ///              vstamp), sent as `0d 00 00 00 00 00 00` — untested
  ///              whether the plotter accepts a zero vstamp for a create;
  ///              this is the most literal reading of "no known vstamp
  ///              yet" and mirrors how [_buildDeleteTrailer] treats a null
  ///              vstamp as an all-zero-length case, but needs live
  ///              confirmation.
  /// next 4       fixed marker `02 19 01 27`.
  /// next N       `gzipBlobLength + 8` as a LEB128 vint, then the SAME
  ///              `02 01 00 0f` [_memberLengthMarker] the download side's
  ///              [_readMemberLengthFromHeader] already knows, then two
  ///              more LEB128 vints — `gzipBlobLength + 2`, then the exact
  ///              gzip blob length (the same "two LEB128 values, the
  ///              second is the real length" shape that download-side
  ///              header uses). Confirmed on both real captures
  ///              (waypoint: 200/194/192; route: 745/739/737).
  /// rest         the gzip-compressed JSON object body itself — BYTE-
  ///              IDENTICAL shape to [fetchObject]'s reply JSON: `{"uuid",
  ///              "proto_ver", "min_proto_ver", "vstamp", ...}` plus
  ///              `"points"` (route) or `"lat"/"lon"` (waypoint). The real
  ///              waypoint capture additionally had `"dspl_optn"`,
  ///              `"depth"`, `"temp"`, `"mtime"`, `"comment"`, `"sym"`
  ///              fields never seen in a download reply before — not
  ///              required (untested which are optional), included here
  ///              as sent as loosely as possible: only the fields this
  ///              client actually has values for.
  /// ```
  ///
  /// **⚠ SUPERSEDED 2026-08-11 — this whole `tDeleteEntry`-shaped wire
  /// format above was never actually how the real app creates objects.**
  /// Two live attempts sending exactly this (once with `vstamp: 0`, once
  /// with a plausible non-zero `vstamp`, both after the same merge-priming
  /// [deleteEntry] needs) both sent successfully but did nothing — the
  /// catalog's entry count never changed. A fresh, purpose-made capture
  /// (`34d945fa`, then a second confirming one, `342c2f35`) of the real
  /// app creating actual new waypoints ("0001", then "0003") on a plotter
  /// with a large existing catalog. That capture pair suggested creation
  /// went through [tCatalogSync] instead — **also wrong**, or at least not
  /// the ONLY mechanism: a third capture (`83d8898e`, two waypoints "0005"
  /// and "0006" created back-to-back on a connection that never ran
  /// [tCatalogSync] at all) showed BOTH new objects sent as ordinary
  /// [tDeleteEntry]-shaped (`msgType 0x02`) messages, structurally
  /// identical to the format documented above — live-confirmed on the
  /// plotter both times. This whole doc-comment section (wire format
  /// above) is therefore accurate after all; [addOrUpdateWaypoint]'s
  /// remaining doc comment below covers the one real gap the two earlier,
  /// failed live attempts actually had: `prevRemoteVer`.
  ///
  /// **A route's points are NOT embedded coordinates — they're UUID
  /// references to separately-created waypoint objects**: the real
  /// captured route's JSON has `"points": [{"lon":..., "lat":...,
  /// "ref":{"class":"uwpt","uuid":"..."}}]`. Not yet implemented or
  /// tested here.
  ///
  /// Creates or updates a waypoint on the plotter's catalog.
  ///
  /// **✅ STATUS as of 2026-08-12: confirmed working live** — a real
  /// created waypoint was independently verified present in the plotter's
  /// own catalog afterward (fresh connection, untrimmed catalog listing),
  /// resolving weeks of otherwise byte-perfect live failures. Two things
  /// were needed, found via two fresh real captures (`bb58f5ed`: waypoints
  /// "0008"/"0009" + route "49"; `4fdcc705`: route "Vlissingen -> R", 16
  /// points):
  ///
  /// 1. **A wrong fixed byte in [_buildAddOrUpdateBody]'s tail**, found by
  ///    re-deriving every field of the tail from scratch against four real
  ///    create frames (not just re-checking the fields already believed
  ///    correct): the byte right after `A`'s own LEB128 encoding was
  ///    hardcoded `0x02` (copied by analogy from [deleteEntry]'s
  ///    differently-shaped `03` marker at a similar position) but is
  ///    `0x01` in every real frame examined. This is the most likely real
  ///    explanation for every earlier live failure — the message always
  ///    sent cleanly (lengths and self-referential offsets all still
  ///    checked out with the wrong byte in place) but the plotter silently
  ///    dropped it.
  /// 2. `prevRemoteVer` is simply **the most recently known `remote_ver`
  ///    for the topic on this connection** — sourced from a real sync when
  ///    one happened to run for another reason, or straight from the
  ///    topic's registration correlation id when nothing else had touched
  ///    it since. The protocol doesn't care which; it only cares that the
  ///    value is current. This method now always runs a fresh
  ///    [_fetchCatalog] sync immediately before building the message —
  ///    **without** the merge-completion batch download [deleteEntry]
  ///    additionally needs (that batch is what didn't scale past ~118
  ///    entries and caused repeated plotter lockouts in earlier attempts;
  ///    omitting it here matches both real captures, neither of which ran
  ///    a batch `tGetObject` before a create).
  ///
  /// **Known rough edge**: this method's own mandatory sync-before-every-
  /// call, against a catalog that has grown past 200 entries, has been
  /// observed triggering the plotter's "user data sharing disabled"
  /// lockout shortly after a call completes (a real, previously-documented
  /// plotter protection state — see this file's own top-level notes) —
  /// not confirmed whether this is inherent to syncing a catalog this
  /// large at all, or specific to doing it right before another write.
  /// Not yet a problem for a single call; something to watch for repeated
  /// calls in quick succession.
  ///
  /// **Reverse-engineered 2026-08-11/12**, across six real captures and
  /// many live attempts. The wire format itself (this method's own
  /// tail-building, shared with [deleteEntry] via [_buildAddOrUpdateBody])
  /// had exactly one wrong byte, found only once a full field-by-field
  /// re-derivation was done instead of re-checking already-trusted fields.
  ///
  /// **The object's own `vstamp` — client-generated, `seq=2` on every
  /// real create seen.** Four real captures' new-object vstamps all
  /// decode as `(seq << 32) | sub` with `seq == 2` exactly (10728735544,
  /// 9818661725, 10089107145, 11499009382 — four different `sub` values,
  /// same `seq`), unrelated to the connection's per-topic `remote_ver`
  /// `seq` (in the hundreds in the same captures) or to
  /// [_incrementVstamp]'s delete-side `seq+1` scheme. A fifth, older
  /// object seen only being UPDATED (not created) had `seq=3` —
  /// consistent with `seq=2` being a real "first version" starting value
  /// an update would increment from, though update support isn't
  /// implemented here yet (this method always creates a fresh uuid,
  /// ignoring [uuid] would need for reuse — see its own parameter doc).
  /// `sub` is a fresh random 32-bit value, same shape as every other
  /// vstamp/remote_ver `sub` field this file generates.
  Future<String> addOrUpdateWaypoint(
    String name,
    double lat,
    double lon, {
    String? uuid,
    Duration timeout = const Duration(seconds: 30),
    // **Debug/investigation parameter, added 2026-08-11.** The real
    // capture this method is modeled on waits ~15s after registering
    // topicWaypoints/topicRoutes (with background keepalives ticking in
    // between) before sending its first create — plausibly just real user
    // interaction time (typing a name, picking a position) rather than
    // anything the plotter's protocol itself requires, but every live
    // attempt so far has sent immediately after registering and none has
    // landed in the catalog. Lets a live test isolate whether this delay
    // matters without changing the method's normal fire-immediately
    // behavior for real callers.
    Duration? debugDelayBeforeSend,
  }) async {
    if (debugDelayBeforeSend != null) {
      await _ensurePreamble(timeout);
      _registerTopic(topicWaypoints);
      _registerTopic(topicRoutes);
      await Future<void>.delayed(debugDelayBeforeSend);
    }

    final targetUuid = uuid ?? _formatUuid(_randomUuidBytes());
    final random = Random();
    final objectVstamp = (2 << 32) | random.nextInt(0x100000000);

    // **Field set and order corrected 2026-08-11** after a live create
    // with only the fields this client had direct values for (uuid,
    // proto_ver, min_proto_ver, lat, lon, vstamp, name) sent successfully
    // but didn't appear in the catalog afterward — every real create
    // capture examined (three independent waypoints: "0001", "0003",
    // "0005") includes SIX more fields in between, in this exact order,
    // with `dspl_optn`/`sym` constant across all three: `dspl_optn: 19`,
    // `depth: null`, `temp: null`, `mtime: <Garmin-epoch seconds>`,
    // `comment: null`, `sym: 18`. Unconfirmed which (if any) are load-
    // bearing vs. cosmetic, but sending the exact real shape rather than
    // a guessed subset is the safer next thing to try.
    final json = <String, dynamic>{
      'uuid': targetUuid,
      'proto_ver': 2,
      'min_proto_ver': 1,
      'lat': _toGarminSemicircle(lat),
      'lon': _toGarminSemicircle(lon),
      'dspl_optn': 19,
      'depth': null,
      'temp': null,
      'mtime': _garminEpochSeconds(DateTime.now()),
      'vstamp': objectVstamp,
      'name': name,
      'comment': null,
      'sym': 18,
    };

    // **Resolved 2026-08-12** via two fresh real captures showing actual
    // successful creates (`bb58f5ed`: waypoints "0008"/"0009" + route "49";
    // `4fdcc705`: route "Vlissingen -> R"). `prevRemoteVer` is simply
    // "whatever `remote_ver` this connection most recently learned for the
    // topic" — the protocol doesn't care whether that value came from the
    // topic's registration correlation id or a real sync reply, only that
    // it's current. Both real captures confirm this: `bb58f5ed` synced
    // `topicWaypoints` immediately before its creates (its `prevRemoteVer`
    // is byte-identical to the sync reply's `remote_ver`, not the
    // registration correlation id); `4fdcc705` did NOT sync `topicWaypoints`
    // before its waypoint creates (nothing else had touched that topic
    // since registration, so the registration correlation id was still
    // current) but DID sync `topicRoutes` first (three routes had been
    // deleted earlier in the same session, advancing that topic's real
    // `remote_ver` past its registration-time value, which would have
    // left an outdated correlation id if it hadn't synced) — this shows
    // why the earlier registration-correlation-id-only approach could
    // plausibly fail
    // during a long-lived test session with multiple prior writes: the
    // cached value goes stale and the plotter silently drops a write
    // built on a stale `prevRemoteVer`.
    //
    // **No longer unconditionally re-syncs — fixed 2026-08-13.** This
    // used to always call [_fetchCatalog] here, on the theory that doing
    // so right before every add/update always produces a current value
    // regardless of caching. That was true in isolation, but wrong once
    // this connection could be long-lived and shared (see
    // [RouteCatalogService]): a SECOND [tCatalogSync] on a topic this
    // same connection had already synced was found live to be its own
    // reliability risk — the exact same "no reply"/reset-connection
    // failure mode already documented on [_syncCatalog]/[fetchObjects]'
    // own doc comments for two batch downloads on one connection,
    // generalized to two plain syncs. [_remoteVerByTopic] already holds
    // the most recently known value for this topic on this connection —
    // from [_registerTopic]'s own correlation id if nothing else has
    // touched it yet, from a real sync if [RouteCatalogService] (or any
    // other caller) already ran one, or from this method's own previous
    // call if this is a second write in a row — so a fresh sync here is
    // only actually needed the first time this topic is touched at all
    // on this connection.
    final prevRemoteVer = _remoteVerByTopic[topicWaypoints] ?? (await _fetchCatalog(topicWaypoints, timeout: timeout)).remoteVer;
    final newRemoteVer = _freshRemoteVerLikeValue(prevRemoteVer);
    final body = _buildAddOrUpdateBody(
      uuid: targetUuid,
      vstamp: objectVstamp,
      json: json,
      prevRemoteVer: prevRemoteVer,
      newRemoteVer: newRemoteVer,
    );

    _send(topicWaypoints, tDeleteEntry, 0, body);
    _remoteVerByTopic[topicWaypoints] = newRemoteVer;
    return targetUuid;
  }

  /// Creates or updates a route on the plotter's catalog, given a list of
  /// `(lat, lon)` points — same envelope/tail mechanism as
  /// [addOrUpdateWaypoint] (see its doc comment for the full derivation),
  /// on [topicRoutes] instead of [topicWaypoints], with a different JSON
  /// object shape: `name`/`uuid`/`auto_name`/`proto_ver`/`min_proto_ver`/
  /// `vstamp`/`points` instead of a waypoint's `lat`/`lon`/`dspl_optn`/etc.
  ///
  /// **✅ Confirmed working live 2026-08-12** — a created route was
  /// independently verified present in the plotter's own catalog
  /// afterward (fresh connection, untrimmed catalog listing).
  ///
  /// **Deliberately NOT matching the real app's own behavior for
  /// `points`.** Real captures (`bb58f5ed`'s route "49", `4fdcc705`'s
  /// route "Vlissingen -> R") show the official app always creates one
  /// separate, real, independently-visible waypoint object per route
  /// point FIRST, then references them by uuid:
  /// `"points":[{"lon":...,"lat":...,"ref":{"class":"uwpt","uuid":"..."}}]`
  /// — never raw coordinates. That's a real app UX quirk (every route you
  /// create there also litters the waypoint list with one hidden-looking
  /// entry per point), not something this client should reproduce —
  /// confirmed by the plotter's own UI behaving the same way when a route
  /// is drawn directly on it (no extra waypoints appear either). This
  /// method instead sends `points` with embedded `lon`/`lat` directly, no
  /// `ref`/`uuid` — a guess with no real-capture precedent when first
  /// written, but the live test above confirms the plotter accepts it: a
  /// 3-point route created and durably found in the catalog afterward,
  /// with no corresponding entries added to the waypoint catalog.
  ///
  /// **Not yet tested**: larger point counts (only 3 points tried so far),
  /// and updating an existing route (only create tried so far — this
  /// method always generates a fresh uuid unless one is passed in, same
  /// caveat as [addOrUpdateWaypoint]'s own `uuid` parameter).
  Future<String> addOrUpdateRoute(
    String name,
    List<(double lat, double lon)> points, {
    String? uuid,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final targetUuid = uuid ?? _formatUuid(_randomUuidBytes());
    final random = Random();
    final objectVstamp = (2 << 32) | random.nextInt(0x100000000);

    final json = <String, dynamic>{
      'name': name,
      'uuid': targetUuid,
      'auto_name': false,
      'proto_ver': 2,
      'min_proto_ver': 1,
      'vstamp': objectVstamp,
      'points': [
        for (final (lat, lon) in points) {'lon': _toGarminSemicircle(lon), 'lat': _toGarminSemicircle(lat)},
      ],
    };

    // See [addOrUpdateWaypoint]'s doc comment for why this only syncs
    // when this connection doesn't already have a cached remote_ver for
    // the topic, rather than unconditionally re-syncing.
    final prevRemoteVer = _remoteVerByTopic[topicRoutes] ?? (await _fetchCatalog(topicRoutes, timeout: timeout)).remoteVer;
    final newRemoteVer = _freshRemoteVerLikeValue(prevRemoteVer);
    final body = _buildAddOrUpdateBody(
      uuid: targetUuid,
      vstamp: objectVstamp,
      json: json,
      prevRemoteVer: prevRemoteVer,
      newRemoteVer: newRemoteVer,
    );

    _send(topicRoutes, tDeleteEntry, 0, body);
    _remoteVerByTopic[topicRoutes] = newRemoteVer;
    return targetUuid;
  }

  /// Builds the shared tail structure [addOrUpdateWaypoint] and
  /// [addOrUpdateRoute] use — see [addOrUpdateWaypoint]'s doc comment for
  /// the full field-by-field wire format derivation.
  List<int> _buildAddOrUpdateBody({
    required String uuid,
    required int vstamp,
    required Map<String, dynamic> json,
    required Uint8List prevRemoteVer,
    required Uint8List newRemoteVer,
  }) {
    final gzipBlob = _gzipEncode(utf8.encode(jsonEncode(json)));
    final vstampBytes = _buildAddOrUpdateVstampField(vstamp);
    final uuidBytes = _parseUuid(uuid);

    // **Corrected 2026-08-11** after the previous version's `02 19 01 27`
    // "fixed marker" turned out to actually be TWO separate tagged fields
    // this method was never sending on purpose — `proto_ver` (tag `0x11`)
    // and `min_proto_ver` (tag `0x19`) — that happened to look like a fixed
    // 4-byte marker only because this method's own hardcoded `proto_ver:
    // 2, min_proto_ver: 1` JSON values are so small their LEB128 encoding
    // is exactly one byte each, coincidentally matching the real capture's
    // literal bytes even though the actual field boundaries were wrong. A
    // fifth (envelope-level) present-field count of 5 covers: uuid,
    // vstamp, proto_ver, min_proto_ver, and a nested nested-catalog-style
    // "wpt_data" field wrapping the gzip blob — confirmed by decoding the
    // real capture field-by-field with each field's own `(fieldId << 3) |
    // lebLen`-shaped tag: uuid=`07`(fieldId 0, overflow), vstamp=`0d`
    // (fieldId 1, lebLen 5), proto_ver=`11` (fieldId 2, lebLen 1),
    // min_proto_ver=`19` (fieldId 3, lebLen 1), wpt_data=`27` (fieldId 4,
    // overflow) — this message's fields are 0-indexed on the wire.
    const presentFieldCount = 5;
    final protoVerBytes = _buildAddOrUpdateTaggedIntField(fieldId: 2, value: (json['proto_ver'] as int));
    final minProtoVerBytes = _buildAddOrUpdateTaggedIntField(fieldId: 3, value: (json['min_proto_ver'] as int));
    // `wpt_data`'s own tag byte (`(4 << 3) | 7` — the same overflow-marker
    // shape [uuid]'s own `07` tag uses), then a LEB128 overflow-length
    // vint, then the SAME `02 01 00 0f` [_memberLengthMarker] the download
    // side's [_readMemberLengthFromHeader] already knows, then two more
    // LEB128 values — `gzLen+2`, then the exact `gzLen` — the same "two
    // LEB128 values, the second is the real length" shape as that
    // download-side header. Confirmed on every real create capture.
    final wptDataOverflowLen = _encodeUnsignedLeb128(gzipBlob.length + 8);
    final fieldTable = <int>[
      presentFieldCount,
      0x07, 0x11, 0x10, // uuid field tag/overflow-size/length prefix
      ...uuidBytes,
      ...vstampBytes,
      ...protoVerBytes,
      ...minProtoVerBytes,
      (4 << 3) | 7,
      ...wptDataOverflowLen,
      ..._memberLengthMarker,
      ..._encodeUnsignedLeb128(gzipBlob.length + 2),
      ..._encodeUnsignedLeb128(gzipBlob.length),
      ...gzipBlob,
    ];

    // B = self-referential byte-distance from the tail's own end back to
    // fieldTable's start — see [addOrUpdateWaypoint]'s doc comment for
    // why this isn't the same fixed formula [_rteDelMsgTagPrefix] uses.
    // Solved the same fixed-point way [_solveSelfReferentialLeb128Length]
    // solves the outer tag: `B`'s own LEB128 width is part of what it's
    // counting.
    final bEstimate = fieldTable.length + _encodeUnsignedLeb128(fieldTable.length).length;
    final b = _solveSelfReferentialLeb128Length(bEstimate);
    final bBytes = _encodeUnsignedLeb128(b);
    final a = b + bBytes.length + 1;

    // **Bug found 2026-08-12** via a strict byte-by-byte re-derivation of
    // this marker against four real create frames across two fresh
    // captures (`bb58f5ed`, `4fdcc705`) — every one of them has `0x01`
    // here, not `0x02`. Confirmed via the `a = b + lebLen(b) + 1` identity
    // holding exactly in every real frame once the byte at this position
    // is excluded from `b`'s own encoding (it isn't part of `b`'s LEB128 —
    // `b`'s bytes start right after it, same as this method already
    // assumed). This one wrong byte, sent on every single previous live
    // attempt, is the most likely real explanation for why the message
    // always sent successfully (byte count/self-referential lengths all
    // still checked out) but the plotter never durably added the object —
    // it's plausible this second-position marker actually carries some
    // meaning (unconfirmed what) that the plotter validates.
    final tail = <int>[
      0x01, 0x07,
      ..._encodeUnsignedLeb128(a),
      0x01,
      ...bBytes,
      ...fieldTable,
    ];
    final tailLenBytes = _encodeUnsignedLeb128(tail.length);
    final restAfterTag = <int>[
      ...prevRemoteVer,
      ...newRemoteVer,
      ...tailLenBytes,
      ...tail,
    ];
    final totalLengthEstimate = restAfterTag.length + _encodeUnsignedLeb128(restAfterTag.length).length;
    final tagValue = _solveSelfReferentialLeb128Length(totalLengthEstimate);
    return <int>[
      ..._encodeUnsignedLeb128(tagValue),
      ...restAfterTag,
    ];
  }

  /// The object-own-`vstamp` field: same tagged-field convention as
  /// [_buildAddOrUpdateTaggedIntField] — tag byte `(fieldId << 3) |
  /// lebLen` followed by [vstamp]'s own unsigned LEB128 encoding at
  /// whatever width it naturally takes, no padding. `vstamp` is
  /// field 1, so the tag is `0x08 | lebLen`. Unlike [_buildDeleteTrailer]'s
  /// `del_vstamp`, this is NOT incremented — it's the object's own
  /// current/starting vstamp verbatim.
  List<int> _buildAddOrUpdateVstampField(int vstamp) {
    // _encodeUnsignedLeb128 assumes a non-negative value and loops forever
    // on a negative one (right-shifting a negative Dart int sign-extends,
    // so it never reaches zero) — caught live 2026-08-11 when a caller
    // passed a `(seq << 32) | sub` vstamp whose `seq` alone was large
    // enough to overflow into bit 63, silently producing a negative
    // 64-bit int and hanging mid-send instead of failing cleanly.
    if (vstamp < 0) {
      throw RouteCatalogException('vstamp $vstamp is negative — likely an overflowed (seq << 32) | sub construction');
    }
    return _buildAddOrUpdateTaggedIntField(fieldId: 1, value: vstamp);
  }

  /// Builds a small tagged integer field — tag byte `(fieldId << 3) |
  /// lebLen`, same convention every other field tag in this message uses
  /// (see [_buildAddOrUpdateVstampField]'s doc comment for the general
  /// shape), followed by [value]'s own unsigned LEB128 encoding at
  /// whatever width it naturally takes (no fixed-width padding, unlike
  /// the vstamp field). Used for `proto_ver`/`min_proto_ver`, which are
  /// always small values (1-2 in every real capture) — this throws if
  /// [value] ever needs more than 1 LEB128 byte, since a `lebLen` above 7
  /// would collide with the "overflow, size given separately" marker
  /// shape [uuid]'s own tag uses, which this simple helper doesn't
  /// implement.
  List<int> _buildAddOrUpdateTaggedIntField({required int fieldId, required int value}) {
    final varint = _encodeUnsignedLeb128(value);
    if (varint.length > 6) {
      throw RouteCatalogException('value $value for field $fieldId needs a longer encoding than this helper supports');
    }
    return <int>[(fieldId << 3) | varint.length, ...varint];
  }

  /// A fresh random 16-byte value for a newly-created object's own uuid —
  /// same shape as `route_sync.dart`'s per-waypoint uuid (this file has no
  /// dependency on that one beyond the shared [RoutePoint] type, so it's
  /// not reused directly).
  static Uint8List _randomUuidBytes() {
    final rnd = Random();
    return Uint8List.fromList(List<int>.generate(16, (_) => rnd.nextInt(256)));
  }

  /// Converts plain degrees to Garmin's semicircle `int32` encoding — same
  /// formula as `route_sync.dart`'s `_toSemicircle`, duplicated here since
  /// this file has no dependency on that one beyond the shared
  /// [RoutePoint] type (see this file's `export` statement).
  static int _toGarminSemicircle(double degrees) {
    const scale = 2147483648.0 / 180.0; // 2^31 / 180
    return (degrees * scale).round();
  }

  /// Converts [time] to seconds since the Garmin/GPS epoch
  /// (1989-12-31T00:00:00Z) — same formula as `route_sync.dart`'s
  /// `_waypointMetadataBlock`/`_garminEpochOffsetSeconds`, duplicated here
  /// for the same reason [_toGarminSemicircle] is.
  static int _garminEpochSeconds(DateTime time) {
    final garminEpoch = DateTime.utc(1989, 12, 31).millisecondsSinceEpoch ~/ 1000;
    return time.toUtc().millisecondsSinceEpoch ~/ 1000 - garminEpoch;
  }

  /// gzip-compresses [data] the same way the plotter's own object payloads
  /// are compressed — confirmed round-trippable against both real
  /// captured objects' JSON via [GZipCodec] (Dart's standard zlib-backed
  /// implementation), not a custom encoder.
  static Uint8List _gzipEncode(List<int> data) {
    return Uint8List.fromList(GZipCodec().encode(data));
  }

  /// **Diagnostic only, added 2026-08-09** — sends an arbitrary
  /// route/waypoint-change message on [topic] using this connection's own fresh
  /// `prevRemoteVer`/`newRemoteVer` (same envelope construction
  /// [deleteEntry] uses — the self-referential LEB128 length header,
  /// `seq = cached remote_ver's seq + 1`), with [tail] as the inner
  /// change-message payload verbatim. Exists purely to
  /// test whether THIS client's writes are ignored specifically for
  /// deletes, or for every write on this channel — by replaying a real
  /// captured non-delete `rte_change` (e.g. a waypoint update) byte-for-
  /// byte, with only the envelope's version-stamp fields regenerated
  /// fresh for this connection. Requires [_remoteVerByTopic] to already
  /// have a cached value for [topic] (call [fetchCatalog] on it first).
  Future<void> debugSendRteChange(int topic, List<int> tail) async {
    final prevRemoteVer = _remoteVerByTopic[topic];
    if (prevRemoteVer == null) {
      throw RouteCatalogException('no cached remote_ver for topic 0x${topic.toRadixString(16)} — call fetchCatalog first');
    }
    final newRemoteVer = _freshRemoteVerLikeValue(prevRemoteVer);
    final tailLenBytes = _encodeUnsignedLeb128(tail.length);
    final restAfterTag = <int>[
      ...prevRemoteVer,
      ...newRemoteVer,
      ...tailLenBytes,
      ...tail,
    ];
    final totalLengthEstimate = restAfterTag.length + _encodeUnsignedLeb128(restAfterTag.length).length;
    final tagValue = _solveSelfReferentialLeb128Length(totalLengthEstimate);
    final body = <int>[
      ..._encodeUnsignedLeb128(tagValue),
      ...restAfterTag,
    ];
    _send(topic, tDeleteEntry, 0, body);
    _remoteVerByTopic[topic] = newRemoteVer;
  }

  /// A fresh 8-byte value shaped like the `newRemoteVer` half of a real
  /// delete message.
  ///
  /// **Corrected again 2026-08-09**, after a byte-for-byte comparison of
  /// all 6 real captured deletes' `prevRemoteVer`/`newRemoteVer` pairs
  /// (extracted straight from the pcaps, not re-derived) found a pattern
  /// the previous version of this doc comment explicitly said was ruled
  /// out: **`newRemoteVer`'s `seq` (upper 32 bits) is `prevRemoteVer`'s
  /// own `seq` plus exactly 1, in all 6 captures, no exceptions**
  /// (983->984, 921->922, 910->911, 868->869, 870->871, 869->870). The
  /// earlier conclusion ("differs by billions, not `prevRemoteVer + 1`")
  /// was comparing the two values as single 64-bit integers — a `seq`
  /// packed into the *upper* 32 bits means even a `+1` there moves the
  /// whole 64-bit value by roughly 2^32, which reads as "differs by
  /// billions" if you don't split `seq`/`sub` apart before comparing.
  /// **`sub`'s bit layout — fully resolved 2026-08-09**, by comparing the
  /// raw bits of `sub` across all 6 captured deletes at every candidate
  /// split point. The layout that fits every sample without exception:
  /// ```
  /// bits[0:8)   1 random byte (differs every capture)
  /// bits[8:12)  product number (constant 0 in every capture)
  /// bits[12:32) unit id (20 bits, constant per device across a capture)
  /// bits[32:64) seq (prevRemoteVer's own seq + 1)
  /// ```
  /// This confirms the bit positions this code already used (`sub =
  /// randByte | unitId<<12`) are exactly right, AND that the 4-bit
  /// product-number field (bits 8-12, left as 0 here — no real Garmin
  /// product number is known) really is `0` in every real capture's own
  /// `sub` field, checked directly (not just assumed): all 6 captures
  /// have `(sub>>8)&0xF == 0`. What's genuinely NOT resolvable this way:
  /// the device unit id is populated at runtime from real device
  /// identity/hardware, which this library — not a real Garmin unit —
  /// has no legitimate value for. [_clientUnitId] (an arbitrary
  /// process-lifetime-stable value, or [debugClientUnitId] if set) is
  /// the best available stand-in: the *mechanism* is now proven correct,
  /// only the specific 20-bit identity value is necessarily a guess.
  /// `seq` itself is unrelated to this and IS solid: [prevRemoteVer]'s
  /// own `seq` incremented by 1, matching every real capture exactly
  /// (replacing [_nextCorrelationId]'s independent, `0xfe`-based
  /// [_syncVerStampSeq] counter, which was the wrong source for this
  /// specific field).
  Uint8List _freshRemoteVerLikeValue(Uint8List prevRemoteVer) {
    final prevValue = ByteData.sublistView(prevRemoteVer).getUint64(0, Endian.little);
    final seq = (prevValue >> 32) + 1;
    final randByte = Random().nextInt(0x100);
    final sub = (randByte & 0xFF) | ((_clientUnitId & 0xFFFFF) << 12);
    final value = (seq << 32) | sub;
    final out = Uint8List(8);
    ByteData.view(out.buffer).setUint64(0, value, Endian.little);
    return out;
  }

  /// Builds [deleteEntry]'s `01 07 <A> 03 <B>` prefix — **root cause of
  /// every prior live delete failure, found 2026-08-09** via a targeted
  /// analysis of the real delete message's serialized output with several
  /// `del_vstamp` values chosen for
  /// distinct LEB128 lengths (1, 2, 5, 10 bytes). **This was never a
  /// session-local counter at all** — the earlier `B = A - 2` observation
  /// (across only 4 real captures, all of which happened to carry a
  /// similarly-sized `del_vstamp`) was a coincidence of too small a
  /// sample, not a real invariant. `01 07` is fixed (a field-count/tag
  /// marker emitted once per message, constant across every tested run
  /// regardless of `del_vstamp`), but **`A` and `B` are NOT constant or
  /// incrementing — they are `23 + lebLen` and `21 + lebLen`**, where
  /// `lebLen` is the exact byte length of `del_vstamp`'s own LEB128
  /// encoding (confirmed byte-for-byte across all 4 tested lengths: 1
  /// byte -> `18 03 16`, 2 bytes -> `19 03 17`, 5 bytes -> `1c 03 1a`, and
  /// the relationship holds even at 10 bytes once the tag's own overflow
  /// encoding is accounted for). This is the message-serialization
  /// framework's own
  /// cumulative-byte-position bookkeeping leaking into the wire format —
  /// i.e. these bytes describe how big the *rest of this specific
  /// message* is, not an arbitrary session/connection counter. Using a
  /// stale/guessed counter here — as every previous version of this
  /// method did — produces a message whose declared internal size
  /// disagrees with its actual size, which is a very plausible reason the
  /// plotter silently ignored every previous delete attempt without ever
  /// sending an explicit rejection.
  ///
  /// [vstampLebLen] is `null` when [debugOmitVstampTrailer]/no known
  /// vstamp means the `del_vstamp` field is omitted entirely from this
  /// message — untested against a real capture (every real capture seen
  /// so far always carries `del_vstamp`), so this falls back to treating
  /// the field as 0 bytes long, matching the tested all-zero-length
  /// case structurally but not independently confirmed live.
  List<int> _rteDelMsgTagPrefix(int? vstampLebLen) {
    final lebLen = vstampLebLen ?? 0;
    return <int>[0x01, 0x07, 23 + lebLen, 0x03, 21 + lebLen];
  }

  /// See [deleteEntry]'s doc comment: this is the `del_vstamp` field, a
  /// tagged unsigned LEB128 varint — **solved 2026-08-08** via targeted
  /// reverse engineering, not a checksum. [lastKnownVstamp] is the object's own
  /// `"vstamp"` value from its `tGetObjectReply` JSON (see
  /// [DownloadedObject.vstamp]'s doc comment) or its catalog-entry trailer
  /// (see [CatalogEntry.vstamp]) — the object's version *before* this
  /// delete. **`del_vstamp` itself is NOT that value** — it's a freshly
  /// incremented one, built by [_incrementVstamp]. If null (the object had
  /// no known prior vstamp), `del_vstamp` is omitted entirely — it's a
  /// genuinely optional field (every real capture with it omitted still
  /// parses as a structurally valid message, not just "presumed
  /// skippable"), so omitting it produces a structurally valid, just
  /// shorter, message rather than a guessed/placeholder value.
  ///
  /// **Tag byte corrected 2026-08-09**, found by comparing this library's
  /// own sent bytes against the freshest real capture's actual delete
  /// frame byte-for-byte: the tag was `lebLen` alone (e.g. `0x05` for a
  /// 5-byte LEB128 value), matching `fieldId=0` — but that collides with
  /// the mandatory uuid field, which is ALSO `fieldId=0` (its own tag byte
  /// is `0x07` = `(0<<3)|7`, per [deleteEntry]'s doc comment). The real
  /// capture's del_vstamp tag byte was `0x0d` for that same 5-byte LEB128
  /// value — `0x0d = (1<<3)|5`, i.e. `del_vstamp` is `fieldId=1` (the
  /// field immediately after uuid in the delete message's field list), and the tag
  /// is `(fieldId << 3) | lebLen`, exactly the same shape as the uuid
  /// field's own tag byte — not a bare length byte at all. Sending
  /// `fieldId=0` here made this field indistinguishable from (or a
  /// malformed duplicate of) the uuid field from the plotter's decoder's
  /// perspective, the most likely reason every previous live delete with a
  /// present `del_vstamp` was silently ignored despite an otherwise
  /// byte-perfect message.
  List<int> _buildDeleteTrailer(int? lastKnownVstamp) {
    if (lastKnownVstamp == null) return const <int>[];
    final varint = _encodeUnsignedLeb128(_incrementVstamp(lastKnownVstamp));
    return <int>[(1 << 3) | varint.length, ...varint];
  }

  /// Increments a plotter-format vstamp the same way a real delete's
  /// `del_vstamp` relates to the object's prior vstamp — **found
  /// 2026-08-08** after a real captured `del_vstamp` (30372247711) turned
  /// out to match NEITHER the object's `tCatalogSyncReply` trailer vstamp
  /// (94953779498) NOR its `tGetObjectReply` JSON vstamp (26234302762) —
  /// ruling out "just reuse the last known vstamp verbatim".
  ///
  /// The plotter's vstamp is not a plain integer: it's a packed bitfield
  /// (routes/waypoints use a 32-bit `seq` and a 32-bit `sub` — confirmed by
  /// comparing several real vstamps bit-by-bit), packed as:
  /// ```
  /// vstamp = (seq << 32) | sub
  /// ```
  /// A real delete's `del_vstamp` increments
  /// `seq` by exactly 1 relative to the object's prior vstamp and replaces
  /// `sub` with a **freshly randomized** 32-bit value each time. Verified
  /// against the real capture: the object's last-known vstamp (from `tGetObjectReply`) had
  /// `seq=6`, and the delete's own `del_vstamp` had `seq=7` — an exact
  /// `+1` match — while `sub` changed to an unrelated value (464498986 ->
  /// 307476639), consistent with a fresh random draw that cannot be
  /// reproduced. Reusing a real, unrelated random 32-bit value for `sub`
  /// here is therefore not a guess of the "right" value (there isn't one
  /// to find) but a faithful re-implementation of what the real app does.
  int _incrementVstamp(int vstamp) {
    final seq = (vstamp >> 32) & 0xFFFFFFFF;
    final newSeq = (seq + 1) & 0xFFFFFFFF;
    final newSub = _vstampRandom.nextInt(0x100000000);
    return (newSeq << 32) | newSub;
  }

  static final Random _vstampRandom = Random();

  /// Standard unsigned LEB128: 7 payload bits per byte, low-order group
  /// first, continuation bit (0x80) set on every byte but the last.
  static List<int> _encodeUnsignedLeb128(int value) {
    final out = <int>[];
    var v = value;
    while (true) {
      final byte = v & 0x7f;
      v >>= 7;
      if (v != 0) {
        out.add(byte | 0x80);
      } else {
        out.add(byte);
        break;
      }
    }
    return out;
  }

  /// Solves `value = restLength - lebByteLength(value)` for `value` —
  /// [deleteEntry]'s `body[0]` field (see its doc comment): a LEB128 vint
  /// that encodes the byte length of everything *after* itself in the
  /// message, where "everything after itself" includes this field's own
  /// encoded width. LEB128 byte-length only changes at powers of 128
  /// (1 byte for values < 128, 2 bytes for < 16384, etc.), so a small
  /// fixed-point iteration converges immediately in practice — starting
  /// from `restLength` (an overestimate of `value`, since `value` must be
  /// slightly smaller to leave room for its own encoding) and repeatedly
  /// re-deriving `value` from the current byte-length guess stabilizes as
  /// soon as the guessed byte-length matches the real one, which happens
  /// well within a handful of iterations for any realistic message size.
  static int _solveSelfReferentialLeb128Length(int restLength) {
    var value = restLength;
    for (var i = 0; i < 4; i++) {
      final candidate = restLength - _encodeUnsignedLeb128(value).length;
      if (candidate == value) break;
      value = candidate;
    }
    return value;
  }

  /// Combines [fetchCatalog] and [fetchObjects] into one call that never
  /// returns control to the caller in between — sends the batch
  /// [tGetObject] immediately after the [tCatalogSync] merge completes,
  /// on the same event-loop turn's `async` chain, instead of the caller
  /// getting the catalog back, doing its own thing, and calling
  /// [fetchObjects] later.
  ///
  /// **Added 2026-08-06** after live-testing found that a
  /// [fetchCatalog]-then-[fetchObjects] pair, called as two separate
  /// `await`ed steps from `bin/helm_cli.dart`, got an explicit
  /// [tGetObjectError] back from a real plotter — even though the batch
  /// request's bytes were, in every way examined at the time, byte-for-
  /// byte correct.
  ///
  /// **Root cause found 2026-08-06: the batch request's 8-byte
  /// "correlation id" isn't freely chosable — it must be the exact
  /// `remote_ver` the server assigned in the preceding [tCatalogSync]'s
  /// reply.** See [_syncCatalog]'s doc comment for the full derivation
  /// (comparing several real captures showed any value other than a
  /// specific plotter-supplied one reliably gets rejected, then confirming
  /// byte-for-byte in a real capture which
  /// field of [tCatalogSyncReply] that `remote_ver` actually is). Three
  /// other hypotheses were tried and live-ruled-out along the way:
  /// removing the dart-level `await` gap between [fetchCatalog] and
  /// [fetchObjects] (this function's original reason for existing);
  /// syncing all three registered topics (`0x4`, [topicWaypoints],
  /// [topicRoutes]) via [tCatalogSync] before touching any of their
  /// batch [tGetObject]s; and — the closest false lead — replaying `0x4`'s
  /// *own* full sync-then-batch-download cycle too (matching what a real
  /// capture shows the app doing), which got a real ~80KB reply for
  /// `0x4` but turned out to make the *target* topic's own request fail
  /// unpredictably on a freshly reset/restarted real plotter (`0x4`'s
  /// sync would sometimes never get a reply at all, even with a 60s
  /// timeout). [_fetchCatalog] no longer replays `0x4`'s cycle by default
  /// (see [debugSyncOtherTopics]) — turning it off, combined with the
  /// `remote_ver` fix and generous timeouts (see [fetchCatalog]'s own
  /// doc comment), is what finally got this confirmed working live
  /// end-to-end for the target topic itself: 3, 5, then 20 real
  /// [topicWaypoints] uuids, and separately 5 real [topicRoutes] uuids
  /// (with real multi-point routes — 10 to 79 points each, not just the
  /// single-point waypoints — decoding correctly too), all succeeded
  /// with real names and points.
  ///
  /// [objectsLimit], if given, caps how many of the catalog's uuids are
  /// requested (for cautious/incremental live testing — see
  /// `bin/helm_cli.dart`'s `--fetch-objects-limit`) without reintroducing
  /// an `await` gap: the cap is applied to the same in-flight uuid list,
  /// still inside this one unbroken call.
  ///
  /// **Uses [fetchObjectsChunked], not [fetchObjects], since 2026-08-13**
  /// — see [fetchObjectsChunked]'s own doc comment: an unchunked batch for
  /// a topic this size (currently 64 real routes) was live-confirmed to
  /// reset the connection. [chunkSize] is exposed so cautious/incremental
  /// live testing (same reasoning as [objectsLimit]) can probe smaller
  /// values before trusting the default.
  ///
  /// [knownEntries], if given (non-null, non-empty), makes the sync
  /// non-empty/differential — see [_buildCatalogSyncBody]'s doc comment.
  /// **The reply is still parsed as the plotter's full current view of the
  /// topic, same as the N=0 path** — confirmed via a real capture
  /// (`0d2f840f`) where a non-empty sync's reply still listed every known
  /// entry, not a minimal delta; the benefit of passing [knownEntries] is
  /// presumed to be letting the plotter skip recomputing its own digest
  /// from scratch, not a smaller/different reply shape this method would
  /// need to handle differently.
  Future<List<DownloadedObject>> fetchCatalogAndObjects(
    int topic, {
    Duration catalogTimeout = const Duration(seconds: 30),
    Duration objectsTimeout = const Duration(seconds: 60),
    int? objectsLimit,
    int chunkSize = 10,
    List<CatalogEntry>? knownEntries,
  }) async {
    final sync = await _fetchCatalog(topic, timeout: catalogTimeout, knownEntries: knownEntries);
    if (sync.entries.isEmpty) return const [];
    final uuids = sync.entries.map((e) => e.uuid);
    final limited = objectsLimit != null ? uuids.take(objectsLimit) : uuids;
    return fetchObjectsChunked(topic, limited.toList(), remoteVer: sync.remoteVer, chunkSize: chunkSize, timeout: objectsTimeout);
  }

  /// Debug/investigation helper: sends a [tCatalogSync] with explicitly
  /// chosen raw header field values (the old, now-superseded fieldA/
  /// fieldB/fieldC framing this file used before its real envelope
  /// structure was understood — see [fetchCatalog]'s doc comment and this
  /// file's top doc comment for the current, capture-derived payload). Kept
  /// only as a low-level knob for `bin/helm_cli.dart` to poke arbitrary
  /// raw bytes at a real plotter for further investigation, not because
  /// this framing is believed correct. Returns the raw reply bytes (or
  /// throws on timeout/connection close), leaving interpretation to the
  /// caller.
  Future<Uint8List> debugSendRawCatalogSync(
    int topic, {
    required int fieldA,
    required int fieldB,
    required int fieldC,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await _ensurePreamble(timeout);
    _registerTopic(topicWaypoints);
    _registerTopic(topicRoutes);
    final correlationId = _nextCorrelationId();
    final rest = <int>[
      ...correlationId,
      fieldB & 0xff, (fieldB >> 8) & 0xff,
      fieldC & 0xff, (fieldC >> 8) & 0xff,
    ];
    final sub = _autoReplyToServerGetObject(topic);
    try {
      _send(topic, tCatalogSync, 2, rest, lengthOverride: fieldA);
      final reply = await _awaitCatalogSyncReply(topic, correlationId, timeout);
      return reply.rest;
    } finally {
      await sub.cancel();
    }
  }

  /// Debug/investigation helper: replays a full, real captured [tCatalogSync]
  /// `rest` payload (everything after `[topicId][msgType]` on the wire,
  /// including the outer length field) verbatim, only patching in a fresh
  /// correlation id at byte offset 2 (right after the 2-byte length field —
  /// matches every real request examined). This is how the real, non-empty
  /// digest replay documented at the top of this file was originally
  /// confirmed working live. Not used by [fetchCatalog] itself, which now
  /// sends its own capture-derived N=0 payload directly (see [fetchCatalog]'s
  /// doc comment) rather than replaying a captured non-empty one.
  Future<Uint8List> debugReplayRawCatalogSync(
    int topic,
    Uint8List capturedRest, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await _ensurePreamble(timeout);
    _registerTopic(topicWaypoints);
    _registerTopic(topicRoutes);
    final correlationId = _nextCorrelationId();
    final patched = Uint8List.fromList(capturedRest);
    patched.setRange(2, 10, correlationId);
    final lengthField = ByteData.sublistView(patched, 0, 2).getUint16(0, Endian.little);

    final sub = _autoReplyToServerGetObject(topic);
    try {
      _send(topic, tCatalogSync, 2, patched.sublist(2), lengthOverride: lengthField);
      final reply = await _awaitCatalogSyncReply(topic, correlationId, timeout);
      return reply.rest;
    } finally {
      await sub.cancel();
    }
  }

  /// Fetches one object's full data ([topic] must match whichever catalog
  /// [uuid] came from) and decodes it into a [DownloadedObject].
  ///
  /// Unlike [fetchCatalog], this awaits the registration reply before
  /// sending [tGetObject] — that's the sequencing this function was
  /// originally confirmed working live against a real plotter with, and
  /// there's no capture evidence (unlike for [fetchCatalog]) that this
  /// blocking order is actually wrong, so it's left alone here.
  ///
  /// **Bug fixed 2026-08-06**: that wait used to run unconditionally, even
  /// when [topic] was already registered (e.g. by an earlier [fetchCatalog]
  /// or [fetchObject] call on the same connection — [_registerTopic] is a
  /// no-op then). The plotter only ever sends one registration reply per
  /// topic per connection, so calling [fetchObject] repeatedly after
  /// [fetchCatalog] (the exact "download every entry" pattern this
  /// function exists for) made every call past the first hang until the
  /// timeout with "no reply from the plotter" — confirmed live against a
  /// real plotter's full waypoint catalog, every single entry failing the
  /// same way. Only wait for the registration reply on the first
  /// registration of this topic on this connection.
  ///
  /// **Second bug fixed 2026-08-07**: this request's own "correlation id"
  /// field is the exact same `01 01 01 01 07 11 10`-vs-`01 07 11 10`
  /// marker shape [fetchObjects]'s doc comment describes for its batch
  /// [tGetObject] — a single-uuid request is literally the `n=1` case of
  /// that same wire format — which means the same fix applies: that
  /// field must be the server-assigned `remote_ver` from the most recent
  /// [tCatalogSync] on [topic], not a freely-chosen value. This function
  /// used [_nextCorrelationId] here until now, which worked in isolated
  /// live testing (called right after a fresh preamble, before any
  /// [tCatalogSync] had run) but got a live, real [tGetObjectError]
  /// ("plotter rejected the request ... stale/invalid uuid") once called
  /// after [fetchCatalog] had already synced [topic] and moved the
  /// plotter's own version state forward — the exact pattern a route
  /// catalog browsing UI naturally hits (list the catalog, then fetch
  /// individual objects on demand). Now uses [_remoteVerByTopic]'s cached
  /// value for [topic] if this connection has done a [tCatalogSync] on it
  /// already (via [fetchCatalog] or an earlier [fetchObject] — both keep
  /// the cache updated); if not, runs one first so a working `remote_ver`
  /// exists before the actual object request.
  /// Registers [topic] (waiting for the reply only the first time — see
  /// [fetchObject]'s doc comment) and makes sure [_remoteVerByTopic] has
  /// an entry for it (running one [_syncCatalog] if not), so [topic] is
  /// fully ready for a [tGetObject]. Only ever run once per topic per
  /// connection even under concurrent callers — see
  /// [_syncInFlightByTopic]'s doc comment for why that matters and how
  /// callers share this via [_syncInFlightByTopic].
  Future<void> _ensureTopicReady(int topic, Duration timeout) async {
    final alreadyRegistered = _registeredTopics.contains(topic);
    _registerTopic(topic);
    if (!alreadyRegistered) {
      try {
        await _messages.stream
            .firstWhere((m) => m.topicId == topic && (m.msgType == 0x0a || m.msgType == 0x09))
            .timeout(timeout, onTimeout: () => throw const RouteCatalogException('no reply from the plotter'));
      } on StateError {
        throw const RouteCatalogException('connection to the plotter closed before a reply arrived');
      }
    }
    if (!_remoteVerByTopic.containsKey(topic)) {
      await _syncCatalog(topic, _catalogSyncN0Tail, timeout: timeout);
    }
  }

  /// Queues [body] as the next [fetchObject] request on [topic], running it
  /// only after every earlier-queued request on the same topic has gotten
  /// its reply (or failed) — see [_getObjectQueueByTopic]'s doc comment for
  /// why serializing this matters, not just the one-time registration/sync
  /// that [_syncInFlightByTopic] already covers.
  ///
  /// **Bug found and fixed 2026-08-07**: [fetchObject]'s "correlation id"
  /// field is [_remoteVerByTopic]'s cached `remote_ver` for [topic] — the
  /// *same* value for every request on that topic, by design (see
  /// [_syncCatalog]'s doc comment). [_awaitGetObjectReply] matches a reply
  /// to its caller by `(topicId, correlationId)` alone, so two concurrent
  /// [fetchObject] calls for *different* uuids on the same topic send
  /// wire-identical correlation ids — whichever reply happens to arrive
  /// first can satisfy either caller's `firstWhere`, handing one caller the
  /// other's object (or leaving a caller to time out once its own reply is
  /// consumed by someone else). Live-observed 2026-08-07: fast-scrolling
  /// the catalog dialog (many rows' lazy [fetchObject] calls firing in a
  /// burst) reintroduced both wrong/missing names and the plotter's "User
  /// data sharing is disabled" lockout, even after [_syncInFlightByTopic]
  /// already fixed the earlier registration/sync race. The wire protocol
  /// has no per-request id finer than `remote_ver` to disambiguate
  /// concurrent replies on one topic, so the fix is to never have more than
  /// one [tGetObject] in flight per topic at all — this queue chains each
  /// new call's send+await after the previous one's completion.
  Future<T> _enqueueGetObject<T>(int topic, Future<T> Function() run) {
    final previous = _getObjectQueueByTopic[topic] ?? Future<void>.value();
    final result = previous.then((_) => run());
    // Swallow errors here only so the *queue* tail itself never completes
    // with an error (which would break every subsequent queued call on this
    // topic) — the real error/result still reaches this call's own caller
    // via the returned [result] future below.
    _getObjectQueueByTopic[topic] = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<DownloadedObject> fetchObject(
    int topic,
    String uuid, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await _ensurePreamble(timeout);
    // Registration-wait and remote_ver-sync are both single-shot,
    // exactly-one-reply-per-connection exchanges with the plotter (see
    // this function's own doc comment and [_syncInFlightByTopic]'s doc
    // comment) — sharing one in-flight future per topic across
    // concurrent callers (a catalog-browsing UI lazily fetching many
    // visible rows' names at once is the exact case this matters for)
    // makes every caller past the first just await the same result
    // instead of each independently racing to register/sync and
    // corrupting the exchange.
    await _syncInFlightByTopic.putIfAbsent(topic, () => _ensureTopicReady(topic, timeout));
    // The actual send+await must also be serialized per topic — see
    // _enqueueGetObject's doc comment for why concurrent requests on the
    // same topic can't be told apart by the reply-matching logic.
    return _enqueueGetObject(topic, () async {
      final remoteVer = _remoteVerByTopic[topic];
      final uuidBytes = _parseUuid(uuid);
      // One more length byte after the correlation id, confirmed in the
      // capture to be the byte count of everything that follows it (marker +
      // UUID = 7 + 16 = 23 = 0x17).
      final markerAndUuidLength = _getObjectRequestMarker.length + uuidBytes.length;
      _send(topic, tGetObject, 1, [
        ...?remoteVer,
        markerAndUuidLength,
        ..._getObjectRequestMarker,
        ...uuidBytes,
      ]);
      final reply = await _awaitGetObjectReply(topic, remoteVer ?? _nextCorrelationId(), timeout);
      if (reply.msgType == tGetObjectError) {
        throw RouteCatalogException('plotter rejected the request for $uuid (no such object, or a stale/invalid uuid)');
      }

      final gzipStart = _findBytes(reply.rest, const [0x1F, 0x8B, 0x08]);
      if (gzipStart < 0) {
        throw const RouteCatalogException('object reply had no gzip payload');
      }
      return _decodeObjectJson(reply.rest.sublist(gzipStart), fallbackUuid: uuid);
    });
  }

  /// Fetches many objects at once ([topic] must match whichever catalog
  /// every uuid in [uuids] came from) — the same [tGetObject] the real app
  /// sends right after a [fetchCatalog] merge to bulk-download everything,
  /// instead of one [fetchObject] round trip per uuid.
  ///
  /// **Found and confirmed 2026-08-06** after [fetchObject] turned out to
  /// be unusable in a loop for a real 177-entry catalog (each call after
  /// the first hung until timeout — see [fetchObject]'s own doc comment
  /// for that bug). A real capture of the app's own post-sync behavior
  /// showed it never loops [fetchObject]; it sends one [tGetObject] whose
  /// body lists every uuid it wants. [fetchObject]'s single-uuid request
  /// turned out to be the `n=1` case of this exact same wire format, not a
  /// separate one — the two `01 01 01 01 07 11 10`-vs-`01 07 11 10` marker
  /// readings that looked like different formats in earlier analysis were
  /// the same bytes misread two different ways: `01 01` + a
  /// LEB128-encoded entry count, then that many `01 07 11 10`+uuid
  /// records. For `n=1` the count byte is `01`, which is why it looked
  /// like part of a longer fixed marker.
  ///
  /// The request's own two length fields are **LEB128 varints**, not the
  /// fixed-width length bytes used elsewhere in this file — reading them
  /// as `u16 LE` is what made this format look inconsistent across
  /// differently-sized real captures at first (two real (n, length)
  /// samples fit a *plausible-looking* linear regression with
  /// non-integer coefficients, which was the tell that the reading itself
  /// was wrong, not the model). Verified against real captured
  /// correlation ids and uuids for `n=75` and `n=118`, reproducing both
  /// captures' wire bytes exactly, then sweeping `n` from 0 to 5000
  /// (including every LEB128 byte-count boundary up to 5000) and
  /// confirming this Dart-side formula matches
  /// it at every single point.
  ///
  /// Wire format of `rest` (everything after `[topicId][msgType=0x0c]`):
  /// ```
  /// rest = leb128(len(A)) ++ A
  /// A    = correlationId(8) ++ leb128(len(B)) ++ B
  /// B    = 01 01 ++ leb128(uuids.length) ++ uuids.length × (01 07 11 10 ++ uuid(16))
  /// ```
  ///
  /// The reply is expected to bundle one gzip+JSON blob per requested
  /// uuid, back-to-back with no separator — confirmed in the same real
  /// capture (a 118-uuid request came back as exactly 118 concatenated
  /// gzip members in one [tGetObjectReply]). Entries that fail to decode
  /// (e.g. a uuid the plotter silently dropped) are skipped rather than
  /// failing the whole batch, since a partial result is more useful here
  /// than none — unlike [fetchObject], where a single bad reply should be
  /// visible to a caller fetching one specific known object.
  ///
  /// **Live-testing status (2026-08-06).** The request format IS
  /// confirmed byte-for-byte correct — reproduced against real captured
  /// uuids/correlation ids for `n=75` and `n=118`, matching exactly —
  /// and the reply-parsing path is confirmed correct against a real
  /// captured 118-object [tGetObjectReply] fixture
  /// (`test/fixtures/waypoints_batch_get_object_reply.bin`, all 118
  /// decode successfully in `fetchObjects`' own test).
  ///
  /// Getting a real reply also required two more fixes, both live-
  /// confirmed: (1) [remoteVer] — the request's own 8-byte field is
  /// actually the server-assigned `remote_ver` from the most recent
  /// [tCatalogSync] on this topic, not a free-form correlation id (see
  /// this parameter's own doc note, and [_syncCatalog]'s doc comment for
  /// the full derivation); using a fresh [_nextCorrelationId] value
  /// there, as an early version of this file did, got an explicit
  /// [tGetObjectError] every time. (2) [_awaitGetObjectReply] itself had
  /// a latent bug — [tGetObjectError]'s body has no real correlation id
  /// (fixed `08 00 00 00 00 00 00 00 00`, like [tRegisterTopicReply]),
  /// so matching it against the sent correlation id silently never
  /// matched, turning a real, fast error reply into an apparent 30s
  /// "no reply from the plotter" timeout — fixed by matching
  /// [tGetObjectError] on topic alone.
  ///
  /// **Confirmed working live end-to-end, 2026-08-06.** With both fixes
  /// above, [debugSyncOtherTopics] off (see its own doc comment — `0x4`'s
  /// sync turned out to be actively harmful against a real plotter, not
  /// helpful), and long-enough timeouts (see [fetchCatalog]'s doc
  /// comment), a live batch download for [topicWaypoints] returned real,
  /// correctly-decoded objects (names and points) — first for 3 uuids,
  /// then 5, then 20, all succeeding cleanly and quickly on a fresh
  /// connection with no errors.
  ///
  /// One earlier live attempt (before the fixes above) asked for all
  /// 177 real waypoint uuids at once and got no reply within 30s, and —
  /// separately, importantly — that single timeout then made the real
  /// plotter stop replying to **any** request on **any** new connection
  /// (including a plain, previously-working [fetchCatalog] call) for
  /// 15-20+ minutes afterward. This matches the same family of
  /// protective behavior as the "User data sharing is disabled" screen
  /// from earlier in this investigation (see this file's top doc
  /// comment), just without the visible error screen — see the memory
  /// system's `plotter-timeout-lockout` note for the full incident and
  /// the recommended live-testing protocol (small `n` first, generous
  /// timeouts, long gaps between attempts) going forward.
  ///
  /// **`remoteVer` is required, not optional in practice** — see
  /// [_syncCatalog]'s doc comment for why. It must be the exact 8 bytes
  /// [_syncCatalog] returned from the most recent [tCatalogSync] on
  /// [topic] on this same connection; passing anything else (including
  /// omitting it when this connection has never synced [topic] at all)
  /// gets an explicit [tGetObjectError] from a real plotter, confirmed
  /// live 2026-08-06.
  ///
  /// **Falls back to [_remoteVerByTopic]'s cached value when omitted** —
  /// found live 2026-08-07 fixing a UI that (reasonably) calls plain
  /// [fetchCatalog] then this function as two separate steps (to show
  /// catalog-size progress in between — see `route_catalog_dialog.dart`)
  /// instead of [fetchCatalogAndObjects]: omitting [remoteVer] used to
  /// fall back to a fresh, self-chosen [_nextCorrelationId] value, which
  /// always got an explicit [tGetObjectError] back, "plotter rejected the
  /// batch object request" — [fetchObject] (the single-uuid path) already
  /// had this same fallback for the exact same reason; this function just
  /// hadn't needed it before now.
  Future<List<DownloadedObject>> fetchObjects(
    int topic,
    List<String> uuids, {
    Uint8List? remoteVer,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (uuids.isEmpty) return const [];
    // **No longer chunked — found live 2026-08-08.** This used to split
    // [uuids] into groups of 100 (re-syncing for a fresh `remoteVer`
    // between chunks), based on an earlier live test (2026-08-07) where a
    // 177-uuid single-batch waypoint request got no reply. That test's
    // real bug turned out to be something else entirely: the catalog can
    // list more raw entries than are real, individually-fetchable objects
    // (see [_syncCatalog]'s "real object count" doc comment) — this
    // topic's real waypoint count was 118, not 177, so that original test
    // was unknowingly asking for 59 non-existent objects mixed in with the
    // real ones. Once [_syncCatalog] started trimming to the real count,
    // a genuine 118-uuid single batch (no chunking) succeeded live —
    // matching the real captured app's own behavior, which also never
    // chunks (its own real capture sent all 118 real waypoint uuids in
    // one request). Chunking was actually the newly-introduced bug: the
    // re-sync-and-continue step for a second chunk got no reply at all in
    // live testing, every time — the plotter apparently cannot handle a
    // second batch tGetObject on the same topic on the same connection,
    // chunked or not, which chunking existing at all was masking as
    // "batch too big" instead of surfacing directly.
    final reply = await _sendBatchGetObject(topic, uuids, remoteVer: remoteVer, timeout: timeout);
    // **Marks [topic] as merge-primed — added live 2026-08-11.** This batch
    // download IS the same merge-completion round-trip [deleteEntry]
    // itself runs to prime [topic] before its own first delete (see
    // [deleteEntry]'s `_mergePrimedTopics` doc comment) — a caller (like
    // the catalog UI, which always calls [fetchCatalog] then this method
    // once per topic when a dialog opens) that already did this same work
    // shouldn't have to pay for it again inside [deleteEntry]. Without
    // this, a delete right after the UI finished loading a topic still
    // went through [deleteEntry]'s own full sync-and-batch-download path
    // (a second, separate round-trip of the exact same shape moments
    // after this one) — live-observed to reliably get "no reply from the
    // plotter" and eventually trip the plotter's protection screen, even
    // though the UI's own load had just succeeded cleanly. Marking [topic]
    // primed here lets a delete immediately after loading a tab take
    // [deleteEntry]'s fast path instead.
    _mergePrimedTopics.add(topic);
    // Splitting the gzip members apart and decoding each one (gzip inflate
    // + JSON parse + building every point) runs on a background isolate,
    // not the caller's own event loop — live-observed necessary: decoding
    // a single ~367KB/5000-point track object synchronously took long
    // enough that the OS itself flagged a Flutter UI built on top of this
    // as "not responding". [_decodeBatchReply] (the isolate entry point)
    // is a plain top-level function taking/returning only simple data
    // (Uint8List in, List<DownloadedObject> out) since isolate boundaries
    // can only cross with data, not closures over this connection's state.
    return Isolate.run(() => _decodeBatchReply(reply.rest));
  }

  /// Like [fetchObjects], but splits [uuids] into groups of at most
  /// [chunkSize], sending one batch [tGetObject] per group, sequentially,
  /// all reusing the same [remoteVer] (no re-sync between chunks — that
  /// exact approach was already tried and found broken live 2026-08-08,
  /// see [fetchObjects]'s own doc comment: a second batch tGetObject on an
  /// already-synced topic/connection reliably gets no reply at all,
  /// whether or not a resync precedes it). Exists because a single
  /// unchunked batch for **routes** (many embedded points per object,
  /// unlike single-point waypoints) was live-confirmed 2026-08-13 to
  /// reliably reset the connection outright at this catalog's real size
  /// (64 routes) — reproduced twice, isolated down to this exact request,
  /// with zero writes or other topics involved (see
  /// `remote_helm_re/findings/00_STATUS.md` Update 27). The real app is
  /// never observed sending a client-initiated bulk content batch at all
  /// (see Update 28) — this chunking exists purely so this client can
  /// still get every object's content up front without lazy-loading
  /// (an explicit product requirement), not because it replicates
  /// anything the real app does.
  Future<List<DownloadedObject>> fetchObjectsChunked(
    int topic,
    List<String> uuids, {
    required Uint8List remoteVer,
    int chunkSize = 10,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final results = <DownloadedObject>[];
    for (var i = 0; i < uuids.length; i += chunkSize) {
      final chunk = uuids.sublist(i, i + chunkSize > uuids.length ? uuids.length : i + chunkSize);
      results.addAll(await fetchObjects(topic, chunk, remoteVer: remoteVer, timeout: timeout));
    }
    return results;
  }

  /// Sends the batch [tGetObject] request and returns the raw
  /// [tGetObjectReply], without the (potentially slow — see
  /// [_splitGzipMembers]'s doc comment) gzip-member-splitting and JSON
  /// decoding [fetchObjects] does with the result. Split out so
  /// [_fetchCatalog]'s "sync every other registered topic's own batch
  /// tGetObject too, discarding the result" step (see [_fetchCatalog]'s
  /// doc comment for why that's needed) doesn't pay for parsing objects
  /// nothing will ever look at — confirmed live 2026-08-06 to matter:
  /// `0x4`'s own real reply was ~80KB and [_splitGzipMembers]'s
  /// byte-by-byte boundary search made that discard step alone take
  /// well over a minute.
  Future<_InnerMessage> _sendBatchGetObject(
    int topic,
    List<String> uuids, {
    Uint8List? remoteVer,
    required Duration timeout,
  }) async {
    await _ensurePreamble(timeout);
    final alreadyRegistered = _registeredTopics.contains(topic);
    _registerTopic(topic);
    if (!alreadyRegistered) {
      try {
        await _messages.stream
            .firstWhere((m) => m.topicId == topic && (m.msgType == 0x0a || m.msgType == 0x09))
            .timeout(timeout, onTimeout: () => throw const RouteCatalogException('no reply from the plotter'));
      } on StateError {
        throw const RouteCatalogException('connection to the plotter closed before a reply arrived');
      }
    }
    // Falls back to this connection's cached remote_ver for [topic] (from
    // an earlier [fetchCatalog]/[_syncCatalog] call) when the caller
    // didn't pass one explicitly — see [fetchObjects]'s doc comment for
    // why this matters; [_nextCorrelationId] as a last resort keeps this
    // callable in isolation (e.g. tests) rather than throwing outright.
    final correlationId = remoteVer ?? _remoteVerByTopic[topic] ?? _nextCorrelationId();

    // Per-entry marker `01 07 11 10` — distinct from the reply-side
    // [_catalogUuidMarker] (`02 07 11 10`), only the leading byte differs.
    final body = BytesBuilder(copy: false)
      ..add(const [0x01, 0x01])
      ..add(_leb128(uuids.length));
    for (final uuid in uuids) {
      body
        ..add(const [0x01, 0x07, 0x11, 0x10])
        ..add(_parseUuid(uuid));
    }
    final bBytes = body.toBytes();
    final a = BytesBuilder(copy: false)
      ..add(correlationId)
      ..add(_leb128(bBytes.length))
      ..add(bBytes);
    final aBytes = a.toBytes();
    final rest = BytesBuilder(copy: false)
      ..add(_leb128(aBytes.length))
      ..add(aBytes);

    // Bug found live 2026-08-08: while a large batch tGetObject reply is
    // outstanding, the plotter can send its own mid-merge tGetObject on the
    // same topic — the same "digest-based merge is two-way" behavior
    // _syncCatalog already handles via _autoReplyToServerGetObject (see that
    // function's doc comment: unanswered, it "appears to block the
    // plotter's own tCatalogSyncReply until answered"). This function used
    // to not subscribe at all, so a plotter-initiated request arriving
    // during a big batch fetch got silently ignored — live-observed as a
    // 100-uuid routes batch (fresh, correct remote_ver, immediately
    // following a successful tCatalogSync) getting no reply whatsoever,
    // not even tGetObjectError, matching exactly this kind of stall rather
    // than an outright rejection. Wrapping the send+await the same way
    // _syncCatalog does fixes it.
    final getObjectSub = _autoReplyToServerGetObject(topic);
    final _InnerMessage reply;
    try {
      _send(topic, tGetObject, 0, rest.toBytes());
      reply = await _awaitGetObjectReply(topic, correlationId, timeout);
    } finally {
      await getObjectSub.cancel();
    }
    if (reply.msgType == tGetObjectError) {
      throw const RouteCatalogException('plotter rejected the batch object request');
    }
    return reply;
  }

  /// Decodes an incoming plotter-initiated `tDeleteEntry`-shaped message
  /// (see [pushes]' own doc comment) into a [CatalogPush] and adds it to
  /// [_pushes]. Deliberately reuses [_findBytes]-based landmark search
  /// (the uuid marker, the gzip magic) rather than re-deriving the exact
  /// field-by-field tag layout [_buildAddOrUpdateBody]/[_buildDeleteTrailer]
  /// build — this is parsing a message this client didn't construct, so
  /// trusting the same landmarks the send side already relies on is safer
  /// than assuming the receive side's layout is byte-identical to what
  /// this client happens to send.
  void _handleIncomingPush(_InnerMessage message) {
    final uuidMarkerIdx = _findBytes(message.rest, const [0x07, 0x11, 0x10]);
    if (uuidMarkerIdx < 0 || uuidMarkerIdx + 3 + 16 > message.rest.length) {
      // Not a shape this client recognizes -- silently ignored rather than
      // thrown, since a malformed/unexpected push shouldn't take down an
      // otherwise-healthy connection over something this client doesn't
      // strictly need to understand.
      return;
    }

    // **Added 2026-08-13, live-suspected cause of a plotter crash/reboot
    // after an incoming push.** The push carries the plotter's own fresh
    // `prevRemoteVer`/`newRemoteVer` pair for this topic — same envelope
    // shape [_buildAddOrUpdateBody]'s own tail uses on the way out, just
    // arriving in the other direction — but this method used to only
    // decode the uuid/object from it, never updating [_remoteVerByTopic]
    // with the plotter's own [newRemoteVer]. That leaves this
    // connection's cached `remote_ver` stale the moment ANYTHING else
    // changes the topic (this client's own writes, the real app's writes,
    // or a change made directly on the plotter) — and the very next write
    // this connection makes (e.g. [addOrUpdateRoute]/[addOrUpdateWaypoint]
    // reusing that stale cached value instead of syncing, since 2026-08-13's
    // fix to stop always re-syncing) would then be built on a
    // `prevRemoteVer` the plotter no longer considers current. Updating it
    // here keeps the cache honest without needing a fresh sync at all —
    // the whole point of listening to pushes in the first place.
    final (value: _, consumed: prefixLen) = _decodeLeb128(message.rest, 0);
    if (prefixLen + 16 <= message.rest.length) {
      final newRemoteVer = Uint8List.sublistView(message.rest, prefixLen + 8, prefixLen + 16);
      _remoteVerByTopic[message.topicId] = newRemoteVer;
    }

    final uuid = _formatUuid(Uint8List.sublistView(message.rest, uuidMarkerIdx + 3, uuidMarkerIdx + 3 + 16));

    final gzipIdx = _findBytes(message.rest, const [0x1F, 0x8B, 0x08]);
    if (gzipIdx < 0) {
      // No JSON payload at all -- the same shape deleteEntry's own
      // fire-and-forget delete uses, just arriving in the other direction.
      _pushes.add(CatalogPushDelete(message.topicId, uuid));
      return;
    }
    final object = _decodePushObjectJson(Uint8List.sublistView(message.rest, gzipIdx), fallbackUuid: uuid);
    if (object != null) {
      _pushes.add(CatalogPushUpdate(message.topicId, object));
    }
  }

  Future<void> close() async {
    _keepaliveTimer?.cancel();
    await _appMsgReplySub?.cancel();
    await _sub.cancel();
    await _messages.close();
    await _pushes.close();
    _socket.destroy();
  }
}

/// [Isolate.run] entry point for [RouteCatalogConnection.fetchObjects] —
/// splits a raw batch [tGetObjectReply] body into its gzip members and
/// decodes each one, all off the caller's own event loop (see
/// [RouteCatalogConnection.fetchObjects]'s doc comment for why). Must be a
/// plain top-level function taking/returning only data that can cross an
/// isolate boundary (no closures over connection state) — [Uint8List] in,
/// [List] of plain data objects out.
List<DownloadedObject> _decodeBatchReply(Uint8List replyRest) {
  final results = <DownloadedObject>[];
  for (final blob in _splitGzipMembers(replyRest)) {
    try {
      results.add(_decodeObjectJson(blob, fallbackUuid: ''));
    } on RouteCatalogException {
      // Skip individual entries that fail to decode — see fetchObjects'
      // own doc comment for why a partial result beats none here.
    }
  }
  return results;
}

/// Decodes one gzip+JSON object payload (starting exactly at its `1F 8B 08`
/// gzip magic — the caller has already located it within a larger reply)
/// into a [DownloadedObject]. Shared by [RouteCatalogConnection.fetchObject]
/// (one gzip blob per reply) and the batch object-fetch path (many
/// concatenated gzip blobs per reply, one per requested uuid).
DownloadedObject _decodeObjectJson(Uint8List gzipBytes, {required String fallbackUuid}) {
  final Map<String, dynamic> json;
  try {
    final decompressed = GZipCodec().decode(gzipBytes);
    // The decompressed payload has a trailing NUL byte after the JSON's
    // closing brace in every capture seen — stripped rather than treated
    // as an error, since it's consistently harmless padding, not
    // truncated/corrupt data. String.trim() doesn't remove it (NUL isn't
    // Unicode whitespace), hence the explicit strip here.
    var jsonBytes = decompressed;
    var end = jsonBytes.length;
    while (end > 0 && jsonBytes[end - 1] == 0) {
      end--;
    }
    json = jsonDecode(utf8.decode(jsonBytes.sublist(0, end))) as Map<String, dynamic>;
  } on Object catch (e) {
    throw RouteCatalogException('could not decode object payload: $e');
  }

  // Tracks use `"id"` for their name instead of routes/waypoints' `"name"`
  // — confirmed live 2026-08-07 fetching the real track "03-AUG-22" via
  // topic4 (see this file's top doc comment's track section).
  final name = (json['name'] ?? json['id']) as String? ?? fallbackUuid;
  final points = <RoutePoint>[];
  final rawPoints = json['points'];
  if (rawPoints is List) {
    for (final p in rawPoints) {
      final map = p as Map<String, dynamic>;
      final lon = (map['lon'] as num).toInt();
      final lat = (map['lat'] as num).toInt();
      points.add(RoutePoint(name: name, lat: _fromSemicircle(lat), lon: _fromSemicircle(lon)));
    }
  } else if (json['lon'] is num && json['lat'] is num) {
    // Unconfirmed fallback for a lone-waypoint reply shape — see this
    // file's top doc comment's "Known gaps" section.
    final lon = (json['lon'] as num).toInt();
    final lat = (json['lat'] as num).toInt();
    points.add(RoutePoint(name: name, lat: _fromSemicircle(lat), lon: _fromSemicircle(lon)));
  }
  if (points.isEmpty) {
    throw const RouteCatalogException('object reply had no usable coordinates');
  }

  return DownloadedObject(
    name: name,
    uuid: json['uuid'] as String? ?? fallbackUuid,
    points: points,
    vstamp: (json['vstamp'] as num?)?.toInt(),
  );
}

/// Like [_decodeObjectJson], but for [RouteCatalogConnection.pushes]:
/// **allows an empty `points` list** rather than throwing. A real capture
/// (`0b32f738`) showed the plotter push a brand-new route with `"points":
/// []` the moment it's created on the plotter's own screen, before the
/// user has drawn any points yet — a real, valid intermediate state for a
/// push (unlike [fetchObject]'s reply, which only ever describes an
/// already-fully-formed object, where no usable coordinates really does
/// mean something went wrong). Returns `null` instead of throwing on a
/// genuinely undecodable payload, since one malformed push shouldn't be
/// allowed to crash an otherwise-healthy [pushes] listener.
DownloadedObject? _decodePushObjectJson(Uint8List gzipBytes, {required String fallbackUuid}) {
  final Map<String, dynamic> json;
  try {
    final decompressed = GZipCodec().decode(gzipBytes);
    var jsonBytes = decompressed;
    var end = jsonBytes.length;
    while (end > 0 && jsonBytes[end - 1] == 0) {
      end--;
    }
    json = jsonDecode(utf8.decode(jsonBytes.sublist(0, end))) as Map<String, dynamic>;
  } on Object {
    return null;
  }

  final name = (json['name'] ?? json['id']) as String? ?? fallbackUuid;
  final points = <RoutePoint>[];
  final rawPoints = json['points'];
  if (rawPoints is List) {
    for (final p in rawPoints) {
      final map = p as Map<String, dynamic>;
      final lon = (map['lon'] as num).toInt();
      final lat = (map['lat'] as num).toInt();
      points.add(RoutePoint(name: name, lat: _fromSemicircle(lat), lon: _fromSemicircle(lon)));
    }
  } else if (json['lon'] is num && json['lat'] is num) {
    final lon = (json['lon'] as num).toInt();
    final lat = (json['lat'] as num).toInt();
    points.add(RoutePoint(name: name, lat: _fromSemicircle(lat), lon: _fromSemicircle(lon)));
  }

  return DownloadedObject(
    name: name,
    uuid: json['uuid'] as String? ?? fallbackUuid,
    points: points,
    vstamp: (json['vstamp'] as num?)?.toInt(),
  );
}

/// Splits [body] into consecutive gzip members, each starting at a `1F 8B
/// 08` magic. Used to decode a batch [tGetObjectReply] that bundles many
/// objects (one gzip blob per requested uuid, back-to-back, no length
/// prefix between them — confirmed in a real capture: a 118-uuid batch
/// request came back as exactly 118 concatenated gzip members, decoded
/// and JSON-parsed byte-for-byte correctly with this approach).
///
/// Splitting naively at the next `1F 8B 08` magic doesn't work: gzip's
/// DEFLATE payload can legitimately contain that same 3-byte sequence
/// as compressed data, which was confirmed to corrupt 117 of 118 blobs
/// in a real capture when tried. Instead, each member's true end is
/// found by decoding the window from its start until decoding it as
/// gzip **and then as JSON** both succeed. Neither check alone is
/// reliable: [GZipCodec.decode] on a too-short prefix can throw, or can
/// "succeed" with an empty or truncated (e.g. `{"na`) result instead —
/// both confirmed live against a real 118-object capture, where
/// trusting either signal alone matched a false boundary well before
/// the true one. Requiring a full, valid JSON object parse (a member's
/// compressed JSON body only becomes syntactically complete at its true
/// end) is the only check of the three that only succeeds at the real
/// boundary.
///
/// **Scans forward in [_boundaryScanStep]-byte jumps, not one byte at a
/// time** — a plain byte-by-byte scan (this function's original
/// implementation) took over a minute against a real, larger (177-entry)
/// batch reply, which is far too slow for a one-time catalog load. A
/// naive binary search over candidate end offsets does NOT work here —
/// confirmed live: decode success past the true boundary is **not
/// monotonic** (e.g. against a real capture, offsets 261-270 past a
/// member's start decoded successfully — tolerating a few bytes of the
/// next member's own header — but offset 300 failed again, because by
/// then the window spans deep enough into unrelated compressed data to
/// break the DEFLATE stream). This scans strictly forward in small
/// jumps to find *a* successful window without ever skipping past one
/// (unlike doubling/exponential search, which jumped straight past that
/// narrow tolerance zone and missed every member in testing), then
/// steps strictly backward byte-by-byte from that known-good point to
/// find the exact minimal boundary — backward-only, since a smaller
/// window than a known-good one either also succeeds (still inside the
/// same tolerance zone) or fails (the moment it drops below the true
/// boundary), which unlike the forward direction genuinely is
/// monotonic. Verified against a real 118-blob capture: every found
/// boundary lands exactly on the real `1F 8B 08` marker position, and
/// this brought that same capture from ~150ms down to ~70ms — the real
/// win is on larger replies the byte-by-byte version couldn't finish in
/// reasonable time at all.
List<Uint8List> _splitGzipMembers(Uint8List body) {
  final blobs = <Uint8List>[];
  var offset = 0;
  while (true) {
    final start = _findBytes(Uint8List.sublistView(body, offset), const [0x1F, 0x8B, 0x08]);
    if (start < 0) break;
    final absStart = offset + start;

    // **Fast path: read this member's own real length from its header,
    // instead of guessing — found live 2026-08-07.** Every member's gzip
    // magic is preceded by a fixed-shape header: `05 07 11 10` + uuid(16)
    // + 11 more bytes + `02 01 00 0f` + two back-to-back LEB128 values,
    // the *second* of which is this member's exact byte length (confirmed
    // against two independent real captures: a 118-waypoint batch and a
    // single ~80KB track object, both matching this member's real length
    // exactly — verified by successfully gzip-decoding exactly that many
    // bytes and finding a complete JSON object). This replaces what used
    // to be a guess-and-check boundary scan (still kept below as a
    // fallback for a reply that doesn't match this exact header shape):
    // that scan grew its trial window in small steps from 20 bytes up to
    // the member's full size, trying a fresh gzip-decode-then-JSON-parse
    // at every step — fine for the small ~200-300 byte members routes/
    // waypoints have, but for the track's single ~80KB member that's
    // ~20,000 failed attempts, live-measured taking ~26 *seconds* for
    // that one object alone (network transfer for the same reply took
    // 55ms — decoding was >99% of the total time). Reading the real
    // length directly is O(1) instead of O(member size), and correctly
    // handles multiple large members in one reply (the boundary-scan
    // approach only got a fast path for the very last member in a reply,
    // via a since-removed "no more magic after this" special case).
    final directLength = _readMemberLengthFromHeader(body, absStart);
    if (directLength != null) {
      final end = absStart + directLength;
      if (end <= body.length && _decodesToValidJson(body, absStart, end)) {
        blobs.add(Uint8List.sublistView(body, absStart, end));
        offset = end;
        continue;
      }
      // Header didn't check out (length pointed past a valid member) —
      // fall through to the scan below rather than trusting a bad read.
    }

    var end = absStart + 20;
    var found = false;
    while (end <= body.length) {
      if (_decodesToValidJson(body, absStart, end)) {
        found = true;
        break;
      }
      end += _boundaryScanStep;
    }
    if (!found) break; // trailing garbage/truncated member: stop, keep what parsed

    while (end - 1 > absStart && _decodesToValidJson(body, absStart, end - 1)) {
      end--;
    }
    blobs.add(Uint8List.sublistView(body, absStart, end));
    offset = end;
  }
  return blobs;
}

/// The fixed marker between a member's uuid header and its two length
/// fields — see [_splitGzipMembers]'s doc comment for the full header
/// shape this is part of.
const List<int> _memberLengthMarker = [0x02, 0x01, 0x00, 0x0f];

/// Reads a gzip member's real byte length from its own header, by walking
/// backward from [gzipStart] (this member's `1F 8B 08` magic) to find the
/// `02 01 00 0f` marker and decoding the second of the two LEB128 values
/// right after it — see [_splitGzipMembers]'s doc comment for the header
/// shape and how this was derived. Returns `null` if the expected shape
/// isn't found (e.g. [gzipStart] is too close to the start of [body] for a
/// full header, or the marker isn't where expected), so the caller can
/// fall back to the scan-based approach instead of trusting a bad offset.
int? _readMemberLengthFromHeader(Uint8List body, int gzipStart) {
  // The marker sits a small, fixed number of bytes before the magic in
  // every real capture examined (13 bytes for a small waypoint member, 20
  // for the much larger track member) — rather than assume one fixed
  // offset, search backward through a window comfortably larger than
  // either observed case.
  const searchWindow = 64;
  final searchStart = gzipStart - searchWindow < 0 ? 0 : gzipStart - searchWindow;
  final headerRegion = Uint8List.sublistView(body, searchStart, gzipStart);
  final markerRelIdx = _findBytesLast(headerRegion, _memberLengthMarker);
  if (markerRelIdx < 0) return null;
  final afterMarker = searchStart + markerRelIdx + _memberLengthMarker.length;
  final (value: _, consumed: firstConsumed) = _decodeLeb128(body, afterMarker);
  if (firstConsumed < 0) return null;
  final (value: length, consumed: secondConsumed) = _decodeLeb128(body, afterMarker + firstConsumed);
  if (secondConsumed < 0) return null;
  // The two LEB128 values must end exactly at gzipStart — if they don't,
  // this wasn't really the length header (e.g. a coincidental byte match
  // earlier in the region), so don't trust it.
  if (afterMarker + firstConsumed + secondConsumed != gzipStart) return null;
  return length;
}

/// Like [_findBytes] but returns the *last* match instead of the first —
/// used by [_readMemberLengthFromHeader] to find the length marker
/// closest to the gzip magic it belongs to, in case an earlier
/// coincidental byte match exists further back in the search window.
int _findBytesLast(Uint8List haystack, List<int> needle) {
  for (var i = haystack.length - needle.length; i >= 0; i--) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// Jump size for [_splitGzipMembers]'s forward boundary scan — small
/// enough to never jump past the few-byte "tolerance zone" right after a
/// real member's true end (see [_splitGzipMembers]'s doc comment), large
/// enough to meaningfully cut down how many [GZipCodec.decode] calls a
/// large reply needs. 4 was picked empirically: the smallest real gzip
/// member seen in any capture was 221 bytes and the observed tolerance
/// zone was ~10 bytes wide, so 4 leaves comfortable margin on both.
const int _boundaryScanStep = 4;

bool _decodesToValidJson(Uint8List body, int start, int end) {
  if (end > body.length) return false;
  try {
    final decompressed = GZipCodec().decode(Uint8List.sublistView(body, start, end));
    if (decompressed.isEmpty) return false;
    var jsonEnd = decompressed.length;
    while (jsonEnd > 0 && decompressed[jsonEnd - 1] == 0) {
      jsonEnd--;
    }
    jsonDecode(utf8.decode(decompressed.sublist(0, jsonEnd)));
    return true;
  } on Object {
    return false;
  }
}

/// Converts a Garmin semicircle `int32` back to plain degrees — the inverse
/// of `route_sync.dart`'s `_toSemicircle`.
double _fromSemicircle(int value) {
  const scale = 180.0 / 2147483648.0; // 180 / 2^31
  return value * scale;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Encodes [value] as an unsigned LEB128 varint — the length-field
/// encoding used by [RouteCatalogConnection.fetchObjects]'s batch
/// [tGetObject] request, confirmed against real captured bytes and
/// sweeping every varint byte-count boundary from 0 to 5000 (see
/// [RouteCatalogConnection.fetchObjects]'s doc comment).
Uint8List _leb128(int value) {
  final out = <int>[];
  var v = value;
  while (true) {
    final b = v & 0x7f;
    v >>= 7;
    if (v != 0) {
      out.add(b | 0x80);
    } else {
      out.add(b);
      break;
    }
  }
  return Uint8List.fromList(out);
}

/// Decodes an unsigned LEB128 varint from [bytes] starting at [offset].
/// Returns `consumed: -1` if [bytes] runs out before a terminating byte
/// (continuation bit clear) is found.
({int value, int consumed}) _decodeLeb128(Uint8List bytes, int offset) {
  var value = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    if (i >= bytes.length) return (value: 0, consumed: -1);
    final b = bytes[i];
    value |= (b & 0x7f) << shift;
    i++;
    if (b & 0x80 == 0) break;
    shift += 7;
  }
  return (value: value, consumed: i - offset);
}

int _findBytes(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

String _formatUuid(Uint8List bytes) {
  String hex(int start, int end) =>
      bytes.sublist(start, end).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

Uint8List _parseUuid(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw RouteCatalogException('not a valid UUID: $uuid');
  }
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
