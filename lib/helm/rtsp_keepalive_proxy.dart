/// A transparent local TCP proxy for the plotter's RTSP control connection
/// (port 554). The player connects to `rtsp://127.0.0.1:<port>/...` instead
/// of the plotter directly; every byte is forwarded unmodified in both
/// directions.
///
/// ## Why this exists, and why it's this simple
///
/// The plotter appeared to kill the RTP video stream ~30s after `PLAY`, and
/// a lot of debugging went into "fixing" that before finding the real bug
/// was in this proxy itself, not in what needed to be sent to the plotter:
///
///  1. Initial hypothesis: the plotter has some inactivity timeout on the
///     RTSP control channel, so a client-side keepalive was needed. A
///     standalone test client sending 1-second `OPTIONS` worked
///     indefinitely, matching packet captures of the real Garmin
///     ActiveCaptain app doing the same — but wiring an identical
///     keepalive into a proxy in front of the real `fvp`/mdk player had no
///     effect: still died at ~30s, even though the plotter kept answering
///     every injected `OPTIONS` with `200 OK`.
///  2. Comparing traffic against plain `ffplay` (which never froze)
///     against the same plotter suggested `ffplay` sending RTCP receiver
///     reports was the deciding factor, since `fvp`/mdk seemingly sent
///     none. Implementing synthetic RTCP `RR` packets — first minimal,
///     then with a correct SSRC, then relayed via a full rewritten-SETUP
///     UDP relay so the RR could originate from the exact registered
///     client RTCP port (mirroring FFmpeg's `ff_rtp_check_and_send_back_rr`,
///     confirmed by reading FFmpeg's own source) — each looked correct and
///     each still died at ~30s against the real player, despite standalone
///     tests of the same code succeeding for 90+ seconds every time.
///  3. That inconsistency (isolated tests reliably passing, the real
///     player reliably failing) was the tell that something about *how
///     this proxy forwarded bytes* was the actual problem, not what was
///     being sent over UDP. Testing mdk completely standalone — via a
///     minimal C++ program linked directly against `libmdk.so`, bypassing
///     Flutter/fvp/this proxy entirely — against the real plotter proved
///     it conclusively: mdk sends its own RTSP `OPTIONS` keepalive every
///     30 seconds, exactly like a plain FFmpeg-based client (`ffplay`
///     does the same). It needs no help at all.
///  4. So the proxy was the bug. The earlier version of this file's
///     `_scanClientRequests` forwarded newly-arrived raw bytes immediately
///     whenever the buffered data didn't yet form one complete RTSP
///     request — while also leaving those same bytes in the string buffer
///     it used for parsing. Once enough data arrived to complete the
///     request, it forwarded `text.substring(0, totalLen)`, which
///     included the bytes already forwarded moments earlier: a byte
///     duplication bug. TCP is free to split any write across multiple
///     reads, so this wasn't a rare edge case — it silently corrupted
///     whatever request happened to arrive fragmented, including mdk's
///     periodic `OPTIONS` keepalive, which is exactly the request whose
///     corruption would show up as "the plotter closes the session ~30s
///     after PLAY" (the first `OPTIONS` after the initial handshake is
///     the first opportunity for this to bite).
///
/// None of the RTCP synthesis, SETUP rewriting, or UDP relaying from
/// earlier iterations was ever necessary — every one of them was built
/// chasing a symptom of this forwarding bug. Once each complete request is
/// parsed out of the buffer and forwarded exactly once, mdk's own
/// keepalive is sufficient and this proxy can go back to being a plain,
/// transparent byte-for-byte relay.
library;

import 'dart:async';
import 'dart:io';

class RtspKeepaliveProxy {
  final String realHost;
  final int realPort;

  ServerSocket? _server;
  final List<_ProxyConnection> _connections = [];

  RtspKeepaliveProxy({
    required this.realHost,
    required this.realPort,
  });

  /// Starts listening locally and returns the port to connect to.
  Future<int> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((client) {
      final conn = _ProxyConnection(client: client, realHost: realHost, realPort: realPort);
      _connections.add(conn);
      conn.start().whenComplete(() => _connections.remove(conn));
    }, onError: (Object e) {
      // ignore: avoid_print
      print('RtspKeepaliveProxy: server socket error: $e');
    });
    return server.port;
  }

  Future<void> stop() async {
    for (final conn in List.of(_connections)) {
      await conn.close();
    }
    await _server?.close();
    _server = null;
  }
}

class _ProxyConnection {
  final Socket client;
  final String realHost;
  final int realPort;

  Socket? _upstream;
  bool _closed = false;

  _ProxyConnection({
    required this.client,
    required this.realHost,
    required this.realPort,
  });

  Future<void> start() async {
    try {
      final upstream = await Socket.connect(realHost, realPort);
      upstream.setOption(SocketOption.tcpNoDelay, true);
      _upstream = upstream;

      upstream.listen(
        client.add,
        onError: (Object e) => close(),
        onDone: close,
        cancelOnError: true,
      );
      client.listen(
        upstream.add,
        onError: (Object e) => close(),
        onDone: close,
        cancelOnError: true,
      );
    } catch (e) {
      // ignore: avoid_print
      print('RtspKeepaliveProxy: failed to connect upstream: $e');
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await client.close();
    } catch (_) {}
    try {
      await _upstream?.close();
    } catch (_) {}
  }
}
