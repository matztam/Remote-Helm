/// Route/waypoint sync — pushes a route (as parsed from a GPX file) to the
/// plotter over a separate TCP channel from the main Helm session.
///
/// ## How this was found
///
/// Nothing about this exists in any prior documentation of the Helm
/// protocol (neither `Mrkvak/helm-linux`'s `PROTOCOL.md` nor any public
/// reverse-engineering of Garmin's marine app protocols mentions a route/
/// waypoint sync channel) — it was reverse-engineered from scratch for this
/// feature via a targeted packet capture (PCAPdroid) of the real
/// ActiveCaptain app syncing a manually-imported GPX route to a real
/// plotter.
///
/// The main Helm session (port [helmPort], `helm_client.dart`) briefly
/// mentions this exists: right after the handshake, one of the `0x1649`
/// replies to a subscribe echoes a small subtype-9 payload
/// (`[u32 9][u32 8][u16 ...][u16 ...]`) whose meaning wasn't pinned down,
/// but sync traffic was observed exclusively on a **separate** connection
/// to [routeSyncPort] (50610) — not on [helmPort] itself, and not present
/// at all in a capture of an ActiveCaptain-only (cloud) GPX import that
/// never touched the plotter's local Wi-Fi.
///
/// ### Wire format
///
/// Same outer framing as the rest of Helm
/// (`[u16 type LE][u16 0xBEEF][u32 length LE][payload]`, see
/// `protocol.dart`), but with its own message types and its own `tHello`
/// tag: instead of the touch channel's fixed [helloTag] (`0x9531`), this
/// channel's `tHello` payload is the port number itself
/// (`50610` as `u16`, i.e. `0xc5 0xb2`) — suggesting the port is meant to
/// be treated as a fixed, well-known service address rather than something
/// dynamically negotiated (the client sends this as the very first frame
/// of a fresh connection, before the plotter has said anything back).
///
/// Handshake, all confirmed against the real capture:
/// ```
/// C->S  tHello     (0x083f)  payload = port number, u16 LE (2 bytes)
/// C->S  tToken     (0x0aa9)  payload = 8-byte session token (same as the touch channel)
/// C->S  tSyncBegin (0x08b7)  payload = 0x02 (1 byte) — meaning unconfirmed, always this value
/// S->C  tSyncAck   (0x08b8)  payload = 0x01 (1 byte) — grants the sync
/// C->S  tSyncData  (0x08b9)  payload = the route, see [encodeRoute]
/// S->C  tSyncDone  (0x08bb)  payload = empty — plotter accepted it
/// ```
///
/// ### Route/waypoint record format (inside tSyncData)
///
/// The capture (one route, 4 waypoints) decoded as: a fixed 158-byte
/// preamble (an outer envelope this implementation doesn't fully
/// understand the semantics of beyond two length fields that scale with
/// point count — replayed byte-for-byte otherwise as
/// [_recordSchemaHeaderTemplate]/[_buildRecordSchemaHeader], since
/// deviating from what was actually observed working risks the plotter
/// rejecting or misinterpreting the sync), followed by one **283-byte
/// fixed-size record per waypoint**. The first
/// record's initial ~25 bytes are laid out completely differently from
/// every later record's — not the same fields at shifted offsets, but two
/// unrelated fixed sequences (see [_laterRecordPrefix] and
/// [_firstRecordPrefixTail]) — because the first record additionally
/// carries the route's own name. Confirmed against two independent real
/// captures (4 and 8 waypoints): field offsets within a record (relative
/// to the record's own start) that this implementation actually uses:
///
/// | offset | size | content |
/// |---|---|---|
/// | 0x00 | 15 | route name (first record only), Latin-1, zero-padded/truncated |
/// | 0x0f | 4  | total point count in the route, `u32` LE (first record only) |
/// | 0x18 | 1  | a per-point type marker: `0x03` for a plain position (no catalog identity — the two captures' point-level UUID/name fields are correspondingly zero/empty), `0x00` for a point that references an existing catalog waypoint (that capture's points all carried a real UUID and name) — see [_laterRecordPrefix]'s doc comment |
/// | 0x19 | 4  | latitude, Garmin semicircle `int32` (`round(degrees * 2^31 / 180)`) |
/// | 0x1d | 4  | longitude, same encoding |
/// | 0x21 | 16 | catalog-waypoint UUID this point references — only present (non-zero) on `0x00`-marker points; all-zero on `0x03`-marker (plain-position) points, confirmed in the real GPX-import capture |
/// | 0x31 | 10 | that waypoint's name, Latin-1, zero-padded/truncated (confirmed via a captured "ø" stored as the single byte `0xf8`, not 2-byte UTF-8 — this field is *not* UTF-8, unlike a first guess) — empty on `0x03`-marker points, same as the UUID field |
/// | 0x4f | 11 | fixed bytes, identical across every waypoint in both captures |
/// | 0x5a | 4  | sync timestamp, `u32` LE seconds since the Garmin/GPS epoch (1989-12-31T00:00:00Z) — see [_waypointMetadataBlockPrefix]'s doc comment |
///
/// Everything else in the 283-byte record was zero in both captures and is
/// left zero here too.
///
/// ### The trailer after the last record
///
/// The `tSyncData` payload has 34 bytes *after* the last waypoint record: a
/// fixed 30-byte prefix (`ffffffff` + 15 zero bytes + `01 00 0a 00 00 00`,
/// [_trailerPrefix]) followed by a 4-byte checksum. Confirmed identical
/// (byte-for-byte, including the checksum's own placement) across two
/// independent real captures with different point counts (4 and 8 points),
/// which is what made cracking the checksum tractable: since the fixed
/// prefix and its position relative to the end are the same in both, the
/// checksum must depend only on the data that differs between them.
///
/// The checksum is plain CRC-32/IEEE (the same polynomial and algorithm as
/// `zlib.crc32`/PNG/gzip — confirmed against real captures to be the
/// standard table) over `payload[1:payload.length -
/// 10]` — i.e. everything except the payload's very first byte and the
/// last 10 bytes (the checksum field itself plus the fixed `01 00 0a 00 00
/// 00` immediately before it), encoded little-endian. Verified to
/// byte-for-byte reproduce both captures' checksums exactly (`0xb4c2cab1`
/// for 4 points, `0xa7cee384` for 8 points) via [_computeTrailerChecksum].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// The route/waypoint sync service's own port — observed fixed at this
/// value in the only capture available; unlike the RTSP video URL, nothing
/// in the main Helm session communicates this port dynamically, so it's
/// treated as a constant here. See this file's top doc comment.
const int routeSyncPort = 50610;

