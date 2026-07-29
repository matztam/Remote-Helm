/// Renders the plotter's RTSP/H.264 video stream, scaled to fit its own
/// aspect ratio inside whatever space the parent gives it (letterboxed, no
/// cropping — so a raw pointer position over this widget maps directly to a
/// normalized `[0,1]` position on the plotter's screen with no crop offset
/// to account for).
///
/// Uses `fvp` (an FFmpeg/mdk-based platform implementation registered for
/// the official `video_player` plugin) because `video_player` itself has no
/// RTSP support, and the plotter's RTSP server only offers UDP transport
/// (`RTP/AVP/UDP`; TCP-interleaved gets `461 Unsupported transport`).
///
/// ## No local proxy — connects directly to the plotter
///
/// This widget used to route the player through a local
/// `RtspKeepaliveProxy` (`rtsp://127.0.0.1:<port>/...`) to work around a
/// video freeze/blackout that appeared ~30s after `PLAY`. That extra hop
/// turned out to be unnecessary *and* costly: the freeze's real cause
/// was never on this connection at all — it was the plotter's separate
/// touch/control channel (`HelmClient`, port 51200) killing the whole
/// session, video included, when it stopped seeing touch activity after
/// the initial context handshake. See `helm_client.dart`'s doc comment for
/// the full investigation. `HelmClient` now sends a periodic no-op touch
/// frame once its context is granted, which fixes the freeze at the
/// source — there is no plotter-side RTSP keepalive requirement beyond
/// what `fvp`/mdk already does on its own (mdk sends its own RTSP
/// `OPTIONS` every 30s, same as a plain `ffplay`/FFmpeg client).
///
/// With the freeze fixed at its actual source, routing every video byte
/// through an extra local TCP hop was pure overhead: after wiring the
/// touch keepalive, the video was stable but control input lagged
/// noticeably worse than earlier in this project's history, when the
/// player connected to the plotter directly. Removing the proxy (this
/// version) restores the direct connection.
///
/// `video_player`/`fvp` don't reliably surface a stream drop as
/// `hasError` — a dead stream just freezes on the last frame (Linux) or
/// goes black (Android, where the hardware decoder is torn down) with no
/// exception. [_onControllerUpdate] still watches for `hasError` as a
/// backstop.
///
/// ## Stall watchdog
///
/// Since a dropped stream (e.g. a Wi-Fi hiccup between the tablet and the
/// plotter) usually doesn't raise `hasError` at all, this view also polls
/// `controller.value.position` on a timer: while the controller reports
/// `isPlaying`, that position must keep advancing. If it doesn't for
/// [_stallThreshold] consecutive checks, the stream is presumed dead and
/// [_start] is called again automatically — no user interaction (and no
/// visible "Retry" button to notice/tap) required, since this is meant to
/// run unattended at the helm. [isStalled] is the pure decision function,
/// factored out so the polling logic is unit-testable without a real
/// [VideoPlayerController].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart';

/// Whether a video reporting [isPlaying] and last known position
/// [lastPosition] should be considered stalled, given its current
/// [position] — i.e. playback claims to be active but the position hasn't
/// advanced. Returns `false` (never stalled) while not playing, since a
/// paused/buffering video is expected to hold its position.
///
/// A pure function so the watchdog's actual decision logic can be tested
/// directly, without needing a real (platform-backed) controller.
bool isStalled({
  required bool isPlaying,
  required Duration? lastPosition,
  required Duration? position,
}) {
  if (!isPlaying || lastPosition == null || position == null) return false;
  return position <= lastPosition;
}

