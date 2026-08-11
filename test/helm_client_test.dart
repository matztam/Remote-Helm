import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/helm_client.dart';
import 'package:remote_helm/helm/protocol.dart';

void main() {
  test(
    'sends a periodic tSubscribe(8,10,6) keepalive once a touch context is granted, '
    'never a synthetic tTouch',
    () async {
      late StreamSubscription<Socket> serverSub;
      final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final receivedTypes = <int>[];
      final subscribeIndicesReceived = <int>[];
      const grantedCtx = [0x01, 0x02, 0x03, 0x04];

      serverSub = fakeServer.listen((client) {
        client.listen((data) {
          // Parse every complete frame out of this chunk (the test only ever
          // sends whole frames per write from HelmClient, so no reassembly
          // needed) and reply to tAcquire with a context grant.
          var offset = 0;
          while (offset + 8 <= data.length) {
            final type = data[offset] | (data[offset + 1] << 8);
            final length = data[offset + 4] |
                (data[offset + 5] << 8) |
                (data[offset + 6] << 16) |
                (data[offset + 7] << 24);
            receivedTypes.add(type);
            if (type == tSubscribe && length == 4) {
              subscribeIndicesReceived.add(
                ByteData.sublistView(data, offset + 8, offset + 8 + 4).getUint32(0, Endian.little),
              );
            }
            offset += 8 + length;
            if (type == tAcquire) {
              final reply = buildFrame(tContext, [0, 0, 0, 1, ...grantedCtx]);
              client.add(reply);
            }
          }
        });
      });
      addTearDown(() async {
        await serverSub.cancel();
        await fakeServer.close();
      });

      final client = HelmClient(
        InternetAddress.loopbackIPv4.address,
        port: fakeServer.port,
        token: Uint8List.fromList(List.filled(8, 0)),
      );
      addTearDown(client.close);

      await client.connect(timeout: const Duration(seconds: 2));

      expect(client.touchCtx, isNotNull);
      expect(client.touchCtx, grantedCtx);

      // subscribeIndices (the initial handshake's own subscription list) is
      // 16 entries long; anything past that came from the keepalive.
      final subscribeCountAfterHandshake = subscribeIndicesReceived.length;
      expect(subscribeCountAfterHandshake, subscribeIndices.length);

      await Future<void>.delayed(const Duration(milliseconds: 10200));

      // Two 5s ticks should have fired by now, each re-sending [8, 10, 6] —
      // matching the real app's own keepalive exactly (see helm_client.dart's
      // top doc comment for the packet capture this was confirmed against).
      final newIndices = subscribeIndicesReceived.skip(subscribeCountAfterHandshake).toList();
      expect(newIndices.length, greaterThanOrEqualTo(6));
      for (var i = 0; i < newIndices.length; i += 3) {
        expect(newIndices.sublist(i, i + 3), [8, 10, 6]);
      }

      // Never a synthetic tTouch: the whole point of switching to tSubscribe
      // was to avoid any interaction with touch/cursor state.
      expect(receivedTypes.where((t) => t == tTouch).length, 0);
    },
  );

  test('keepalive keeps ticking regardless of real touch activity', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final receivedTouchPayloads = <Uint8List>[];
    var subscribeCount = 0;
    const grantedCtx = [0x01, 0x02, 0x03, 0x04];

    serverSub = fakeServer.listen((client) {
      client.listen((data) {
        var offset = 0;
        while (offset + 8 <= data.length) {
          final type = data[offset] | (data[offset + 1] << 8);
          final length = data[offset + 4] |
              (data[offset + 5] << 8) |
              (data[offset + 6] << 16) |
              (data[offset + 7] << 24);
          if (type == tTouch) {
            receivedTouchPayloads.add(
              Uint8List.fromList(data.sublist(offset + 8, offset + 8 + length)),
            );
          }
          if (type == tSubscribe) subscribeCount++;
          offset += 8 + length;
          if (type == tAcquire) {
            final reply = buildFrame(tContext, [0, 0, 0, 1, ...grantedCtx]);
            client.add(reply);
          }
        }
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final client = HelmClient(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      token: Uint8List.fromList(List.filled(8, 0)),
    );
    addTearDown(client.close);

    await client.connect(timeout: const Duration(seconds: 2));
    expect(client.touchCtx, isNotNull);
    final subscribeCountAfterHandshake = subscribeCount;

    // A real touch mid-session must be sent exactly as given — the
    // keepalive (a different frame type entirely now) has no reason to
    // affect it, unlike the old synthetic-tTouch approach.
    client.touch(0.2, 0.3, true);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(receivedTouchPayloads.length, 1);
    final x = ByteData.sublistView(receivedTouchPayloads.single).getUint32(9, Endian.little);
    final y = ByteData.sublistView(receivedTouchPayloads.single).getUint32(13, Endian.little);
    expect(x, fx(0.2));
    expect(y, fx(0.3));

    await Future<void>.delayed(const Duration(milliseconds: 5300));

    // The keepalive tick still fires on schedule — it doesn't back off just
    // because there was real activity, since (being tSubscribe) it can't
    // cause the double-tap problem the old approach had.
    expect(subscribeCount, greaterThan(subscribeCountAfterHandshake));
  });
}
