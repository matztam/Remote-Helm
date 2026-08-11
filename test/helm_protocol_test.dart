// Verifies the Dart port of the Helm wire protocol against concrete byte
// sequences confirmed from a real packet capture during reverse engineering
// (see the PROTOCOL.md notes in github.com/Mrkvak/helm-linux, and this
// project's own capture analysis) — not just against the Python reference's
// own logic, so a bug shared between both ports wouldn't be masked.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/protocol.dart';

void main() {
  group('buildFrame', () {
    test('encodes header with 0xBEEF magic and little-endian length', () {
      final frame = buildFrame(0x1644, const []);
      expect(frame.length, 8);
      // type = 0x1644 LE
      expect(frame[0], 0x44);
      expect(frame[1], 0x16);
      // magic = 0xBEEF LE
      expect(frame[2], 0xEF);
      expect(frame[3], 0xBE);
      // length = 0
      expect(frame.sublist(4, 8), [0, 0, 0, 0]);
    });

    test('appends payload after the 8-byte header', () {
      final frame = buildFrame(0x0aa9, [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(frame.length, 16);
      expect(frame.sublist(8), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('T_HELLO payload matches the observed capture: type=0x083f, payload=0x9531 LE', () {
      final frame = buildFrame(tHello, [0x31, 0x95]);
      // Directly observed on the wire in PCAPdroid captures against a real
      // GPSMAP unit: "3f08efbe02000000" + hello tag bytes.
      expect(frame.sublist(0, 8), [0x3f, 0x08, 0xef, 0xbe, 0x02, 0x00, 0x00, 0x00]);
      expect(frame.sublist(8), [0x31, 0x95]);
    });
  });

  group('parseFrames', () {
    test('decodes a single well-formed frame', () {
      final buf = buildFrame(0x1648, [0x0b, 0x00, 0x00, 0x00]);
      final result = parseFrames(buf);
      expect(result.frames, hasLength(1));
      expect(result.frames.single.type, 0x1648);
      expect(result.frames.single.payload, [0x0b, 0x00, 0x00, 0x00]);
      expect(result.consumed, buf.length);
      expect(result.frames.single.endOffset, buf.length);
    });

    test('decodes multiple concatenated frames', () {
      final a = buildFrame(0x1648, [1, 0, 0, 0]);
      final b = buildFrame(0x1648, [2, 0, 0, 0]);
      final buf = Uint8List.fromList([...a, ...b]);
      final result = parseFrames(buf);
      expect(result.frames, hasLength(2));
      expect(result.frames[0].payload, [1, 0, 0, 0]);
      expect(result.frames[1].payload, [2, 0, 0, 0]);
      expect(result.consumed, buf.length);
    });

    test('leaves a trailing partial frame unconsumed', () {
      final complete = buildFrame(0x1648, [1, 0, 0, 0]);
      final partial = Uint8List.fromList([0x4c, 0x16, 0xef, 0xbe, 0x18, 0x00]); // truncated header
      final buf = Uint8List.fromList([...complete, ...partial]);
      final result = parseFrames(buf);
      expect(result.frames, hasLength(1));
      expect(result.consumed, complete.length);
    });

    test('resyncs past garbage bytes to find the next 0xBEEF marker', () {
      final garbage = [0xff, 0xff, 0xff];
      final frame = buildFrame(0x1648, [9, 0, 0, 0]);
      final buf = Uint8List.fromList([...garbage, ...frame]);
      final result = parseFrames(buf);
      expect(result.frames, hasLength(1));
      expect(result.frames.single.payload, [9, 0, 0, 0]);
    });

    test('returns no frames and consumes nothing on pure garbage', () {
      final buf = Uint8List.fromList([0xff, 0xff, 0xff, 0xff]);
      final result = parseFrames(buf);
      expect(result.frames, isEmpty);
      expect(result.consumed, 0);
    });
  });

  group('fx (Q16.16 fixed point)', () {
    test('0.0 maps to 0', () => expect(fx(0.0), 0));
    test('1.0 maps to touchUnity (65536)', () => expect(fx(1.0), touchUnity));
    test('0.5 maps to 32768', () => expect(fx(0.5), 32768));
    test('clamps negative input to 0', () => expect(fx(-0.2), 0));
    test('clamps >1.0 input to touchUnity', () => expect(fx(1.2), touchUnity));

    test('matches a concrete value observed in a real capture: '
        'a click at normalized x≈0.1232 encoded to 0x1f89 (8073)', () {
      // From this project's own pcap analysis of a real single-tap
      // (top-left corner click), the plotter received X = 0x00001f89 = 8073.
      // 8073 / 65536 ≈ 0.12319, so encoding that fraction must reproduce it
      // (within the same rounding the capture itself was produced with).
      expect(fx(8073 / 65536), 8073);
    });
  });

  group('encodeTouch', () {
    test('produces the exact 24-byte layout: ctx(4) count(4)=1 track(1) x(4) y(4) down(4) pad(3)', () {
      final ctx = Uint8List.fromList([0xcd, 0x63, 0xff, 0x4a]);
      final out = encodeTouch(ctx, 0.5, 0.25, true);
      expect(out.length, 24);
      expect(out.sublist(0, 4), ctx); // ctx_id
      expect(out.sublist(4, 8), [1, 0, 0, 0]); // count = 1 LE
      expect(out[8], 0); // track_id
      final bd = ByteData.sublistView(out);
      expect(bd.getUint32(9, Endian.little), fx(0.5)); // x
      expect(bd.getUint32(13, Endian.little), fx(0.25)); // y
      expect(bd.getUint32(17, Endian.little), 1); // down
      expect(out.sublist(21, 24), [0, 0, 0]); // padding
    });

    test('down=false encodes a zero down field', () {
      final ctx = Uint8List.fromList([1, 2, 3, 4]);
      final out = encodeTouch(ctx, 0.1, 0.9, false);
      final bd = ByteData.sublistView(out);
      expect(bd.getUint32(17, Endian.little), 0);
    });

    test('matches bytes actually observed on the wire in this project\'s '
        'own pcap capture: ctx=0x4aff63cd, touch-down at X=8073, Y=14777', () {
      final ctx = Uint8List.fromList([0xcd, 0x63, 0xff, 0x4a]);
      final out = encodeTouch(ctx, 8073 / 65536, 14777 / 65536, true);
      expect(_toHex(out), 'cd63ff4a0100000000891f0000b939000001000000000000');
    });
  });

  group('encodePinch', () {
    test('produces the exact 40-byte layout for two fingers', () {
      final ctx = Uint8List.fromList([1, 2, 3, 4]);
      final out = encodePinch(ctx, 0.4, 0.5, 0.6, 0.5, true);
      expect(out.length, 40);
      expect(out.sublist(0, 4), ctx);
      expect(out.sublist(4, 8), [2, 0, 0, 0]); // count = 2
      expect(out[8], 0); // finger 0 track_id
      final bd = ByteData.sublistView(out);
      expect(bd.getUint32(9, Endian.little), fx(0.4));
      expect(bd.getUint32(13, Endian.little), fx(0.5));
      expect(out[17], 1); // down0
      expect(out[18], 1); // finger 1 track_id
      expect(bd.getUint32(22, Endian.little), fx(0.6));
      expect(bd.getUint32(26, Endian.little), fx(0.5));
      expect(out[30], 1); // down1
      expect(out.sublist(31, 40), List.filled(9, 0)); // padding
    });

    test('down=false sets both down bytes to 0', () {
      final ctx = Uint8List.fromList([1, 2, 3, 4]);
      final out = encodePinch(ctx, 0.4, 0.5, 0.6, 0.5, false);
      expect(out[17], 0);
      expect(out[30], 0);
    });
  });
}

String _toHex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
