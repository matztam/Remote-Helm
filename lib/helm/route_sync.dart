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
/// understand the semantics of — replayed byte-for-byte as
/// [_recordSchemaHeader], since deviating from what was actually observed
/// working risks the plotter rejecting or misinterpreting the sync),
/// followed by one **283-byte fixed-size record per waypoint**. The first
/// record's initial ~25 bytes are laid out completely differently from
/// every later record's — not the same fields at shifted offsets, but two
/// unrelated fixed sequences (see [_laterRecordPrefix] and
/// [_firstRecordPrefixTail]) — because the first record additionally
/// carries the route's own name. Confirmed against all 4 captured
/// waypoints: field offsets within a record (relative to the record's own
/// start) that this implementation actually uses:
///
/// | offset | size | content |
/// |---|---|---|
/// | 0x00 | 15 | route name (first record only), Latin-1, zero-padded/truncated |
/// | 0x19 | 4  | latitude, Garmin semicircle `int32` (`round(degrees * 2^31 / 180)`) |
/// | 0x1d | 4  | longitude, same encoding |
/// | 0x21 | 16 | per-waypoint UUID-shaped random bytes (differs on every waypoint; format/meaning not confirmed) |
/// | 0x31 | 10 | waypoint name, Latin-1, zero-padded/truncated (confirmed via a captured "ø" stored as the single byte `0xf8`, not 2-byte UTF-8 — this field is *not* UTF-8, unlike a first guess) |
/// | 0x4f | 15 | fixed bytes, identical across all 4 captured waypoints (plausibly a symbol/display-option field that just happened to be the same value in this one capture) |
///
/// Everything else in the 283-byte record was zero in every captured
/// waypoint and is left zero here too. This is the biggest known gap:
/// only ever tested against routes without an actual timestamp set by the
/// app itself — if the plotter turns out to require that non-zero to
/// accept a route from a from-scratch client (rather than one replaying
/// values the app itself generated), that would need a fresh capture to
/// pin down.
///
/// ### ⚠ Known-incomplete: the trailer after the last record
///
/// The captured `tSyncData` payload has 34 bytes *after* the last
/// waypoint record (`158 + 283×4 = 1290`, but the actual payload was
/// 1324 bytes) that this implementation does not yet understand or
/// reproduce correctly for an arbitrary point count — it was only ever
/// tested with exactly 4 points. The last 4 of those 34 bytes look
/// checksum-shaped, but neither CRC-32 nor Adler-32 over any prefix of
/// the payload matched, so it isn't reproduced here at all (an unknown
/// trailer with no plausible fallback beats emitting a definitely-wrong
/// checksum). **This has only been verified to build the exact captured
/// route; sending anything with a different point count, or relying on
/// the plotter to actually accept the sync rather than silently reject
/// it, needs live verification against a real plotter before trusting
/// this beyond that one case.**
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
/// them, and there's a `ffffffff` marker in both, at different offsets."
///
/// Non-first records: 11 zero bytes, `ffffffff`, 10 more zero bytes.
final Uint8List _laterRecordPrefix = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, //
  0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00,
]);

/// Bytes 15..24 (10 bytes) of the first record's prefix — i.e. everything
/// after its 15-byte route-name slot (bytes 0..14, written separately via
/// [_writeFixedString]) and before [_kLatOffset].
final Uint8List _firstRecordPrefixTail = Uint8List.fromList(
  [0x04, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x02, 0x00],
);

/// A 15-byte block after the waypoint name field, identical across all 4
/// captured waypoints despite them having different names/coordinates —
/// unlike [_routeMetadataBlock], this repeats on *every* record, not just
/// the first. Plausibly a symbol/display-option field that happened to be
/// the same for every waypoint in the one captured GPX (all used the
/// default "Waypoint" symbol) rather than something that's actually fixed
/// in general — replayed verbatim since there's no way to tell from a
/// single sample.
const int _kWaypointMetadataOffset = 0x4f;
final Uint8List _waypointMetadataBlock = Uint8List.fromList([
  0x12, 0x00, 0x13, 0x51, 0x59, 0x04, 0x69, 0x51, //
  0x59, 0x04, 0x69, 0x1a, 0xbe, 0xd5, 0x44,
]);

