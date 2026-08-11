/// The app's single screen: video + touch control, with a connect/discover
/// control bar that's always visible on desktop and hidden (behind a small
/// edge tap) on Android, where the video should fill the whole display.
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../helm/discovery.dart';
import '../helm/gpx.dart';
import '../helm/route_sync.dart';
import 'helm_session_controller.dart';
import 'helm_touch_surface.dart';
import 'helm_video_view.dart';
import 'platform_layout.dart';
import 'route_catalog_dialog.dart';

class HelmHomeScreen extends StatefulWidget {
  const HelmHomeScreen({super.key});

  @override
  State<HelmHomeScreen> createState() => _HelmHomeScreenState();
}

class _HelmHomeScreenState extends State<HelmHomeScreen> with WidgetsBindingObserver {
  final _session = HelmSessionController();
  final _hostController = TextEditingController();
  bool _controlsVisible = true; // desktop: always effectively true (shown)
  bool _isFullscreen = false;

  // Attached to HelmVideoView's AspectRatio widget so HelmTouchSurface can
  // measure its actual on-screen rectangle directly, instead of recomputing
  // it from a separately-tracked aspect ratio value that could drift out of
  // sync with what's actually rendered.
  final _videoBoxKey = GlobalKey();

  // Lets didChangeAppLifecycleState reach into the video player to force a
  // reconnect on resume — see that method's doc comment for why this is
  // needed on top of HelmVideoView's own stall watchdog.
  final _videoViewKey = GlobalKey<HelmVideoViewState>();

  DateTime? _pausedAt;

  // A resume after less than this was backgrounded briefly enough (e.g. a
  // quick app-switcher glance, a notification shade pull) that the
  // connection is presumably still fine; don't force a reconnect for that.
  // Long enough to comfortably clear normal quick-switch UI interactions.
  static const _resumeReconnectThreshold = Duration(seconds: 10);

