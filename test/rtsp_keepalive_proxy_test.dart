import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/rtsp_keepalive_proxy.dart';

void main() {
  test('forwards handshake requests/responses unmodified, including bodies', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final receivedByServer = <String>[];
    serverSub = fakeServer.listen((client) {
      runZonedGuarded(() {
        final buf = StringBuffer();
        client.listen(
          (data) {
            buf.write(String.fromCharCodes(data));
            final text = buf.toString();
            if (!text.contains('\r\n\r\n')) return;
            receivedByServer.add(text);
            buf.clear();
            if (text.startsWith('DESCRIBE')) {
              const body = 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=helm\r\n';
              client.write(
                'RTSP/1.0 200 OK\r\n'
                'CSeq: 1\r\n'
                'Content-Type: application/sdp\r\n'
                'Content-Length: ${body.length}\r\n'
                '\r\n'
                '$body',
              );
            } else {
              client.write('RTSP/1.0 200 OK\r\nCSeq: 1\r\nSession: 42\r\n\r\n');
            }
          },
          onError: (Object _) {},
          onDone: () {},
        );
      }, (Object e, StackTrace st) {});
    }, onError: (Object _) {});
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final proxy = RtspKeepaliveProxy(
      realHost: InternetAddress.loopbackIPv4.address,
      realPort: fakeServer.port,
      keepaliveInterval: const Duration(seconds: 30), // won't fire during this test
    );
    addTearDown(proxy.stop);
    final localPort = await proxy.start();

    final client = await Socket.connect(InternetAddress.loopbackIPv4, localPort);
    addTearDown(client.close);
    final responses = StringBuffer();
    client.listen((data) => responses.write(String.fromCharCodes(data)));

    client.write('DESCRIBE rtsp://plotter/helm_1280x720.h264 RTSP/1.0\r\nCSeq: 1\r\n\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(receivedByServer, hasLength(1));
    expect(receivedByServer.first, startsWith('DESCRIBE'));
    expect(responses.toString(), contains('200 OK'));
    expect(responses.toString(), contains('s=helm'));
  });

  test('injects a keepalive on the same connection after PLAY, and swallows its response', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final receivedByServer = <String>[];
    serverSub = fakeServer.listen((client) {
      runZonedGuarded(() {
        final buf = StringBuffer();
        client.listen(
          (data) {
            buf.write(String.fromCharCodes(data));
            final text = buf.toString();
            if (!text.contains('\r\n\r\n')) return;
            receivedByServer.add(text);
            buf.clear();
            final cseqMatch = RegExp(r'CSeq:\s*(\d+)').firstMatch(text);
            final cseq = cseqMatch?.group(1) ?? '1';
            client.write('RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nSession: 42\r\n\r\n');
          },
          onError: (Object _) {},
          onDone: () {},
        );
      }, (Object e, StackTrace st) {});
    }, onError: (Object _) {});
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final proxy = RtspKeepaliveProxy(
      realHost: InternetAddress.loopbackIPv4.address,
      realPort: fakeServer.port,
      keepaliveInterval: const Duration(milliseconds: 100),
    );
    addTearDown(proxy.stop);
    final localPort = await proxy.start();

    final client = await Socket.connect(InternetAddress.loopbackIPv4, localPort);
    addTearDown(client.close);
    final clientResponses = <String>[];
    final buf = StringBuffer();
    client.listen((data) {
      buf.write(String.fromCharCodes(data));
      final text = buf.toString();
      if (text.contains('\r\n\r\n')) {
        clientResponses.add(text);
        buf.clear();
      }
    });

    client.write('PLAY rtsp://plotter/helm_1280x720.h264 RTSP/1.0\r\nCSeq: 1\r\n\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    // The server should have seen PLAY plus several injected OPTIONS.
    expect(receivedByServer.first, startsWith('PLAY'));
    final optionsCount = receivedByServer.where((r) => r.startsWith('OPTIONS')).length;
    expect(optionsCount, greaterThanOrEqualTo(2));

    // But the client should only have seen exactly one response (to its own
    // PLAY) — the proxy must swallow responses to its injected keepalives.
    expect(clientResponses, hasLength(1));
  });
}
