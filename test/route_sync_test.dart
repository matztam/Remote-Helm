import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/protocol.dart';
import 'package:remote_helm/helm/route_sync.dart';

// The exact tSyncData (0x08b9) payload captured (PCAPdroid) from the real
// ActiveCaptain app syncing a 4-point GPX route ("AAAAAAAAA") to a real
// plotter — see route_sync.dart's top doc comment. Used here as a golden
// reference: if encodeRoute() ever stops matching this byte-for-byte for
// the exact same input, either the implementation regressed or the
// reference itself needs re-deriving (both worth knowing immediately).
const _capturedTSyncData =
    '03000021050000070f000000640000000200120500001e000000040000002e00000018000000'
    '8e00000001000000c8000f00c9000400ca000400cb0001000000010001000400020004000a00'
    '100014000a0015001400160002001700010018000400190004001a0004001e00010023000a00'
    '1f00100020000100210004002200080028003300290033002a0033002b0002002c0001002d00'
    '10003f00010041414141414141414100000000000004000000ffffffff020071779f277af723'
    '07b92f472232d1428f989d3cd67f7646e153616e64626a657267200000000000000000000000'
    '00000000000000000012001351590469515904691abed5440000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '00000000000000000000000000000000000000000000000000000000000000000000ffffffff'
    '0000000000000000000064b99e27e93d28077eac79c3922b429bbde3e168bac36354426af872'
    '6e736b6e7564000000000000000000000000000000000000000012001351590469515904691a'
    'bed5440000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '00000000000000000000000000ffffffff000000000000000000003639a127fb222707f496e7'
    '973afd47bf8d6049959ebb84db497267656e64776f0000000000000000000000000000000000'
    '000000000012001351590469515904691abed544000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '000000000000000000000000000000000000000000000000000000000000ffffffff00000000'
    '0000000000002c8ca02719cd1f0791eb8231505f47f2b5b164e00d8ed85d53616e64626a6572'
    '6720000000000000000000000000000000000000000012001351590469515904691abed54400'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000000000000000'
    '000000000000000000ffffffff00000000000000000001000a000000b4c2cab1';

// The per-waypoint UUIDs captured alongside the payload above — fed back
// in via encodeRoute's uuidGenerator override so the byte-for-byte
// comparison isn't defeated by that field being random in normal use.
final _capturedWaypointUuids = [
  Uint8List.fromList(const [
    0xb9, 0x2f, 0x47, 0x22, 0x32, 0xd1, 0x42, 0x8f, //
    0x98, 0x9d, 0x3c, 0xd6, 0x7f, 0x76, 0x46, 0xe1,
  ]),
  Uint8List.fromList(const [
    0x7e, 0xac, 0x79, 0xc3, 0x92, 0x2b, 0x42, 0x9b, //
    0xbd, 0xe3, 0xe1, 0x68, 0xba, 0xc3, 0x63, 0x54,
  ]),
  Uint8List.fromList(const [
    0xf4, 0x96, 0xe7, 0x97, 0x3a, 0xfd, 0x47, 0xbf, //
    0x8d, 0x60, 0x49, 0x95, 0x9e, 0xbb, 0x84, 0xdb,
  ]),
  Uint8List.fromList(const [
    0x91, 0xeb, 0x82, 0x31, 0x50, 0x5f, 0x47, 0xf2, //
    0xb5, 0xb1, 0x64, 0xe0, 0x0d, 0x8e, 0xd8, 0x5d,
  ]),
];

void main() {
  test('encodeRoute matches a real captured tSyncData payload byte-for-byte', () {
    final points = [
      const RoutePoint(name: 'Sandbjerg Vig - Mindertiefen', lat: 55.719726, lon: 10.041321),
      const RoutePoint(name: 'Bjørnsknude Flak', lat: 55.715648, lon: 10.064805),
      const RoutePoint(name: 'Irgendwo', lat: 55.729377, lon: 10.058734),
      const RoutePoint(name: 'Sandbjerg Vig', lat: 55.725664, lon: 10.018439),
    ];

    var uuidIndex = 0;
    final encoded = encodeRoute(
      'AAAAAAAAA',
      points,
      uuidGenerator: () => _capturedWaypointUuids[uuidIndex++],
    );

    expect(encoded.length, _capturedTSyncData.length ~/ 2);
    expect(encoded.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), _capturedTSyncData);
  });

  test('encodeRoute rejects an empty route', () {
    expect(() => encodeRoute('empty', const []), throwsArgumentError);
  });

  test('encodeRoute refuses point counts other than 4 (trailer not understood yet)', () {
    final onePoint = [const RoutePoint(name: 'only one', lat: 0, lon: 0)];
    expect(() => encodeRoute('one', onePoint), throwsUnimplementedError);
  });

  test('syncRoute sends hello/token/begin/data in order and awaits ack/done', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final receivedTypes = <int>[];

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);
      client.listen((chunk) {
        buf.add(chunk);
        final bytes = buf.toBytes();
        final result = parseFrames(bytes);
        buf.clear();
        buf.add(bytes.sublist(result.consumed));
        for (final f in result.frames) {
          receivedTypes.add(f.type);
          if (f.type == tSyncBegin) {
            client.add(buildFrame(tSyncAck, const [0x01]));
          } else if (f.type == tSyncData) {
            client.add(buildFrame(tSyncDone));
          }
        }
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final points = [
      const RoutePoint(name: 'a', lat: 1, lon: 2),
      const RoutePoint(name: 'b', lat: 3, lon: 4),
      const RoutePoint(name: 'c', lat: 5, lon: 6),
      const RoutePoint(name: 'd', lat: 7, lon: 8),
    ];

    await syncRoute(
      InternetAddress.loopbackIPv4.address,
      'r',
      points,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );

    expect(receivedTypes, [tHello, tToken, tSyncBegin, tSyncData]);
  });

  test('syncRoute throws RouteSyncTimeoutException if the plotter never acks', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    serverSub = fakeServer.listen((client) {
      // Accept the connection but never reply — simulates an unreachable
      // or non-responsive sync port.
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final points = [
      const RoutePoint(name: 'a', lat: 1, lon: 2),
      const RoutePoint(name: 'b', lat: 3, lon: 4),
      const RoutePoint(name: 'c', lat: 5, lon: 6),
      const RoutePoint(name: 'd', lat: 7, lon: 8),
    ];

    await expectLater(
      syncRoute(
        InternetAddress.loopbackIPv4.address,
        'r',
        points,
        port: fakeServer.port,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<RouteSyncTimeoutException>()),
    );
  });
}
