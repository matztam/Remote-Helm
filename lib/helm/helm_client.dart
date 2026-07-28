/// Working Garmin Helm client — session, touch control, and video URL.
///
/// Ported from the Python reference implementation
/// (github.com/Mrkvak/helm-linux, `helm/helm_client.py`). See `protocol.dart`
/// for the wire format itself.
///
/// Prereqs: this client must be a registered bl-id (see `credential.dart` /
/// pairing flow) and the plotter's global App-permission must be set to
/// "View and Control".
///
/// Note: like the Python reference, this client only reads from the socket
/// during the handshake (waiting for `0x1645`). Once connected, sends
/// (touch/zoom) are one-way; nothing continuously drains further server
/// frames afterwards. That matches actual usage (video comes separately over
/// RTSP), but means the socket's receive buffer will simply accumulate
/// unread bytes for the life of the connection if the plotter keeps sending
/// unsolicited frames — acceptable for a session that's normally closed
/// within minutes to hours, not indefinitely long-lived.
///
/// ## Why this client sends a periodic no-op touch frame
///
/// After the handshake grants a touch context (`0x1645`/[touchCtx]), the
/// plotter expects *some* touch activity to keep flowing on this connection
/// — not as a requirement of the touch channel in isolation, but as a
/// keepalive for the whole session, including the separate RTSP video
/// stream running alongside it. Without it, the plotter kills the video
/// (freeze on Linux, black screen on Android, no error surfaced by
/// `video_player`/fvp) roughly 30s after the touch context was acquired,
/// regardless of how healthy the RTSP control connection itself looks.
///
/// This took a long, wrong-turn-heavy investigation to find: many rounds
/// of RTSP/RTCP keepalive experiments (documented in
/// `rtsp_keepalive_proxy.dart`'s history) never touched the actual cause,
/// because the real trigger lives entirely on this connection, not the
/// video one. It was finally isolated with a step-by-step rebuild of the
/// handshake in a minimal standalone app (sending `tHello`, then
/// `+tToken`, then `+tSubscribe`, then `+tAcquire` one step at a time
/// against the real plotter) — video stayed alive fine through every step
/// except the last: adding `tAcquire` alone reproduced the freeze,
/// independent of whether the client actively read the plotter's own
/// response afterwards (ruling out a TCP backpressure/unread-socket
/// explanation). Comparing against packet captures of the real Garmin
/// ActiveCaptain app confirmed it sends frequent `0x164c` (tTouch) frames
/// throughout an active session — plausibly real touch/gesture activity in
/// those captures rather than a fixed-interval keepalive, but sending a
/// synthetic no-op touch frame once a second reproduced the same
/// stabilizing effect in the same standalone rebuild (verified 126+
/// continuous seconds against the real plotter, versus ~30-33s without
/// it). Sending `down: false` at a fixed, arbitrary position keeps this
/// inert — it moves nothing on the plotter's screen, it's just activity on
/// the wire.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

class NoTouchContextException implements Exception {
  const NoTouchContextException();
  @override
  String toString() =>
      "no touch context (plotter didn't send 0x1645) — control not granted?";
}

class HelmClient {
  final String host;
  final int port;
  final Uint8List token;

  Socket? _socket;
  final BytesBuilder _rxBuf = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _rxSub;
  Timer? _keepaliveTimer;

  /// Plotter-assigned touch context id (from `0x1645`), 4 bytes, or null
  /// until the handshake completes successfully.
  Uint8List? touchCtx;

  HelmClient(this.host, {this.port = helmPort, Uint8List? token})
    : token = token ?? randomToken();

  String get rtspUrl => 'rtsp://$host:554/helm_1280x720.h264';

  bool get canZoom => touchCtx != null;

  /// Connects and performs the handshake. Throws a [SocketException] on
  /// connect failure, or leaves [touchCtx] null if the plotter never granted
  /// a touch context within [timeout] (e.g. permission not set to "View and
  /// Control").
  Future<void> connect({Duration timeout = const Duration(seconds: 6)}) async {
    _socket = await Socket.connect(host, port, timeout: timeout);
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    await _handshake(timeout);
  }

  void _send(int type, [List<int> payload = const []]) {
    final sock = _socket;
    if (sock == null) throw StateError('not connected');
    sock.add(buildFrame(type, payload));
  }

  Future<void> _handshake(Duration timeout) async {
    _send(tHello, _u16le(helloTag));
    _send(tToken, token);
    for (final idx in subscribeIndices) {
      _send(tSubscribe, _u32le(idx));
    }
    // One touch context (finger 1) for taps/drags — exactly like the app for
    // single-finger use. Multi-touch (pinch) reuses this same context with
    // count=2 messages (see PROTOCOL.md / encodePinch); no second context is
    // requested.
    _send(tAcquire);
    touchCtx = await _awaitContext(timeout);
    if (touchCtx != null) _startKeepalive();
  }

