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
///    two-finger pinch frames (matching the down/first-finger-down then
///    second-finger-down sequence a real multi-touch surface produces)
///    until both fingers lift.
///  - Desktop mouse: primary button = single-finger tap/drag; scroll wheel
///    (including trackpad "smooth" scroll, which Flutter normalizes into
///    the same PointerScrollEvent) = zoom, synthesized as a two-finger pinch
///    like the Python reference's HelmClient.zoom().
///
/// ## Locating the video's own rectangle
///
/// This used to be computed indirectly: `HelmVideoView` reported its
/// player's `aspectRatio` as a plain `double` via a callback, and this
/// widget re-derived the letterboxed rectangle from that number using the
/// same "contain fit" math `AspectRatio` itself uses (see the old
/// `videoRect(Size, double?)` helper). That's a second, independent
/// implementation of the same layout decision `AspectRatio` already made —
/// any mismatch between the two (e.g. the reported `aspectRatio` being
/// stale, `0`, or otherwise not what was actually rendered) makes this
/// widget's rectangle silently diverge from the one on screen, with no
/// visible sign beyond touch input landing in the wrong place. That's
/// consistent with a real-device report (Pixel 9 Pro, portrait) where
/// vertical touch input collapsed to a narrow band around the video's
/// center — exactly what happens when the rect used for normalization is
/// taller than the one actually drawn (see `helm_touch_surface_test.dart`).
///
/// Instead, [videoBoxKey] must be attached to the actual widget being
/// rendered at the video's own size (e.g. the `AspectRatio` in
/// `HelmVideoView`) — its [RenderBox] is measured directly, every time a
/// pointer event needs normalizing, so there is no second calculation to
/// drift out of sync with what's on screen.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../helm/helm_client.dart';

/// The video's own on-screen rectangle, in this [ancestor]'s local
/// coordinate space, as actually rendered by the widget attached to
/// [videoBoxKey] — or `null` if that widget hasn't been laid out yet (e.g.
/// the very first frame) or [ancestor] isn't one of its ancestors.
Rect? measuredVideoRect(GlobalKey videoBoxKey, RenderBox ancestor) {
  final videoBox = videoBoxKey.currentContext?.findRenderObject();
  if (videoBox is! RenderBox || !videoBox.attached || !videoBox.hasSize) {
    return null;
  }
  final topLeft = videoBox.localToGlobal(Offset.zero, ancestor: ancestor);
  return topLeft & videoBox.size;
}

class HelmTouchSurface extends StatefulWidget {
  final HelmClient? client;
  final Widget child;

  /// Attached by the caller to the actual widget rendered at the video's own
  /// (letterboxed) size and position — e.g. the `AspectRatio` in
  /// `HelmVideoView` — so this widget can measure its real on-screen
  /// rectangle directly instead of recomputing it from a separately-tracked
  /// aspect ratio. See this file's top doc comment for why.
  final GlobalKey videoBoxKey;

  const HelmTouchSurface({
    super.key,
    required this.client,
    required this.child,
    required this.videoBoxKey,
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

  Offset? _normalize(RenderBox ancestor, Offset local) {
    final rect = measuredVideoRect(widget.videoBoxKey, ancestor);
    if (rect == null || rect.width <= 0 || rect.height <= 0) return null;
    final x = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final y = ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
    return Offset(x, y);
  }

  void _onPointerDown(PointerDownEvent event, RenderBox box) {
    final client = widget.client;
    if (client == null || !client.canZoom) return;
    final norm = _normalize(box, event.localPosition);
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

  void _onPointerMove(PointerMoveEvent event, RenderBox box) {
    final client = widget.client;
    if (client == null || !client.canZoom) return;
    if (!_activePointerOrder.contains(event.pointer)) return;
    final norm = _normalize(box, event.localPosition);
    if (norm == null) return;
    _pointerPositions[event.pointer] = norm;

    if (_activePointerOrder.length == 1) {
      client.touch(norm.dx, norm.dy, true);
    } else if (_activePointerOrder.length >= 2) {
      _sendPinchForCurrentPointers(client, down: true);
    }
  }

  void _onPointerUp(PointerEvent event, RenderBox box) {
    final client = widget.client;
    final wasTwoFingers = _activePointerOrder.length >= 2;
    final norm = _pointerPositions[event.pointer] ?? _normalize(box, event.localPosition);

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

  void _onScroll(PointerScrollEvent event, RenderBox box) {
    final client = widget.client;
    if (client == null || !client.canZoom || _zoomBusy) return;
    final norm = _normalize(box, event.localPosition);
    if (norm == null) return;
    final direction = event.scrollDelta.dy < 0 ? 1 : -1;

    _zoomBusy = true;
    unawaited(
      client.zoom(direction, norm.dx, norm.dy).whenComplete(() => _zoomBusy = false),
    );
  }

  final _listenerKey = GlobalKey();

  RenderBox? get _box => _listenerKey.currentContext?.findRenderObject() as RenderBox?;

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: _listenerKey,
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        final box = _box;
        if (box != null) _onPointerDown(e, box);
      },
      onPointerMove: (e) {
        final box = _box;
        if (box != null) _onPointerMove(e, box);
      },
      onPointerUp: (e) {
        final box = _box;
        if (box != null) _onPointerUp(e, box);
      },
      onPointerCancel: (e) {
        final box = _box;
        if (box != null) _onPointerUp(e, box);
      },
      onPointerSignal: (e) {
        final box = _box;
        if (e is PointerScrollEvent && box != null) _onScroll(e, box);
      },
      child: widget.child,
    );
  }
}
