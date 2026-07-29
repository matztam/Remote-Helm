/// Translates raw pointer input (touch and mouse) over a child widget into
/// Helm touch/zoom calls, normalized to the child's own size — so this
/// widget only needs to wrap something whose size *is* the plotter's video
/// area (e.g. the [AspectRatio]-fitted video from `HelmVideoView`) for
/// coordinates to line up with no extra offset math.
///
/// Two input paths, matching how a real device would drive this:
///  - True multi-touch (Android/touchscreen): tracks every active pointer by
///    id; while exactly one is down, sends single-finger touch/move/release
///    frames; the moment a second finger comes down, switches to sending
///    two-finger pinch frames (matching HelmStreamingView.onTouch's
///    ACTION_DOWN -> ACTION_POINTER_DOWN sequence in the original Android
///    app) until both fingers lift.
///  - Desktop mouse: primary button = single-finger tap/drag; scroll wheel
///    (including trackpad "smooth" scroll, which Flutter normalizes into
///    the same PointerScrollEvent) = zoom, synthesized as a two-finger pinch
///    like the Python reference's HelmClient.zoom().
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../helm/helm_client.dart';

/// The video's own on-screen rectangle within [size] given its
/// [aspectRatio] (width / height) — the full [size] when [aspectRatio] is
/// `null` or otherwise not usable, matching `HelmTouchSurface`'s behavior
/// before it was aware of letterboxing (only correct when the container's
/// and the video's aspect ratios happen to match). Otherwise, this is the
/// centered rectangle `Center(child: AspectRatio(aspectRatio: ...))` would
/// actually render: fit [aspectRatio] inside [size] without cropping, then
/// center it — the same "contain" fit `AspectRatio` itself computes.
///
/// A top-level function (rather than a method) so it can be unit-tested
/// directly, without needing to pump a widget tree.
Rect videoRect(Size size, double? aspectRatio) {
  if (aspectRatio == null || aspectRatio <= 0 || size.width <= 0 || size.height <= 0) {
    return Offset.zero & size;
  }
  final containerRatio = size.width / size.height;
  late Size videoSize;
  if (containerRatio > aspectRatio) {
    // Container is relatively wider than the video: video is
    // height-constrained, letterboxed left/right.
    videoSize = Size(size.height * aspectRatio, size.height);
  } else {
    // Container is relatively taller (or equal): video is
    // width-constrained, letterboxed top/bottom.
    videoSize = Size(size.width, size.width / aspectRatio);
  }
  final offset = Offset(
    (size.width - videoSize.width) / 2,
    (size.height - videoSize.height) / 2,
  );
  return offset & videoSize;
}

class HelmTouchSurface extends StatefulWidget {
  final HelmClient? client;
  final Widget child;

  /// The plotter video's own aspect ratio (width / height), if known. The
  /// child is expected to letterbox the video to fit inside whatever space
  /// it's given (see `HelmVideoView`) — this widget needs to know the
  /// video's *own* rectangle within that space to normalize pointer
  /// coordinates correctly, since the space given to the child (this
  /// widget's own [LayoutBuilder] constraints) is usually larger than the
  /// actual letterboxed video once their aspect ratios don't match (e.g.
  /// right after a screen rotation, when the plotter's fixed landscape
  /// video no longer matches the new window/screen shape). `null` (the
  /// default) falls back to treating the full available space as the
  /// video's own area, which is only correct when the aspect ratios
  /// happen to match.
  final double? videoAspectRatio;

  const HelmTouchSurface({
    super.key,
    required this.client,
    required this.child,
    this.videoAspectRatio,
  });

  @override
  State<HelmTouchSurface> createState() => _HelmTouchSurfaceState();
}

class _HelmTouchSurfaceState extends State<HelmTouchSurface> {
  // Active pointers by Flutter's pointer id, in the order they went down —
  // order matters because the first two fingers down are what the plotter's
  // pinch protocol addresses as track_id 0 and 1.
  final List<int> _activePointerOrder = [];
  final Map<int, Offset> _pointerPositions = {};