const int tSyncBegin = 0x08B7;
const int tSyncAck = 0x08B8;
const int tSyncData = 0x08B9;
const int tSyncDone = 0x08BB;

/// One route point: [name] truncated/padded to fit the wire format's fixed
/// 10-byte slot (see [_kWaypointNameSize]); [lat]/[lon] in plain degrees.
class RoutePoint {
  final String name;
  final double lat;
  final double lon;
  const RoutePoint({required this.name, required this.lat, required this.lon});
}

const int _kRecordSize = 283;
const int _kRouteNameSize = 15;
const int _kWaypointNameSize = 10;
const int _kLatOffset = 0x19;
const int _kLonOffset = 0x1d;
const int _kWaypointUuidOffset = 0x21;
const int _kWaypointUuidSize = 16;
const int _kWaypointNameOffset = 0x31;

/// The 25-byte prefix (everything before [_kLatOffset]) is laid out
/// completely differently on the first record (which additionally carries
/// the route's own name) than on every later one — not the same fields at
/// shifted offsets, but two unrelated fixed byte sequences confirmed
/// against the capture (see this file's top doc comment). Both were
/// replayed verbatim rather than reconstructed field-by-field, since
/// neither is understood beyond "the route name text appears in one of
/// them, and there's a `ffffffff` marker in both, at different offsets" —
/// except for their very last byte (offset 24, right before
/// [_kLatOffset]), which is a known unknown: identical across every record
/// *within* a route (confirmed against all 4 records of the 4-point
/// capture and all 8 of the 8-point one), but different between the two
/// routes (`0x00` vs `0x03`) — plausibly some route-level flag or
/// checksum-like value, but with only two data points to compare, no rule
/// for it could be derived. Both prefixes take it as [routeMarkerByte] — see
/// [_kPlainPositionMarkerByte]'s doc comment for which value this client
/// actually sends and why.
///
/// Non-first records: 11 zero bytes, `ffffffff`, 9 more zero bytes, then
/// [routeMarkerByte].
Uint8List _laterRecordPrefix(int routeMarkerByte) {
  return Uint8List.fromList([
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, //
    0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    routeMarkerByte,
  ]);
}