  // On Android, the controls auto-hide again a bit after a connection
  // succeeds — e.g. after the user reveals them to type in a plotter IP
  // manually — so the video goes back to filling the whole screen without
  // a second manual tap. Tracked so a rapid connect/disconnect/reconnect
  // sequence doesn't leave more than one of these timers running at once.
  Timer? _autoHideTimer;
  static const _autoHideDelay = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_onSessionChanged);
    _controlsVisible = isDesktopPlatform; // Android starts hidden (immersive)
    // This is meant to run full-screen on a tablet mounted at the helm —
    // the screen timing out mid-use would defeat the point. Held only for
    // this screen's lifetime, not globally, so it releases automatically
    // if the app is ever backgrounded or closed.
    WakelockPlus.enable();
    _init();
  }

  /// Forces a full reconnect (touch session + video) when the app returns
  /// from a long background/standby period, rather than waiting for
  /// HelmVideoView's own stall watchdog to notice on its own.
  ///
  /// Android tears down the app's network sockets during Doze/deep sleep,
  /// and throttles or fully suspends Dart timers while backgrounded — so
  /// both HelmClient's keepalive and HelmVideoView's watchdog can simply
  /// stop running for the whole standby duration, not just miss a tick.
  /// The watchdog would eventually catch a stalled video after resuming
  /// (it polls on its own timer once the app is foregrounded again), but
  /// there's no equivalent for the touch/control connection — a dead
  /// HelmClient socket doesn't visibly fail until the next touch is
  /// attempted, and even then only surfaces as a silently-dropped tap
  /// rather than a visible error. Reconnecting both proactively on resume
  /// closes that gap instead of relying on the user tapping to notice.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return;
    if (DateTime.now().difference(pausedAt) < _resumeReconnectThreshold) return;

    final host = _session.lastHost;
    if (host == null || host.isEmpty) return;
    // ignore: avoid_print
    print('HelmHomeScreen: resumed after a long background period, reconnecting');
    unawaited(_reconnectAfterResume(host));
  }

  /// Reconnects the touch session, then the video — in that order, and one
  /// at a time, rather than firing both off in parallel.
  ///
  /// [HelmSessionController.connect] replaces the [HelmClient] instance and
  /// calls `notifyListeners()` partway through (while the old client is
  /// being closed and the new one has not yet connected), which rebuilds
  /// this screen and, via [_buildVideoArea], briefly passes a null
  /// `rtspUrl` down to [HelmVideoView] — disposing its old state (and
  /// replacing [_videoViewKey]'s current state) out from under a
  /// concurrently-running `reconnect()` call on the *old* state object,
  /// which raced with fvp's own MdkVideoPlayer tearing down its stream
  /// controller ("Bad state: Cannot add event after closing") and left the
  /// video hanging until the (separate) stall watchdog eventually caught it
  /// ~20s later, rather than reconnecting immediately as intended. Awaiting
  /// the session reconnect first means the video reconnect below always
  /// targets the current, live HelmVideoView state.
  Future<void> _reconnectAfterResume(String host) async {
    await _session.connect(host);
    if (!mounted) return;
    // Let the rebuild _session.connect's notifyListeners() triggered
    // actually run first, so _videoViewKey.currentState below is this
    // frame's HelmVideoView, not a stale/disposed one from before the
    // reconnect.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await _videoViewKey.currentState?.reconnect();
  }

  Future<void> _init() async {
    await _session.loadLastHost();
    final last = _session.lastHost;
    if (last != null && last.isNotEmpty) {
      _hostController.text = last;
      await _session.connect(last);
    } else {
      await _autoDiscoverAndConnect();
    }
  }

  Future<void> _autoDiscoverAndConnect() async {
    final results = await _session.discover();
    if (!mounted) return;
    if (results.length == 1) {
      final host = _addressOf(results.first);
      _hostController.text = host;
      await _session.connect(host);
    }
    // Zero or multiple results: leave it to the user to pick via the
    // control bar (which lists discovered plotters below the host field).
  }

  String _addressOf(HelmServiceInfo s) => s.address.isEmpty ? s.host : s.address;

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    // On Android, once a connection succeeds, the controls (if visible —
    // e.g. the user just typed in a plotter IP by hand) should get out of
    // the way again on their own, same as they were before the user had to
    // reveal them at all. Desktop always shows them, so this is a no-op
    // there; _hideControls itself is also an Android-only no-op guard away
    // from mattering, but skipping the timer entirely there avoids an
    // untriggered Timer sitting around for no reason.
    if (!isDesktopPlatform && _session.isConnected && _controlsVisible) {
      _autoHideTimer?.cancel();
      _autoHideTimer = Timer(_autoHideDelay, () {
        if (mounted && _session.isConnected) _hideControls();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoHideTimer?.cancel();
    WakelockPlus.disable();
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    final nowFull = await toggleDesktopFullscreen();
    setState(() => _isFullscreen = nowFull);
  }

  Future<void> _revealControls() async {
    _autoHideTimer?.cancel();
    if (!isDesktopPlatform) await revealAndroidSystemUiTemporarily();
    setState(() => _controlsVisible = true);
  }

  Future<void> _hideControls() async {
    if (!isDesktopPlatform) await hideAndroidSystemUi();
    setState(() => _controlsVisible = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // Android is meant to run edge-to-edge/immersive; SafeArea only
        // meaningfully insets on desktop where it's a no-op anyway alongside
        // the normal window chrome.
        top: isDesktopPlatform,
        bottom: isDesktopPlatform,
        child: Column(
          children: [
            if (_controlsVisible) _buildControlBar(context),
            Expanded(child: _buildVideoArea(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea(BuildContext context) {
    final client = _session.client;
    final rtspUrl = client?.rtspUrl;

    final video = rtspUrl == null
        ? const Center(
            child: Text('Not connected.', style: TextStyle(color: Colors.white70)),
          )
        : HelmVideoView(key: _videoViewKey, rtspUrl: rtspUrl, videoBoxKey: _videoBoxKey);

    final withTouch = HelmTouchSurface(
      client: client,
      videoBoxKey: _videoBoxKey,
      child: video,
    );

    if (isDesktopPlatform) return withTouch;

    // Android: tapping a thin strip at the very top reveals the hidden
    // controls (mirrors the "swipe from edge" affordance immersive mode
    // already offers for system bars, but ties it to our own UI too).
    return Stack(
      children: [
        Positioned.fill(child: withTouch),
        if (!_controlsVisible)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 24,
            child: GestureDetector(
              onTap: _revealControls,
              child: Container(color: Colors.transparent),
            ),
          ),
      ],
    );
  }

  Widget _buildControlBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Plotter',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Discover',
              icon: const Icon(Icons.search),
              onPressed: _onDiscoverPressed,
            ),
            FilledButton(
              onPressed: _onConnectPressed,
              child: Text(_session.isConnected ? 'Disconnect' : 'Connect'),
            ),
            if (_session.isConnected) ...[
              IconButton(
                tooltip: 'Import GPX route',
                icon: const Icon(Icons.route),
                onPressed: _onImportGpxPressed,
              ),
              IconButton(
                tooltip: 'Browse plotter routes/waypoints',
                icon: const Icon(Icons.list_alt),
                onPressed: _onBrowseCatalogPressed,
              ),
            ],
            if (isDesktopPlatform) ...[
              const Spacer(),
              IconButton(
                tooltip: _isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
                icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                onPressed: _toggleFullscreen,
              ),
            ] else ...[
              const Spacer(),
              IconButton(
                tooltip: 'Hide controls',
                icon: const Icon(Icons.expand_less),
                onPressed: _hideControls,
              ),
            ],
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _session.statusMessage ?? '',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onDiscoverPressed() async {
    final results = await _session.discover();
    if (!mounted) return;
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No plotter found. Join the plotter's Wi-Fi.")),
      );
      return;
    }
    if (results.length == 1) {
      _hostController.text = _addressOf(results.first);
      return;
    }
    final chosen = await showDialog<HelmServiceInfo>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select a plotter'),
        children: [
          for (final s in results)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(s),
              child: Text('${s.name}  (${_addressOf(s)})'),
            ),
        ],
      ),
    );
    if (chosen != null) _hostController.text = _addressOf(chosen);
  }

  Future<void> _onConnectPressed() async {
    if (_session.isConnected) {
      _session.disconnect();
      return;
    }
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    await _session.connect(host);
  }

  /// Picks a `.gpx` file, extracts its routes ([parseGpxRoutes]), and
  /// syncs the first one straight to the plotter ([syncRoute]) — or, if
  /// the file has more than one `<rte>`, lets the user choose which,
  /// mirroring the plotter-selection flow in [_onDiscoverPressed].
  ///
  /// [syncRoute] supports routes of any point count (see route_sync.dart's
  /// top doc comment) — one small caveat remains: a route-level marker
  /// byte in the wire format isn't fully understood yet and is always
  /// sent as the one value confirmed to work, so a route with a
  /// different-from-that value might be rejected or misinterpreted by the
  /// plotter (untested beyond the two point counts verified so far).
  Future<void> _onImportGpxPressed() async {
    const gpxType = XTypeGroup(label: 'GPX', extensions: ['gpx']);
    final file = await openFile(acceptedTypeGroups: const [gpxType]);
    if (file == null) return;
    final gpxText = await file.readAsString();

    List<GpxRoute> routes;
    try {
      routes = parseGpxRoutes(gpxText);
    } on GpxParseException catch (e) {
      _showSnack('Could not read that GPX file: $e');
      return;
    }
    if (routes.isEmpty) {
      _showSnack('No routes found in that GPX file.');
      return;
    }

    GpxRoute? chosen = routes.first;
    if (routes.length > 1) {
      if (!mounted) return;
      chosen = await showDialog<GpxRoute>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Select a route to import'),
          children: [
            for (final r in routes)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(r),
                child: Text('${r.name} (${r.points.length} points)'),
              ),
          ],
        ),
      );
    }
    if (chosen == null) return;

    final host = _session.lastHost;
    if (host == null || host.isEmpty) return;

    try {
      await syncRoute(host, chosen.name, chosen.points);
      _showSnack('Sent "${chosen.name}" to the plotter.');
    } on UnimplementedError {
      _showSnack(
        '"${chosen.name}" has ${chosen.points.length} points — only routes with '
        'exactly 4 points can be sent right now (see route_sync.dart).',
      );
    } on RouteSyncTimeoutException catch (e) {
      _showSnack('Plotter did not respond: $e');
    } on Object catch (e) {
      _showSnack('Failed to send route: $e');
    }
  }

  Future<void> _onBrowseCatalogPressed() async {
    final host = _session.lastHost;
    if (host == null || host.isEmpty) return;
    await showRouteCatalogDialog(context, host);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
