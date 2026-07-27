/// Garmin ActiveCaptain "Helm" wire protocol — frame encoding/decoding.
///
/// Ported from the reverse-engineered Python reference implementation
/// (github.com/Mrkvak/helm-linux, `helm/helm_client.py`), itself recovered
/// from a live capture plus static analysis of the ActiveCaptain app's
/// native core (`libgmm.so`).
///
/// Frame format: `[u16 type LE][u16 0xBEEF][u32 length LE][payload]`
library;

import 'dart:typed_data';

const int helmPort = 51200;
const int helmMagic = 0xBEEF;
const int touchUnity = 65536; // Q16.16 fixed point scale for touch coords

// Message types.
const int tHello = 0x083F;
const int tToken = 0x0AA9;
const int tSubscribe = 0x1648;
const int tAcquire = 0x1644; // empty: client requests a touch context
const int tContext = 0x1645; // plotter reply: [u32 1][u32 touch_ctx_id]
const int tTouch = 0x164C;

const int helloTag = 0x9531; // payload of the 0x083f hello (2 bytes LE)

/// Device-select + subscription indices the app sends, in order (from
/// capture). 0x0b selects the plotter; the rest subscribe to data/pages.
/// Replaying the full set matches the app exactly.
const List<int> subscribeIndices = [
  0x0b, 0x00, 0x01, 0x06, 0x08, 0x0a, 0x03, 0x04, 0x05,
  0x09, 0x01, 0x08, 0x00, 0x0a, 0x02, 0x0c, //
];

/// A single decoded `[type, payload]` frame, plus the offset in the source
/// buffer right after this frame ends (so callers can truncate a receive
/// buffer to "everything up to and including this frame" without relying on
/// object identity across `Uint8List` views).
class HelmFrame {
  final int type;
  final Uint8List payload;
  final int endOffset;
  const HelmFrame(this.type, this.payload, this.endOffset);
}

/// Builds one wire frame: `[u16 type][u16 0xBEEF][u32 length][payload]`.
Uint8List buildFrame(int type, [List<int> payload = const []]) {
  final out = Uint8List(8 + payload.length);
  final bd = ByteData.view(out.buffer);
  bd.setUint16(0, type, Endian.little);
  bd.setUint16(2, helmMagic, Endian.little);
  bd.setUint32(4, payload.length, Endian.little);
  out.setRange(8, 8 + payload.length, payload);
  return out;
}

/// Parses as many complete `[type][0xBEEF][length][payload]` frames as
/// possible out of `buf`, starting at byte 0. Returns the parsed frames and
/// the number of bytes consumed (the caller should keep any remaining tail
/// buffered for the next read, mirroring `parse_frames`/`_rxbuf` in the
/// Python client). Resyncs to the next `0xBEEF` marker on corruption, same as
/// the reference implementation.
({List<HelmFrame> frames, int consumed}) parseFrames(Uint8List buf) {
  final frames = <HelmFrame>[];
  var off = 0;
  final n = buf.length;
  while (off + 8 <= n) {
    final marker = buf[off + 2] | (buf[off + 3] << 8);
    if (marker != helmMagic) {
      final nxt = _findMagicMarker(buf, off + 1);
      if (nxt < 2) break;
      off = nxt - 2;
      continue;
    }
    final bd = ByteData.sublistView(buf, off, off + 8);
    final mtype = bd.getUint16(0, Endian.little);
    final length = bd.getUint32(4, Endian.little);
    if (off + 8 + length > n) break;
    final frameEnd = off + 8 + length;
    frames.add(HelmFrame(mtype, Uint8List.sublistView(buf, off + 8, frameEnd), frameEnd));
    off = frameEnd;
  }
  return (frames: frames, consumed: off);
}

/// Finds the next `EF BE` (0xBEEF little-endian) byte marker at or after
/// [start], returning the index of the low byte (`EF`), or -1 if absent.
int _findMagicMarker(Uint8List buf, int start) {
  for (var i = start; i + 1 < buf.length; i++) {
    if (buf[i] == 0xEF && buf[i + 1] == 0xBE) return i;
  }
  return -1;
}

/// Converts a normalized `[0,1]` coordinate to Q16.16 fixed point, clamped
/// to `[0, touchUnity]` (mirrors `_fx` in the Python client).
int fx(double v) {
  final scaled = (v * touchUnity).round();
  if (scaled < 0) return 0;
  if (scaled > touchUnity) return touchUnity;
  return scaled;
}

/// Single-finger `0x164c` payload (count=1, track_id 0). [ctx] is the
/// plotter-assigned touch context id (from `0x1645`). x,y normalized [0,1].
Uint8List encodeTouch(Uint8List ctx, double x, double y, bool down) {
  final out = Uint8List(24);
  final bd = ByteData.view(out.buffer);
  out.setRange(0, 4, ctx, 0);
  bd.setUint32(4, 1, Endian.little); // count = 1
  out[8] = 0; // track_id
  bd.setUint32(9, fx(x), Endian.little);
  bd.setUint32(13, fx(y), Endian.little);
  bd.setUint32(17, down ? 1 : 0, Endian.little);
  // bytes 21..24 stay zero (padding)
  return out;
}

/// Two-finger `0x164c` payload (count=2), matching the app byte-for-byte:
/// `[ctx][2] 00 [x0][y0][down0] 01 00 00 00 [x1][y1][down1] 00×9`.
/// Finger track_ids are 0 and 1.
Uint8List encodePinch(
  Uint8List ctx,
  double x0,
  double y0,
  double x1,
  double y1,
  bool down,
) {
  final out = Uint8List(40);
  final bd = ByteData.view(out.buffer);
  final d = down ? 1 : 0;
  out.setRange(0, 4, ctx, 0);
  bd.setUint32(4, 2, Endian.little); // count = 2
  out[8] = 0; // finger 0 track_id
  bd.setUint32(9, fx(x0), Endian.little);
  bd.setUint32(13, fx(y0), Endian.little);
  out[17] = d;
  out[18] = 1; // finger 1 track_id
  // bytes 19..21 stay zero
  bd.setUint32(22, fx(x1), Endian.little);
  bd.setUint32(26, fx(y1), Endian.little);
  out[30] = d;
  // bytes 31..40 stay zero (padding)
  return out;
}

/// UTF-8 helper for building the 8-byte session token payload, matching
/// Python's `os.urandom(8)` usage as an opaque client-chosen id (the plotter
/// never interprets it — callers may pass any 8 random bytes).
Uint8List randomToken() {
  final rnd = List<int>.generate(8, (_) => _fastRandomByte());
  return Uint8List.fromList(rnd);
}

int _rngState = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
int _fastRandomByte() {
  // xorshift32 — good enough for a non-cryptographic session token, avoids
  // pulling in dart:math's Random just for this.
  _rngState ^= (_rngState << 13) & 0xFFFFFFFF;
  _rngState ^= (_rngState >> 17);
  _rngState ^= (_rngState << 5) & 0xFFFFFFFF;
  return _rngState & 0xFF;
}