/// Bytes 15..24 (10 bytes) of the first record's prefix — i.e. everything
/// after its 15-byte route-name slot (bytes 0..14, written separately via
/// [_writeFixedString]) and before [_kLatOffset]. Byte 0 (a `u32` LE at
/// offset 15..18) is the route's total point count — confirmed by diffing
/// the 4-point capture (`04 00 00 00`) against the 8-point one (`08 00 00
/// 00`), and built dynamically here accordingly. The last byte is
/// [routeMarkerByte] — see [_laterRecordPrefix]'s doc comment.
Uint8List _firstRecordPrefixTail(int pointCount, int routeMarkerByte) {
  final tail = Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x02, routeMarkerByte]);
  ByteData.view(tail.buffer).setUint32(0, pointCount, Endian.little);
  return tail;
}

/// **Corrected 2026-08-16** — this client builds routes from plain
/// coordinates (a GPX file's `<rtept>` points have no catalog identity),
/// which the one real GPX-import capture available (an 8-point route)
/// encoded with marker byte `0x03` and an all-zero UUID/empty name per
/// point. A second real capture (4 points, all referencing pre-existing,
/// named catalog waypoints) used marker `0x00` with a real UUID/name per
/// point instead — a genuinely different point shape this client has no
/// use for, since it never has a real catalog-waypoint UUID to reference.
/// Previously this used `0x00` (the wrong shape) while also writing a
/// random UUID and the point's GPX name into the fields real `0x03`-marker
/// points always left empty — a combination never observed on the wire,
/// mixing "this is a named waypoint reference" (the marker) with "this is
/// an anonymous position" (the actual field contents).
const int _kPlainPositionMarkerByte = 0x03;

/// A 15-byte block after the waypoint name field, identical across every
/// waypoint *within* a single capture but different between the two known
/// captures (`…1abed544` vs. `…de7ad844` in their last 4 bytes) — plausibly
/// a symbol/display-option field (first 11 bytes, confirmed fixed across
/// both captures) followed by a sync timestamp (last 4 bytes). The last 4
/// bytes, read as a `u32` LE, decode as a plausible Unix-style timestamp
/// against the Garmin/GPS epoch (1989-12-31 00:00:00 UTC): the 4-point
/// capture's `1abed544` -> 1154858522 -> 2026-08-05 10:02:02 UTC, and the
/// 8-point capture's `de7ad844` -> 1155037918 -> 2026-08-07 11:51:58 UTC —
/// both matching their respective capture dates/times (the second capture
/// was PCAPdroid-logged at "07 Aug., 13:51" local CEST = 11:51 UTC),
/// confirming this is the sync time, not a fixed constant — built
/// dynamically here from [DateTime.now] accordingly.
const int _kWaypointMetadataOffset = 0x4f;
final Uint8List _waypointMetadataBlockPrefix = Uint8List.fromList([
  0x12, 0x00, 0x13, 0x51, 0x59, 0x04, 0x69, 0x51, //
  0x59, 0x04, 0x69,
]);

/// Seconds between the Unix epoch and the Garmin/GPS epoch
/// (1989-12-31T00:00:00Z) used by [_waypointMetadataBlockPrefix]'s trailing
/// timestamp field — see that field's doc comment for how this was derived.
final int _garminEpochOffsetSeconds = DateTime.utc(1989, 12, 31).millisecondsSinceEpoch ~/ 1000;

