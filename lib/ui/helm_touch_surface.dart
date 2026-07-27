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

class HelmTouchSurface extends StatefulWidget {
  final HelmClient? client;
  final Widget child;

  const HelmTouchSurface({super.key, required this.client, required this.child});

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
    if (size.width <= 0 || size.height <= 0) return null;
    final x = (local.dx / size.width).clamp(0.0, 1.0);
    final y = (local.dy / size.height).clamp(0.0, 1.0);
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