  // Non-blocking guard for zoom(): it's a multi-frame async sequence with
  // sleeps between frames (matching HelmClient.zoom()/the real app's pinch
  // timing); a burst of scroll events (common with smooth-scroll touchpads)
  // must drop overlapping zooms rather than queue them, or they'd pile up
  // and the UI would appear to lag/freeze behind a growing backlog.
  bool _zoomBusy = false;

  Offset? _normalize(Size size, Offset local) {
    final rect = videoRect(size, widget.videoAspectRatio);
    if (rect.width <= 0 || rect.height <= 0) return null;
    final x = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final y = ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
    return Offset(x, y);
  }

  void _onPointerDown(PointerDownEvent event, Size size) {
    final client = widget.client;
    if (client == null || !client.canZoom) return;
    final norm = _normalize(size, event.localPosition);
    if (norm == null) return;

    _activePointerOrder.add(event.pointer);
    _pointerPositions[event.pointer] = norm;

    if (_activePointerOrder.length == 1) {
      client.touch(norm.dx, norm.dy, true);
    } else if (_activePointerOrder.length == 2) {
      _sendPinchForCurrentPointers(client, down: true);
    }
    // A third+ simultaneous pointer isn't meaningful for this protocol
    // (only two track_ids are used); ignore extras rather than error.
  }

  void _onPointerMove(PointerMoveEvent event, Size size) {
    final client = widget.client;
    if (client == null || !client.canZoom) return;
    if (!_activePointerOrder.contains(event.pointer)) return;
    final norm = _normalize(size, event.localPosition);
    if (norm == null) return;
    _pointerPositions[event.pointer] = norm;

    if (_activePointerOrder.length == 1) {
      client.touch(norm.dx, norm.dy, true);
    } else if (_activePointerOrder.length >= 2) {
      _sendPinchForCurrentPointers(client, down: true);
    }
  }

  void _onPointerUp(PointerEvent event, Size size) {
    final client = widget.client;
    final wasTwoFingers = _activePointerOrder.length >= 2;
    final norm = _pointerPositions[event.pointer] ??
        (size.width > 0 && size.height > 0 ? _normalize(size, event.localPosition) : null);

    _activePointerOrder.remove(event.pointer);
    _pointerPositions.remove(event.pointer);

    if (client == null || !client.canZoom || norm == null) return;

    if (wasTwoFingers) {
      // One finger lifting from a pinch releases both track_ids (the
      // plotter doesn't need a mid-gesture "down to 1 finger" transition
      // for this use case — lifting either finger ends the zoom gesture).
      _sendPinchForCurrentPointers(client, down: false, releasedPointer: event.pointer);
    } else if (_activePointerOrder.isEmpty) {
      client.touch(norm.dx, norm.dy, false);
    }
  }

  /// Sends a two-finger `0x164c` pinch frame using the two most-recently
  /// pressed active pointers (or, when releasing, the last known positions
  /// including the pointer that just lifted).
  void _sendPinchForCurrentPointers(
    HelmClient client, {
    required bool down,
    int? releasedPointer,
  }) {
    final ids = _activePointerOrder.length >= 2
        ? _activePointerOrder.sublist(0, 2)
        : [..._activePointerOrder, ?releasedPointer];
    if (ids.length < 2) return;
    final p0 = _pointerPositions[ids[0]];
    final p1 = _pointerPositions[ids[1]];
    if (p0 == null || p1 == null) return;
    client.sendPinchFrame(p0.dx, p0.dy, p1.dx, p1.dy, down);
  }

  void _onScroll(PointerScrollEvent event, Size size) {
    final client = widget.client;
    if (client == null || !client.canZoom || _zoomBusy) return;
    final norm = _normalize(size, event.localPosition);
    if (norm == null) return;
    final direction = event.scrollDelta.dy < 0 ? 1 : -1;

    _zoomBusy = true;
    unawaited(
      client.zoom(direction, norm.dx, norm.dy).whenComplete(() => _zoomBusy = false),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _onPointerDown(e, size),
          onPointerMove: (e) => _onPointerMove(e, size),
          onPointerUp: (e) => _onPointerUp(e, size),
          onPointerCancel: (e) => _onPointerUp(e, size),
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) _onScroll(e, size);
          },
          child: widget.child,
        );
      },
    );
  }
}