Uint8List _waypointMetadataBlock(DateTime syncTime) {
  final block = Uint8List(15);
  block.setRange(0, _waypointMetadataBlockPrefix.length, _waypointMetadataBlockPrefix);
  final garminSeconds = syncTime.toUtc().millisecondsSinceEpoch ~/ 1000 - _garminEpochOffsetSeconds;
  ByteData.view(block.buffer).setUint32(11, garminSeconds, Endian.little);
  return block;
}

/// The 158-byte preamble observed before the first waypoint record in
/// every `tSyncData` payload — mostly replayed verbatim (see this file's
/// top doc comment for why), except for two `u16` length fields that vary
/// with the route's total encoded size (see [_buildRecordSchemaHeader]):
/// bytes 3-4 (`payload.length - 11`) and bytes 18-19 (`payload.length -
/// 26`), confirmed by diffing the 4-point and 8-point captures — every
/// other byte in the preamble was identical between them.
final Uint8List _recordSchemaHeaderTemplate = Uint8List.fromList([
  0x03, 0x00, 0x00, 0x21, 0x05, 0x00, 0x00, 0x07, 0x0f, 0x00, 0x00, 0x00, //
  0x64, 0x00, 0x00, 0x00, 0x02, 0x00, 0x12, 0x05, 0x00, 0x00, 0x1e, 0x00,
  0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x2e, 0x00, 0x00, 0x00, 0x18, 0x00,
  0x00, 0x00, 0x8e, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xc8, 0x00,
  0x0f, 0x00, 0xc9, 0x00, 0x04, 0x00, 0xca, 0x00, 0x04, 0x00, 0xcb, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x04, 0x00, 0x02, 0x00,
  0x04, 0x00, 0x0a, 0x00, 0x10, 0x00, 0x14, 0x00, 0x0a, 0x00, 0x15, 0x00,
  0x14, 0x00, 0x16, 0x00, 0x02, 0x00, 0x17, 0x00, 0x01, 0x00, 0x18, 0x00,
  0x04, 0x00, 0x19, 0x00, 0x04, 0x00, 0x1a, 0x00, 0x04, 0x00, 0x1e, 0x00,
  0x01, 0x00, 0x23, 0x00, 0x0a, 0x00, 0x1f, 0x00, 0x10, 0x00, 0x20, 0x00,
  0x01, 0x00, 0x21, 0x00, 0x04, 0x00, 0x22, 0x00, 0x08, 0x00, 0x28, 0x00,
  0x33, 0x00, 0x29, 0x00, 0x33, 0x00, 0x2a, 0x00, 0x33, 0x00, 0x2b, 0x00,
  0x02, 0x00, 0x2c, 0x00, 0x01, 0x00, 0x2d, 0x00, 0x10, 0x00, 0x3f, 0x00,
  0x01, 0x00, //
]);

const int _kHeaderLengthFieldAOffset = 3;
const int _kHeaderLengthFieldBOffset = 18;

/// Builds the 158-byte preamble for a `tSyncData` payload of total length
/// [totalPayloadLength] — see [_recordSchemaHeaderTemplate].
Uint8List _buildRecordSchemaHeader(int totalPayloadLength) {
  final header = Uint8List.fromList(_recordSchemaHeaderTemplate);
  final bd = ByteData.view(header.buffer);
  bd.setUint16(_kHeaderLengthFieldAOffset, totalPayloadLength - 11, Endian.little);
  bd.setUint16(_kHeaderLengthFieldBOffset, totalPayloadLength - 26, Endian.little);
  return header;
}

/// Converts plain degrees to Garmin's semicircle `int32` encoding
/// (`round(degrees * 2^31 / 180)`), confirmed against all 4 captured
/// waypoints' coordinates matching the source GPX exactly.
int _toSemicircle(double degrees) {
  const scale = 2147483648.0 / 180.0; // 2^31 / 180
  return (degrees * scale).round();
}