/// Registers fvp as the video_player platform implementation. Call this once
/// at app startup, before any [HelmVideoView] is built.
///
/// `lowLatency: 2` is fvp's "live stream" mode: it may drop frames to keep
/// up with the live feed rather than buffering, which is what we want for
/// a remote-control video feed (staleness is worse than an occasional
/// dropped frame).
///
/// `player: {'avformat.rtsp_transport': 'udp'}` overrides fvp's own default
/// of `'tcp'` (see its `video_player_mdk.dart`) — the plotter's RTSP server
/// only implements UDP transport and returns `461 Unsupported transport` for
/// TCP-interleaved, so without this override every stream fails to open at
/// all (confirmed against a real plotter: `PlatformException(media open
/// error, invalid or unsupported media, ...)`).
///
/// The remaining `avformat.*` overrides trim FFmpeg's own RTP jitter/
/// reordering buffer, which otherwise adds up to noticeable latency on top
/// of fvp's own `lowLatency` frame-drop buffer (touch control felt laggy
/// against a real plotter before these were added):
/// - `max_delay=0`: don't hold packets waiting to reorder out-of-order RTP.
/// - `reorder_queue_size=0`: same, at the demuxer's jitter-buffer level.
///
/// Note: `player` options here are applied *before* fvp's own `lowLatency`
/// setup, and fvp's `lowLatency>=1` path unconditionally re-sets
/// `avformat.fflags` afterwards (setProperty replaces, it doesn't merge) —
/// so an `avformat.fflags` override here would be silently discarded. Don't
/// add one; `lowLatency: 2` already covers `+nobuffer` and a 1000ms dropping
/// buffer range.
///
/// `forceSoftwareDecoder` was tried (`video.decoders: ['FFmpeg']`) on the
/// theory that Android's hardware decoder (`AMediaCodec`, fvp's default)
/// holds a multi-frame internal queue that adds latency — tested against a
/// real plotter and made touch-to-video-update lag *worse*, not better.
/// Left available as a parameter in case it's worth re-testing on other
/// hardware, but the default (hardware decoding) is the better choice here.
void registerHelmVideoPlayer({bool forceSoftwareDecoder = false}) {
  fvp.registerWith(
    options: {
      'lowLatency': 2,
      'player': const {
        'avformat.rtsp_transport': 'udp',
        'avformat.max_delay': '0',
        'avformat.reorder_queue_size': '0',
      },
      if (forceSoftwareDecoder) 'video.decoders': const ['FFmpeg'],
    },
  );
}

/// Reports on video lifecycle so the parent (which owns the Helm session)
/// can show connection status without this widget knowing about HelmClient.
enum HelmVideoStatus { connecting, playing, error }

class HelmVideoView extends StatefulWidget {
  final String rtspUrl;

  /// Called whenever the underlying player's status changes.
  final ValueChanged<HelmVideoStatus>? onStatusChanged;

  /// Called once the video's aspect ratio is known (after `initialize()`)
  /// and again if it ever changes. [HelmTouchSurface] needs this to map
  /// pointer coordinates onto the plotter's screen correctly: this view
  /// letterboxes the video inside whatever space its parent gives it (see
  /// `build()` below), so the video's own on-screen rectangle is usually
  /// smaller than this widget's full bounds — most noticeably right after
  /// a screen rotation, when the available space's aspect ratio suddenly
  /// no longer matches the plotter's (fixed, landscape) video. Without
  /// knowing the actual video rectangle, touch input gets normalized
  /// against the full (wrong) bounds instead, throwing off both the scale
  /// and, once the video is no longer centered exactly the same way, the
  /// offset too.
  final ValueChanged<double>? onAspectRatioChanged;

  const HelmVideoView({
    super.key,
    required this.rtspUrl,
    this.onStatusChanged,
    this.onAspectRatioChanged,
  });

  @override
  State<HelmVideoView> createState() => HelmVideoViewState();
}

class HelmVideoViewState extends State<HelmVideoView> {
  VideoPlayerController? _controller;
  HelmVideoStatus _status = HelmVideoStatus.connecting;
  bool _disposed = false;