  /// Sends an inert touch-up frame once a second for as long as this client
  /// is connected — see this file's top doc comment for why the plotter
  /// needs this to keep the RTSP video stream alive.
  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final ctx = touchCtx;
      if (ctx == null) return;
      _send(tTouch, encodeTouch(ctx, 0.0, 0.0, false));
    });
  }

  Future<Uint8List?> _awaitContext(Duration timeout) async {
    final sock = _socket!;
    final completer = Completer<Uint8List?>();
    Timer? deadline;

    void finish(Uint8List? result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    _rxSub = sock.listen(
      (chunk) {
        _rxBuf.add(chunk);
        final buf = _rxBuf.toBytes();
        final result = parseFrames(buf);
        for (final f in result.frames) {
          if (f.type == tContext && f.payload.length >= 8) {
            // Consume everything up to and including this frame; anything
            // after is left buffered for read()/normal operation.
            _rxBuf.clear();
            _rxBuf.add(buf.sublist(f.endOffset));
            finish(Uint8List.sublistView(f.payload, 4, 8));
            return;
          }
        }
        // No context frame yet: keep only what parseFrames didn't consume,
        // matching the Python client's unbounded-growth guard.
        _rxBuf.clear();
        _rxBuf.add(buf.sublist(result.consumed));
        if (_rxBuf.length > 1 << 20) {
          final tail = _rxBuf.toBytes();
          _rxBuf.clear();
          _rxBuf.add(tail.sublist(tail.length - 4096));
        }
      },
      onError: (_) => finish(null),
      onDone: () => finish(null),
      cancelOnError: true,
    );

    deadline = Timer(timeout, () => finish(null));
    final result = await completer.future;
    deadline.cancel();
    await _rxSub?.cancel();
    _rxSub = null;
    return result;
  }

  // ---- input --------------------------------------------------------------

  void touch(double x, double y, bool down) {
    final ctx = touchCtx;
    if (ctx == null) throw const NoTouchContextException();
    _send(tTouch, encodeTouch(ctx, x, y, down));
  }

  /// Sends one two-finger `0x164c` pinch frame at explicit positions. Unlike
  /// [zoom] (which plays out a whole synthetic pinch gesture over several
  /// frames), this is for callers driving real, continuously-tracked
  /// multi-touch input (e.g. two actual fingers on a touchscreen) where the
  /// finger positions come from the platform's own pointer events rather
  /// than from an interpolated animation.
  void sendPinchFrame(double x0, double y0, double x1, double y1, bool down) {
    final ctx = touchCtx;
    if (ctx == null) throw const NoTouchContextException();
    _send(tTouch, encodePinch(ctx, x0, y0, x1, y1, down));
  }

  /// A press+release at normalized (x, y).
  Future<void> tap(double x, double y) async {
    touch(x, y, true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    touch(x, y, false);
  }

  /// Press, move through [points], release. [points] are normalized (x, y).
  Future<void> drag(
    List<(double, double)> points, {
    Duration stepDelay = const Duration(milliseconds: 30),
  }) async {
    if (points.isEmpty) return;
    touch(points.first.$1, points.first.$2, true);
    for (final p in points.skip(1)) {
      await Future<void>.delayed(stepDelay);
      touch(p.$1, p.$2, true);
    }
    await Future<void>.delayed(stepDelay);
    final last = points.last;
    touch(last.$1, last.$2, false);
  }

  /// Pinch-to-zoom centered on (cx, cy). direction > 0 zooms in (fingers
  /// spread apart), < 0 zooms out (together). Two fingers move as a
  /// horizontal pair, sent as count=2 pinch messages (see [encodePinch]).
  Future<void> zoom(
    int direction,
    double cx,
    double cy, {
    int steps = 8,
    double span = 0.08,
    double gap0 = 0.04,
  }) async {
    final ctx = touchCtx;
    if (ctx == null) return;

    final gaps = List<double>.generate(
      steps,
      (i) => gap0 + (span - gap0) * i / (steps - 1),
    );
    final ordered = direction < 0 ? gaps.reversed.toList() : gaps;

    void frame(double gap, bool down) {
      _send(tTouch, encodePinch(ctx, cx - gap, cy, cx + gap, cy, down));
    }

    frame(ordered.first, true);
    for (final g in ordered.skip(1)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      frame(g, true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    frame(ordered.last, false);
  }

  /// Whatever bytes were left over in the receive buffer after the handshake
  /// completed (device info, etc. sent by the plotter alongside the `0x1645`
  /// context grant) — mirrors Python's `read()` fallback path. Returns an
  /// empty list if nothing is buffered. This does not perform a fresh socket
  /// read; call this once right after [connect] if you want to inspect the
  /// plotter's immediate follow-up frames (e.g. for diagnostics).
  Uint8List takeBufferedBytes() {
    final out = _rxBuf.toBytes();
    _rxBuf.clear();
    return out;
  }

  void close() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _rxSub?.cancel();
    _rxSub = null;
    _socket?.destroy();
    _socket = null;
  }
}

Uint8List _u16le(int v) {
  final out = Uint8List(2);
  ByteData.view(out.buffer).setUint16(0, v, Endian.little);
  return out;
}

Uint8List _u32le(int v) {
  final out = Uint8List(4);
  ByteData.view(out.buffer).setUint32(0, v, Endian.little);
  return out;
}