/// Writes [text] into `out[offset..offset+size)` as Latin-1 (ISO-8859-1),
/// truncated and zero-padded to [size] bytes. Confirmed against the
/// capture: a name containing "ø" (U+00F8) was stored as the single byte
/// `0xf8`, not the 2-byte UTF-8 encoding — so this is a genuinely
/// single-byte-per-character field, not UTF-8 truncated mid-sequence as
/// originally assumed. [text] is silently truncated to Latin-1's range
/// (U+0000-U+00FF) by [String.codeUnitAt] via [latin1.encode] throwing on
/// anything outside it — callers passing names with characters outside
/// Latin-1 (e.g. many non-European scripts) will hit that, and there's no
/// known fallback behavior to fall back to since nothing wider than
/// Latin-1 was ever seen in the capture.
void _writeFixedString(Uint8List out, int offset, int size, String text) {
  final bytes = latin1.encode(text);
  final n = bytes.length < size ? bytes.length : size;
  out.setRange(offset, offset + n, bytes);
}

/// **Corrected 2026-08-16** — the per-point UUID/name fields at
/// [_kWaypointUuidOffset]/[_kWaypointNameOffset] were previously always
/// filled with a fresh random UUID and the point's GPX name, regardless of
/// [_kPlainPositionMarkerByte]. The one real GPX-import capture available
/// shows a plain-position point's UUID field all-zero and its name field
/// empty — those fields only carry real content on a `0x00`-marker point
/// that references an actual, pre-existing catalog waypoint (a shape this
/// client never uses, since it has no such waypoint to reference). This
/// zero-filled placeholder replaces the old random-UUID generator.
Uint8List _zeroWaypointUuid() => Uint8List(_kWaypointUuidSize);

/// Encodes one 283-byte waypoint record. [routeName] is only non-null for
/// the first record in a route (see this file's top doc comment).
/// [pointCount] is the route's total point count, needed for the first
/// record's prefix tail (see [_firstRecordPrefixTail]) — ignored for
/// non-first records. [syncTime] is the sync timestamp shared by every
/// record in the route (see [_waypointMetadataBlockPrefix]'s doc comment
/// for why this must be computed once per route, not once per record).
/// [uuid] defaults to [_zeroWaypointUuid] (see its own doc comment);
/// overridable for tests that want to check the rest of a record
/// byte-for-byte against a real `0x00`-marker capture, which does carry a
/// real per-waypoint UUID.
Uint8List _encodeRecord(
  RoutePoint point, {
  String? routeName,
  required int pointCount,
  required Uint8List metadataBlock,
  int routeMarkerByte = _kPlainPositionMarkerByte,
  Uint8List Function() uuid = _zeroWaypointUuid,
}) {
  final out = Uint8List(_kRecordSize);
  if (routeName != null) {
    _writeFixedString(out, 0, _kRouteNameSize, routeName);
    final tail = _firstRecordPrefixTail(pointCount, routeMarkerByte);
    out.setRange(_kRouteNameSize, _kRouteNameSize + tail.length, tail);
  } else {
    final prefix = _laterRecordPrefix(routeMarkerByte);
    out.setRange(0, prefix.length, prefix);
  }
  final bd = ByteData.view(out.buffer);
  bd.setInt32(_kLatOffset, _toSemicircle(point.lat), Endian.little);
  bd.setInt32(_kLonOffset, _toSemicircle(point.lon), Endian.little);
  out.setRange(_kWaypointUuidOffset, _kWaypointUuidOffset + _kWaypointUuidSize, uuid());
  // Left empty (all-zero, [_writeFixedString]'s default for an empty
  // string) for a plain-position point, matching the real GPX-import
  // capture — see [_zeroWaypointUuid]'s doc comment. [point.name] is still
  // used elsewhere (e.g. this client's own UI), just not written into this
  // wire field, which the real app reserves for an actual catalog
  // waypoint's name.
  _writeFixedString(out, _kWaypointNameOffset, _kWaypointNameSize, routeMarkerByte == _kPlainPositionMarkerByte ? '' : point.name);
  out.setRange(
    _kWaypointMetadataOffset,
    _kWaypointMetadataOffset + metadataBlock.length,
    metadataBlock,
  );
  return out;
}