  // Stall watchdog: polled independently of _onControllerUpdate (which only
  // fires on player-driven value changes — a fully stalled player may stop
  // producing those entirely, so polling on our own timer is what actually
  // catches that case).
  static const _watchdogInterval = Duration(seconds: 3);
  Timer? _watchdogTimer;
  Duration? _lastPosition;

  // Backoff for reconnect attempts that themselves fail to reach a playing
  // state again (e.g. the plotter is fully off Wi-Fi, not just hiccuping) —
  // without this, a permanently unreachable plotter would retry every
  // _watchdogInterval forever.
  static const _minRetryDelay = Duration(seconds: 2);
  static const _maxRetryDelay = Duration(seconds: 30);
  Duration _retryDelay = _minRetryDelay;

  @override
  void initState() {
    super.initState();
    _start(widget.rtspUrl);
  }

  @override
  void didUpdateWidget(covariant HelmVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rtspUrl != widget.rtspUrl) {
      _start(widget.rtspUrl);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _watchdogTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _setStatus(HelmVideoStatus s) {
    _status = s;
    widget.onStatusChanged?.call(s);
    if (mounted) setState(() {});
  }

  Future<void> _start(String url) async {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    final oldController = _controller;
    _controller = null;
    await oldController?.dispose();

    _setStatus(HelmVideoStatus.connecting);

    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    controller.addListener(_onControllerUpdate);
    try {
      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }
      await controller.play();
      _controller = controller;
      _setStatus(HelmVideoStatus.playing);
      widget.onAspectRatioChanged?.call(controller.value.aspectRatio);
      _retryDelay = _minRetryDelay;
      _lastPosition = null;
      _watchdogTimer = Timer.periodic(_watchdogInterval, (_) => _checkForStall());
    } catch (e, st) {
      // ignore: avoid_print
      print('HelmVideoView: failed to initialize $url: $e\n$st');
      await controller.dispose();
      if (!_disposed) {
        _setStatus(HelmVideoStatus.error);
        _scheduleRetry();
      }
    }
  }

  void _checkForStall() {
    final c = _controller;
    if (c == null) return;
    final value = c.value;
    final stalled = isStalled(
      isPlaying: value.isPlaying,
      lastPosition: _lastPosition,
      position: value.position,
    );
    _lastPosition = value.position;
    if (stalled) {
      // ignore: avoid_print
      print('HelmVideoView: stream stalled (position stuck at ${value.position}), reconnecting');
      _setStatus(HelmVideoStatus.error);
      _start(widget.rtspUrl);
    }
  }

  void _onControllerUpdate() {
    final c = _controller;
    if (c == null) return;
    if (c.value.hasError) {
      // ignore: avoid_print
      print('HelmVideoView: player error: ${c.value.errorDescription}');
      _setStatus(HelmVideoStatus.error);
      _scheduleRetry();
    }
  }

  /// Schedules an automatic [reconnect] after [_retryDelay], doubling it
  /// (capped at [_maxRetryDelay]) for next time — so a plotter that's fully
  /// unreachable doesn't get hammered with reconnect attempts every few
  /// seconds forever.
  void _scheduleRetry() {
    Future.delayed(_retryDelay, () {
      if (_disposed) return;
      _start(widget.rtspUrl);
    });
    _retryDelay = _retryDelay * 2 > _maxRetryDelay ? _maxRetryDelay : _retryDelay * 2;
  }

  /// Re-establishes the video connection (e.g. after an error, or a manual
  /// "retry" action from the parent).
  Future<void> reconnect() => _start(widget.rtspUrl);

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return _statusOverlay();
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _statusOverlay() {
    switch (_status) {
      case HelmVideoStatus.connecting:
        return const Center(child: CircularProgressIndicator());
      case HelmVideoStatus.error:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 48),
              const SizedBox(height: 8),
              const Text('Video connection lost'),
              TextButton(onPressed: reconnect, child: const Text('Retry')),
            ],
          ),
        );
      case HelmVideoStatus.playing:
        return const SizedBox.shrink();
    }
  }
}
