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

  test('does not duplicate bytes when a request arrives split across multiple '
      'TCP writes (regression test for a real bug found against the plotter)', () async {
    // This is the bug that caused the plotter to kill sessions ~30s after
    // PLAY in practice: a client request arriving in fragments used to get
    // partially forwarded twice. mdk's own periodic keepalive `OPTIONS`
    // arriving split across reads was enough to trigger it. See this
    // file's top doc comment.
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
            client.write('RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n');
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
    );
    addTearDown(proxy.stop);
    final localPort = await proxy.start();

    final client = await Socket.connect(InternetAddress.loopbackIPv4, localPort);
    addTearDown(client.close);
    client.listen((_) {});

    // Deliberately split a single request across two separate writes, with
    // a delay between them, to force the proxy to see an incomplete
    // request on the first read.
    const request = 'OPTIONS rtsp://plotter/helm_1280x720.h264 RTSP/1.0\r\nCSeq: 1\r\n\r\n';
    final splitPoint = request.length ~/ 2;
    client.write(request.substring(0, splitPoint));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    client.write(request.substring(splitPoint));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(receivedByServer, hasLength(1));
    expect(receivedByServer.first, request);
  });

  test('relays a second, independent request after the first completes', () async {
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
            client.write('RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n');
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
    );
    addTearDown(proxy.stop);
    final localPort = await proxy.start();

    final client = await Socket.connect(InternetAddress.loopbackIPv4, localPort);
    addTearDown(client.close);
    client.listen((_) {});

    client.write('OPTIONS rtsp://plotter/helm_1280x720.h264 RTSP/1.0\r\nCSeq: 1\r\n\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    client.write('OPTIONS rtsp://plotter/helm_1280x720.h264 RTSP/1.0\r\nCSeq: 2\r\n\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(receivedByServer, hasLength(2));
    expect(receivedByServer[0], contains('CSeq: 1'));
    expect(receivedByServer[1], contains('CSeq: 2'));
  });
}