/// The fixed 30-byte trailer prefix observed after the last waypoint
/// record, before the 4-byte checksum — see this file's top doc comment.
/// Confirmed byte-for-byte identical across both known captures (4 and 8
/// points).
final Uint8List _trailerPrefix = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, //
  0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x0a, 0x00, 0x00, 0x00,
]);

/// Standard CRC-32/IEEE lookup table (same polynomial as zlib/gzip/PNG,
/// confirmed by matching real captured checksums exactly) — reimplemented
/// here rather than pulling in a package dependency for one small,
/// completely standard algorithm.
final List<int> _crc32Table = List<int>.generate(256, (i) {
  var c = i;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
  }
  return c;
});

int _crc32(Uint8List data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _crc32Table[(b ^ crc) & 0xFF] ^ (crc >> 8);
  }
  return (~crc) & 0xFFFFFFFF;
}

/// Computes the trailer's 4-byte checksum for a full `tSyncData` payload
/// built so far (preamble + all waypoint records, i.e. everything except
/// the trailer itself) — see this file's top doc comment for how this
/// range was derived. [bodyBeforeTrailer] is the payload up to but not
/// including [_trailerPrefix].
Uint8List _computeTrailerChecksum(Uint8List bodyBeforeTrailer) {
  // The checksum covers payload[1 : payload.length - 10], i.e. everything
  // in the full payload except its first byte and the final 10 bytes
  // (checksum field + the 6-byte `01 00 0a 00 00 00` right before it).
  // Relative to bodyBeforeTrailer (= payload minus the trailer entirely,
  // which is 30 + 4 = 34 bytes), the checksummed region is
  // bodyBeforeTrailer[1:] followed by the trailer's own first 24 bytes
  // (_trailerPrefix minus its last 6 bytes).
  final region = Uint8List(bodyBeforeTrailer.length - 1 + (_trailerPrefix.length - 6));
  region.setRange(0, bodyBeforeTrailer.length - 1, bodyBeforeTrailer, 1);
  region.setRange(bodyBeforeTrailer.length - 1, region.length, _trailerPrefix, 0);
  final crc = _crc32(region);
  final out = Uint8List(4);
  ByteData.view(out.buffer).setUint32(0, crc, Endian.little);
  return out;
}

/// Builds the full `tSyncData` (`0x08b9`) payload for [routeName] and its
/// [points], in order — the header/schema preamble followed by one fixed
/// record per point, the first carrying [routeName], followed by the
/// trailer (see this file's top doc comment). [uuidGenerator] overrides
/// the per-waypoint UUID source (see [_encodeRecord]); only meant for
/// tests.
///
/// Verified byte-for-byte against two independent real captures with
/// different point counts (4 and 8), including the trailer checksum, so
/// this is not limited to any particular point count. [syncTime] overrides
/// the sync timestamp embedded in every record (see
/// [_waypointMetadataBlockPrefix]'s doc comment); defaults to
/// [DateTime.now] and is only meant to be overridden by tests that need a
/// byte-for-byte match against a fixed historical capture. [routeMarkerByte]
/// defaults to [_kPlainPositionMarkerByte] (see its own doc comment for
/// why) — only meant to be overridden by tests reproducing the other real
/// capture available (real, named waypoint references, marker `0x00`),
/// since this client never has a real catalog-waypoint UUID to send there.
Uint8List encodeRoute(
  String routeName,
  List<RoutePoint> points, {
  Uint8List Function() uuidGenerator = _zeroWaypointUuid,
  DateTime? syncTime,
  int routeMarkerByte = _kPlainPositionMarkerByte,
}) {
  if (points.isEmpty) {
    throw ArgumentError.value(points, 'points', 'a route needs at least one point');
  }
  final headerLength = _recordSchemaHeaderTemplate.length;
  final bodyLength = headerLength + _kRecordSize * points.length;
  final totalPayloadLength = bodyLength + _trailerPrefix.length + 4;
  final header = _buildRecordSchemaHeader(totalPayloadLength);
  final metadataBlock = _waypointMetadataBlock(syncTime ?? DateTime.now());

  final body = Uint8List(bodyLength);
  body.setRange(0, headerLength, header);
  var offset = headerLength;
  for (var i = 0; i < points.length; i++) {
    final record = _encodeRecord(
      points[i],
      routeName: i == 0 ? routeName : null,
      pointCount: points.length,
      metadataBlock: metadataBlock,
      routeMarkerByte: routeMarkerByte,
      uuid: uuidGenerator,
    );
    body.setRange(offset, offset + _kRecordSize, record);
    offset += _kRecordSize;
  }

  final out = Uint8List(bodyLength + _trailerPrefix.length + 4);
  out.setRange(0, bodyLength, body);
  out.setRange(bodyLength, bodyLength + _trailerPrefix.length, _trailerPrefix);
  out.setRange(bodyLength + _trailerPrefix.length, out.length, _computeTrailerChecksum(body));
  return out;
}

