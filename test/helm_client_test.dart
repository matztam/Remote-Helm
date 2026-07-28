import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/helm_client.dart';
import 'package:remote_helm/helm/protocol.dart';

void main() {
  test('sends a periodic no-op tTouch keepalive once a touch context is granted', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final receivedTypes = <int>[];
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

    final touchCountAfterHandshake = receivedTypes.where((t) => t == tTouch).length;
    expect(touchCountAfterHandshake, 0);

    await Future<void>.delayed(const Duration(milliseconds: 2200));

    final touchCountAfterWait = receivedTypes.where((t) => t == tTouch).length;
    expect(touchCountAfterWait, greaterThanOrEqualTo(2));
  });
}