/// The 158-byte preamble observed before the first waypoint record in
/// every `tSyncData` payload — see this file's top doc comment for why
/// it's replayed verbatim rather than reconstructed field-by-field.
final Uint8List _recordSchemaHeader = Uint8List.fromList([
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

final Random _uuidRandom = Random();

/// A 16-byte value confirmed to differ across every captured waypoint
/// (never all-zero, never repeated) — almost certainly a per-waypoint
/// UUID, though its exact format (if it's meant to be a standard UUID
/// variant/version at all) wasn't verified. Random bytes are used here
/// since the plotter is only ever going to see values this client itself
/// generated — nothing observed suggests it needs to match any particular
/// format, only to be present and (presumably) unique per waypoint.
Uint8List _randomWaypointUuid() {
  return Uint8List.fromList(List<int>.generate(_kWaypointUuidSize, (_) => _uuidRandom.nextInt(256)));
}

/// Encodes one 283-byte waypoint record. [routeName] is only non-null for
/// the first record in a route (see this file's top doc comment).
/// [uuid] defaults to [_randomWaypointUuid]; overridable so tests can
/// check the rest of a record byte-for-byte against a real capture
/// without the per-waypoint UUID (necessarily random/unique in practice)
/// getting in the way.
Uint8List _encodeRecord(
  RoutePoint point, {
  String? routeName,
  Uint8List Function() uuid = _randomWaypointUuid,
}) {
  final out = Uint8List(_kRecordSize);
  if (routeName != null) {
    _writeFixedString(out, 0, _kRouteNameSize, routeName);
    out.setRange(_kRouteNameSize, _kRouteNameSize + _firstRecordPrefixTail.length, _firstRecordPrefixTail);
  } else {
    out.setRange(0, _laterRecordPrefix.length, _laterRecordPrefix);
  }
  final bd = ByteData.view(out.buffer);
  bd.setInt32(_kLatOffset, _toSemicircle(point.lat), Endian.little);
  bd.setInt32(_kLonOffset, _toSemicircle(point.lon), Endian.little);
  out.setRange(_kWaypointUuidOffset, _kWaypointUuidOffset + _kWaypointUuidSize, uuid());
  _writeFixedString(out, _kWaypointNameOffset, _kWaypointNameSize, point.name);
  out.setRange(
    _kWaypointMetadataOffset,
    _kWaypointMetadataOffset + _waypointMetadataBlock.length,
    _waypointMetadataBlock,
  );
  return out;
}

/// The 34-byte trailer observed after the last waypoint record — see this
/// file's top doc comment's "Known-incomplete" section. Only ever captured
/// following a 4-point route; [encodeRoute] refuses any other point count
/// rather than guess how (or whether) this needs to change, since the
/// last 4 bytes look checksum-shaped but don't match CRC-32 or Adler-32
/// over anything tried, so there's no known way to recompute them for a
/// different route.
final Uint8List _trailerFor4Points = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, //
  0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x0a, 0x00, 0x00, 0x00, 0xb4, 0xc2, 0xca, 0xb1, //
]);

/// Builds the full `tSyncData` (`0x08b9`) payload for [routeName] and its
/// [points], in order — the header/schema preamble followed by one fixed
/// record per point, the first carrying [routeName]. [uuidGenerator]
/// overrides the per-waypoint UUID source (see [_encodeRecord]); only
/// meant for tests.
///
/// Only verified against exactly 4 points (the one real capture this is
/// based on) — see [_trailerFor4Points] for why other counts aren't
/// supported yet rather than silently sent with a probably-wrong trailer.
Uint8List encodeRoute(
  String routeName,
  List<RoutePoint> points, {
  Uint8List Function() uuidGenerator = _randomWaypointUuid,
}) {
  if (points.isEmpty) {
    throw ArgumentError.value(points, 'points', 'a route needs at least one point');
  }
  if (points.length != 4) {
    throw UnimplementedError(
      'encodeRoute has only been verified against a 4-point route (got ${points.length}) '
      '— the trailer after the last record is not understood well enough yet to '
      'generalize to other point counts. See this file\'s doc comment.',
    );
  }
  final out = Uint8List(
    _recordSchemaHeader.length + _kRecordSize * points.length + _trailerFor4Points.length,
  );
  out.setRange(0, _recordSchemaHeader.length, _recordSchemaHeader);
  var offset = _recordSchemaHeader.length;
  for (var i = 0; i < points.length; i++) {
    final record = _encodeRecord(
      points[i],
      routeName: i == 0 ? routeName : null,
      uuid: uuidGenerator,
    );
    out.setRange(offset, offset + _kRecordSize, record);
    offset += _kRecordSize;
  }
  out.setRange(offset, offset + _trailerFor4Points.length, _trailerFor4Points);
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