/// Thrown by [syncRoute] when the plotter never sends `tSyncAck`/`tSyncDone`
/// within the given timeout — most likely means [routeSyncPort] isn't
/// actually fixed the way it appeared to be in the one capture this is
/// based on, or the plotter rejected something about the handshake/payload.
class RouteSyncTimeoutException implements Exception {
  final String stage;
  const RouteSyncTimeoutException(this.stage);
  @override
  String toString() => 'route sync: no response from the plotter ($stage)';
}

/// Connects to the plotter's route/waypoint sync channel, runs the full
/// handshake documented above, and pushes [routeName]/[points] as one
/// route. Opens and closes its own short-lived connection — unlike
/// [HelmClient] (helm_client.dart), there's no reason to keep this
/// connection open past a single sync, so this is a one-shot function
/// rather than a stateful client class.
///
/// Throws [RouteSyncTimeoutException] if the plotter doesn't acknowledge
/// the handshake ([tSyncAck]) or the data ([tSyncDone]) within [timeout],
/// and whatever [Socket.connect] throws (e.g. [SocketException]) if the
/// connection itself fails.
Future<void> syncRoute(
  String host,
  String routeName,
  List<RoutePoint> points, {
  int port = routeSyncPort,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final rxBuf = BytesBuilder(copy: false);
    // broadcast: awaitType() below is called twice (tSyncAck, then
    // tSyncData), each via its own firstWhere() subscription — a plain
    // single-subscription controller would let only the first of those
    // actually attach.
    final frames = StreamController<HelmFrame>.broadcast();
    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        rxBuf.add(chunk);
        final buf = rxBuf.toBytes();
        final result = parseFrames(buf);
        rxBuf.clear();
        rxBuf.add(buf.sublist(result.consumed));
        for (final f in result.frames) {
          frames.add(f);
        }
      },
      onError: frames.addError,
      onDone: () => frames.close(),
      cancelOnError: true,
    );

    Future<HelmFrame> awaitType(int type, String stage) async {
      try {
        return await frames.stream
            .firstWhere((f) => f.type == type)
            .timeout(timeout, onTimeout: () => throw RouteSyncTimeoutException(stage));
      } on StateError {
        // Stream closed (onDone) before a matching frame arrived.
        throw RouteSyncTimeoutException(stage);
      }
    }

    socket.add(buildFrame(tHello, _u16le(routeSyncPort)));
    socket.add(buildFrame(tToken, randomToken()));
    socket.add(buildFrame(tSyncBegin, const [0x02]));
    await awaitType(tSyncAck, 'waiting for tSyncAck after tSyncBegin');

    socket.add(buildFrame(tSyncData, encodeRoute(routeName, points)));
    await awaitType(tSyncDone, 'waiting for tSyncDone after tSyncData');

    await sub.cancel();
    await frames.close();
  } finally {
    socket.destroy();
  }
}

Uint8List _u16le(int v) {
  final out = Uint8List(2);
  ByteData.view(out.buffer).setUint16(0, v, Endian.little);
  return out;
}
