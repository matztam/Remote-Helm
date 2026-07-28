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
/// ## Why there's a local proxy in front of the plotter at all
///
/// There's no plotter-side RTSP keepalive requirement beyond what `fvp`/mdk
/// already does on its own: mdk (via the FFmpeg build it bundles) sends its
/// own RTSP `OPTIONS` keepalive every 30 seconds, same as a plain
/// `ffplay`/FFmpeg client. The actual cause of what looked like a video
/// freeze/blackout ~30s after `PLAY` had nothing to do with this widget or
/// the RTSP connection at all — it was the plotter's touch/control channel
/// (`HelmClient`, port 51200, a completely separate connection) killing the
/// *whole session*, video included, when it stopped seeing touch activity
/// after the initial context handshake. See `helm_client.dart`'s doc
/// comment for the full story (it took a long, wrong-turn-heavy
/// investigation — RTSP/RTCP keepalive theories, a full UDP relay, packet
/// captures of `ffplay` vs. mdk — before a step-by-step handshake rebuild
/// pointed at the real connection). `HelmClient` now sends a periodic
/// no-op touch frame once its context is granted, which fixes this at the
/// source; nothing about the RTSP/video path itself needed to change.
///
/// Along the way, this file's [RtspKeepaliveProxy] carried a real,
/// independent bug worth fixing regardless: it could forward a fragmented
/// RTSP request's bytes twice (once as raw bytes on arrival, again from its
/// parse buffer once the request completed), silently corrupting whatever
/// request happened to arrive split across TCP reads. That's fixed, and
/// [RtspKeepaliveProxy] is a plain, transparent byte-for-byte relay now —
/// but fixing it alone did not resolve the freeze, since the freeze's real
/// cause was on the touch channel the whole time. The proxy itself exists
/// only because `video_player`/`fvp` need a stable local URL to connect to
/// (there's no other reason to route through localhost instead of the
/// plotter directly).
///
/// `video_player`/`fvp` don't reliably surface a stream drop as
/// `hasError` — a dead stream just freezes on the last frame (Linux) or
/// goes black (Android, where the hardware decoder is torn down) with no
/// exception. [_onControllerUpdate] still watches for `hasError` as a
/// backstop.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart';

import '../helm/rtsp_keepalive_proxy.dart';

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

  const HelmVideoView({super.key, required this.rtspUrl, this.onStatusChanged});

  @override
  State<HelmVideoView> createState() => HelmVideoViewState();
}

class HelmVideoViewState extends State<HelmVideoView> {
  VideoPlayerController? _controller;
  RtspKeepaliveProxy? _proxy;
  HelmVideoStatus _status = HelmVideoStatus.connecting;
  bool _disposed = false;

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
    _controller?.dispose();
    _proxy?.stop();
    super.dispose();
  }

  void _setStatus(HelmVideoStatus s) {
    _status = s;
    widget.onStatusChanged?.call(s);
    if (mounted) setState(() {});
  }

  Future<void> _start(String url) async {
    final oldController = _controller;
    final oldProxy = _proxy;
    _controller = null;
    _proxy = null;
    await oldController?.dispose();
    await oldProxy?.stop();

    _setStatus(HelmVideoStatus.connecting);

    final plotterUri = Uri.parse(url);
    final proxy = RtspKeepaliveProxy(
      realHost: plotterUri.host,
      realPort: plotterUri.hasPort ? plotterUri.port : 554,
    );
    final localPort = await proxy.start();
    if (_disposed) {
      await proxy.stop();
      return;
    }
    _proxy = proxy;
    final proxiedUrl = 'rtsp://127.0.0.1:$localPort${plotterUri.path}';

    final controller = VideoPlayerController.networkUrl(Uri.parse(proxiedUrl));
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
    } catch (e, st) {
      // ignore: avoid_print
      print('HelmVideoView: failed to initialize $proxiedUrl: $e\n$st');
      await controller.dispose();
      await proxy.stop();
      if (!_disposed) _setStatus(HelmVideoStatus.error);
    }
  }

  void _onControllerUpdate() {
    final c = _controller;
    if (c == null) return;
    if (c.value.hasError) {
      // ignore: avoid_print
      print('HelmVideoView: player error: ${c.value.errorDescription}');
      _setStatus(HelmVideoStatus.error);
    }
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
