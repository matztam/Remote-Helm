/// A transparent local TCP proxy that sits between the video player and the
/// plotter's RTSP control connection (port 554), injecting an `OPTIONS`
/// keepalive once per second on the *same* connection the player's own
/// requests go out on.
///
/// ## Why this exists
///
/// The plotter does not use an inactivity timeout on the RTSP session — it
/// disconnects unless it sees *some* RTSP request on the control connection
/// roughly every second. This was hard to find because it's much stricter
/// than a typical RTSP keepalive interval (the RTSP spec's `GET_PARAMETER`
/// keepalive convention, and most server implementations, tolerate tens of
/// seconds of silence). Confirmed by comparing against the real Garmin
/// ActiveCaptain app's own traffic (packet capture): it sends `OPTIONS`
/// exactly once per second on the PLAY connection, indefinitely, for as
/// long as the video view is open.
///
/// Earlier attempts that used looser intervals (a keepalive every ~25-30s,
/// or on a separate connection from the one carrying PLAY) all failed —
/// video would freeze/go black around the 30s mark regardless. That looked
/// like a hard, non-negotiable server-side session limit, but it wasn't: a
/// standalone test client sending strict 1-second `OPTIONS` on the *same*
/// connection as PLAY keeps both the control connection and the RTP video
/// stream alive indefinitely (verified 90+ seconds continuous RTP flow
/// against the real plotter, zero drops). The earlier "hard limit"
/// conclusion was simply wrong: it was under-testing keepalive frequency,
/// not discovering a server invariant.
///
/// `video_player`/`fvp` (via mdk/FFmpeg) don't drive their own RTSP
/// keepalive frequently enough to satisfy this on their own, so this proxy
/// injects one independently of whatever the player itself sends. It sits
/// transparently between player and plotter: the player connects to
/// `rtsp://127.0.0.1:<localPort>/...` instead of the plotter directly, and
/// every byte in both directions is forwarded unmodified except for the
/// injected `OPTIONS` requests (and the plotter's responses to them, which
/// are swallowed rather than forwarded, since the player never asked for
/// them).
///
/// ## Implementation notes / past bugs fixed here
///
/// - The keepalive timer only starts after observing the player's own
///   `PLAY` request go out (not immediately on connect). Starting
///   immediately interleaves an `OPTIONS` into the middle of the player's
///   own `OPTIONS`/`DESCRIBE`/`SETUP`/`PLAY` handshake, which desyncs the
///   plotter's RTSP request/response bookkeeping badly enough that `PLAY`
///   is never reached and the connection resets. Confirmed via packet
///   capture.
/// - Response forwarding parses `Content-Length` and forwards the full
///   body, not just up to the first `\r\n\r\n`. Splitting only on the
///   header terminator truncates any response with a body — in practice,
///   `DESCRIBE`'s SDP payload — leaving the player stuck waiting forever
///   on a response it never fully received (visible as a "connecting"
///   spinner that never resolves).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class RtspKeepaliveProxy {
  final String realHost;
  final int realPort;
  final Duration keepaliveInterval;

  ServerSocket? _server;
  final List<_ProxyConnection> _connections = [];

  RtspKeepaliveProxy({
    required this.realHost,
    required this.realPort,
    this.keepaliveInterval = const Duration(seconds: 1),
  });

  /// Starts listening locally and returns the port to connect to.
  Future<int> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((client) {
      final conn = _ProxyConnection(
        client: client,
        realHost: realHost,
        realPort: realPort,
        keepaliveInterval: keepaliveInterval,
      );
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
  final Duration keepaliveInterval;

  Socket? _upstream;
  Timer? _keepaliveTimer;
  bool _seenPlay = false;
  bool _closed = false;
  int _upstreamCseqCounter = 100000; // Far outside the player's own CSeq range.

  final StringBuffer _clientToUpstreamBuffer = StringBuffer();
  final StringBuffer _upstreamToClientBuffer = StringBuffer();
  final List<int> _injectedCseqs = [];
  String? _sessionId;
  String? _requestUri;

  _ProxyConnection({
    required this.client,
    required this.realHost,
    required this.realPort,
    required this.keepaliveInterval,
  });

  Future<void> start() async {
    try {
      final upstream = await Socket.connect(realHost, realPort);
      upstream.setOption(SocketOption.tcpNoDelay, true);
      _upstream = upstream;

      upstream.listen(
        _onUpstreamData,
        onError: (Object e) => close(),
        onDone: close,
        cancelOnError: true,
      );
      client.listen(
        _onClientData,
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

  void _onClientData(List<int> data) {
    final upstream = _upstream;
    if (upstream == null) return;
    upstream.add(data);

    _clientToUpstreamBuffer.write(utf8.decode(data, allowMalformed: true));
    _scanClientRequests();
  }

  void _scanClientRequests() {
    while (true) {
      final text = _clientToUpstreamBuffer.toString();
      final headerEnd = text.indexOf('\r\n\r\n');
      if (headerEnd == -1) return;
      final headerPart = text.substring(0, headerEnd);
      final contentLength = _contentLengthOf(headerPart);
      final totalLen = headerEnd + 4 + contentLength;
      if (text.length < totalLen) return;

      final firstLine = headerPart.split('\r\n').first;
      _requestUri ??= _extractUri(firstLine);
      final sessMatch = RegExp(r'Session:\s*([^\r\n;]+)').firstMatch(headerPart);
      if (sessMatch != null) _sessionId = sessMatch.group(1)?.trim();

      if (firstLine.startsWith('PLAY') && !_seenPlay) {
        _seenPlay = true;
        _startKeepalive();
      }

      _clientToUpstreamBuffer.clear();
      _clientToUpstreamBuffer.write(text.substring(totalLen));
    }
  }

  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(keepaliveInterval, (_) => _sendKeepalive());
  }

  void _sendKeepalive() {
    final upstream = _upstream;
    final uri = _requestUri;
    if (upstream == null || uri == null || _closed) return;
    final cseq = _upstreamCseqCounter++;
    _injectedCseqs.add(cseq);
    final req = StringBuffer()
      ..write('OPTIONS $uri RTSP/1.0\r\n')
      ..write('CSeq: $cseq\r\n');
    if (_sessionId != null) req.write('Session: $_sessionId\r\n');
    req.write('\r\n');
    upstream.add(utf8.encode(req.toString()));
  }

  void _onUpstreamData(List<int> data) {
    _upstreamToClientBuffer.write(utf8.decode(data, allowMalformed: true));
    _forwardUpstreamResponses();
  }

  void _forwardUpstreamResponses() {
    while (true) {
      final text = _upstreamToClientBuffer.toString();
      final headerEnd = text.indexOf('\r\n\r\n');
      if (headerEnd == -1) return;
      final headerPart = text.substring(0, headerEnd);
      final contentLength = _contentLengthOf(headerPart);
      final totalLen = headerEnd + 4 + contentLength;
      if (text.length < totalLen) return;

      final full = text.substring(0, totalLen);
      _upstreamToClientBuffer.clear();
      _upstreamToClientBuffer.write(text.substring(totalLen));

      final cseqMatch = RegExp(r'CSeq:\s*(\d+)', caseSensitive: false).firstMatch(headerPart);
      final cseq = cseqMatch != null ? int.tryParse(cseqMatch.group(1)!) : null;
      if (cseq != null && _injectedCseqs.remove(cseq)) {
        // Response to our own injected keepalive — swallow it, the player
        // never sent this request and doesn't expect a reply to it.
        continue;
      }
      client.add(utf8.encode(full));
    }
  }

  static int _contentLengthOf(String headerPart) {
    final match = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false).firstMatch(headerPart);
    return match != null ? int.parse(match.group(1)!) : 0;
  }

  static String? _extractUri(String requestLine) {
    final parts = requestLine.split(' ');
    return parts.length >= 2 ? parts[1] : null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepaliveTimer?.cancel();
    try {
      await client.close();
    } catch (_) {}
    try {
      await _upstream?.close();
    } catch (_) {}
  }
}
