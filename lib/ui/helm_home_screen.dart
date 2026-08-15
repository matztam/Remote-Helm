/// The app's single screen: video + touch control, with a connect/discover
/// control bar that's always visible on desktop and hidden (behind a small
/// edge tap) on Android, where the video should fill the whole display.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../helm/discovery.dart';
import '../helm/gpx.dart';
import '../helm/route_catalog.dart';
import '../helm/route_sync.dart';
import 'helm_session_controller.dart';
import 'helm_touch_surface.dart';
import 'helm_video_view.dart';
import 'platform_layout.dart';
import 'route_catalog_dialog.dart';
import 'route_catalog_service.dart';

class HelmHomeScreen extends StatefulWidget {
  const HelmHomeScreen({super.key});

  @override
  State<HelmHomeScreen> createState() => _HelmHomeScreenState();
}

class _HelmHomeScreenState extends State<HelmHomeScreen> with WidgetsBindingObserver {
  final _session = HelmSessionController();
  final _catalogService = RouteCatalogService();
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

  // Lets another app's Android share sheet ("Share..." on a GPX file/export)
  // list Remote Helm as a target — see _onImportGpxPressed's doc comment for
  // the shared processing path this feeds into (identical to picking a file
  // via the toolbar button, just a different way of obtaining the bytes).
  // Only ever populated on Android (see AndroidManifest.xml's intent-filters
  // — no iOS Share Extension is wired up), but the package itself is
  // cross-platform and a no-op stream on platforms with no incoming intent.
  StreamSubscription<List<SharedMediaFile>>? _sharingIntentSub;

  // **Added 2026-08-15** to fix a live-reproduced cold-start-via-share bug:
  // a GPX shared while Remote Helm wasn't running yet cold-starts the app,
  // and _handleSharedFiles (triggered by getInitialMedia(), see
  // _initSharingIntent's doc comment) can reach _importGpxFrom's
  // `_session.lastHost` read before _init's `await _session.loadLastHost()`
  // below has actually completed — [HelmSessionController.lastHost] reads
  // as null until then, so the import silently gave up with no host to
  // send to (confirmed live via debug logging: "host=null isConnected=false").
  // [_importGpxFrom] awaits this completer before touching [_session] at
  // all, so it's blocked on the *real* signal (loadLastHost done) rather
  // than a guessed delay.
  final _initDone = Completer<void>();

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
    _initSharingIntent();
    _init();
  }

  /// Wires up both halves of `receive_sharing_intent`'s API: a live stream
  /// for files shared while the app is already running, and a one-shot
  /// check for a file shared while the app was closed/backgrounded (the
  /// share sheet cold-starts or resumes it). Android-only in practice (see
  /// [_sharingIntentSub]'s doc comment).
  void _initSharingIntent() {
    _sharingIntentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleSharedFiles,
      onError: (Object e) {
        // ignore: avoid_print
        print('HelmHomeScreen: sharing intent stream error: $e');
      },
    );
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      // Tell the plugin we're done with the cold-start intent regardless of
      // whether it contained anything usable, so a later hot-restart of
      // this screen doesn't see the same stale share again.
      ReceiveSharingIntent.instance.reset();
      _handleSharedFiles(files);
    });
  }

  /// Picks the first shared file that looks like it could be a GPX route
  /// (by path extension — MIME type on the wire is unreliable, see
  /// AndroidManifest.xml's intent-filter doc comment) and runs it through
  /// the same import flow as the toolbar's "Import GPX" button
  /// ([_importGpxFrom]).
  void _handleSharedFiles(List<SharedMediaFile> files) {
    if (files.isEmpty || !mounted) return;
    final gpxFile = files.firstWhere(
      (f) => f.path.toLowerCase().endsWith('.gpx'),
      orElse: () => files.first,
    );
    unawaited(_importGpxFrom(File(gpxFile.path).readAsString()));
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

  /// Connects both the touch/video session and the catalog service to
  /// [host]. The catalog connection failing doesn't block the touch/video
  /// one or vice versa — see [RouteCatalogService.connect]'s own doc
  /// comment for why it's a separate, independently-connected service
  /// rather than something layered onto [HelmSessionController]'s
  /// [HelmClient] (different port, different protocol entirely).
  Future<void> _connectBoth(String host) async {
    await _session.connect(host);
    unawaited(_catalogService.connect(host));
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
    unawaited(_catalogService.connect(host));
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
    // Completed here, right after [lastHost] becomes readable, not after
    // the rest of this method's connection attempt below — see
    // [_initDone]'s doc comment for why only this part matters to callers
    // waiting on it (e.g. [_importGpxFrom]'s cold-start-via-share case).
    if (!_initDone.isCompleted) _initDone.complete();
    final last = _session.lastHost;
    if (last != null && last.isNotEmpty) {
      _hostController.text = last;
      await _connectBoth(last);
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
      await _connectBoth(host);
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
    _catalogService.dispose();
    _hostController.dispose();
    _sharingIntentSub?.cancel();
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
        // **Top inset fixed 2026-08-15** — live report: with the control
        // bar revealed on Android (e.g. `revealAndroidSystemUiTemporarily`
        // bringing the system status bar back to tap Connect), the bar's
        // buttons sat directly under the status bar (clock etc.), not
        // reachable. `top: isDesktopPlatform` unconditionally skipped the
        // inset on Android on the theory that the app always runs
        // edge-to-edge there — true when the control bar is hidden
        // (immersive video), but wrong the moment it's shown alongside a
        // revealed status bar. Desktop's own window chrome makes this a
        // no-op there either way, so always insetting is safe. Left/right
        // stay unconditionally false — this is a top-vs-bottom fix, not a
        // "wrap everything" one, and an accidental horizontal inset here
        // was live-reproduced pushing the control bar into an overflow on
        // narrower/portrait screens (see git history for the broken
        // version this replaced).
        top: isDesktopPlatform || _controlsVisible,
        bottom: isDesktopPlatform,
        left: false,
        right: false,
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
            // **Fixed-width `SizedBox(width: 160)` replaced with a flexible
            // one 2026-08-15** — live-reproduced overflowing this row on a
            // narrower/portrait screen (a fixed 160dp text field left too
            // little room for the buttons that follow). `flex: 2` against
            // the trailing status text's `flex: 1` keeps the host field
            // comfortably larger while still letting both shrink together
            // instead of one pushing the other off-screen.
            Flexible(
              flex: 2,
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
      unawaited(_catalogService.disconnect());
      return;
    }
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    await _connectBoth(host);
  }

  /// Picks a `.gpx` file via the system file picker and hands it to
  /// [_importGpxFrom]. This is one of two entry points into the same import
  /// flow — the other is [_handleSharedFiles], triggered when another app's
  /// Android "Share..." sheet sends a GPX file straight to Remote Helm
  /// (see AndroidManifest.xml's intent-filters). Both end up parsing the
  /// file ([parseGpxRoutes]), letting the user choose which route to import
  /// (if there's more than one `<rte>`, mirroring the plotter-selection
  /// flow in [_onDiscoverPressed]), and syncing it.
  ///
  /// **Only uses [syncRoute] (`route_sync.dart`) — does NOT durably save to
  /// the plotter's route catalog.** [RouteCatalogConnection.addOrUpdateRoute]
  /// used to be run here too (unconditionally, before offering to also
  /// navigate), but is disabled as of 2026-08-15: every route it has ever
  /// created reliably crashes the plotter's own touch-screen editor the
  /// moment a human opens that route there afterward — confirmed live,
  /// repeatedly, root cause not yet found (see
  /// remote_helm_re/findings/00_STATUS.md Updates 127-129). [syncRoute]
  /// activates the route for immediate navigation without saving it to the
  /// catalog, and has never been implicated in that bug — it's the only
  /// safe way to get a GPX route onto the plotter right now. This means a
  /// GPX import is temporarily navigation-only: it won't appear later in
  /// Browse/Delete. [syncRoute] itself has no hard point-count limit, but
  /// only a 4-point route is verified byte-for-byte against a real capture
  /// — see [_importGpxFrom]'s doc comment for the caveats on anything else.
  ///
  /// **Known side effect, accepted for now (confirmed live 2026-08-15):**
  /// [syncRoute]'s wire format itself encodes one waypoint-shaped record per
  /// route point (see route_sync.dart's own top doc comment on the
  /// "waypoint" record layout) — same as the real app's own catalog-save
  /// path, which is exactly the clutter [addOrUpdateRoute] was written to
  /// avoid (see its doc comment, Update 11 in 00_STATUS.md). Since
  /// [addOrUpdateRoute] is currently disabled for the crash bug above,
  /// there's no way to import a GPX route right now without also getting
  /// this: each imported route durably leaves one waypoint entry per point
  /// sitting in the plotter's waypoint catalog. User-accepted tradeoff
  /// until [addOrUpdateRoute]'s crash is root-caused and it can be turned
  /// back on.
  Future<void> _onImportGpxPressed() async {
    const gpxType = XTypeGroup(label: 'GPX', extensions: ['gpx']);
    final file = await openFile(acceptedTypeGroups: const [gpxType]);
    if (file == null) return;
    await _importGpxFrom(file.readAsString());
  }

  /// Shared tail of both GPX import entry points — the toolbar's file
  /// picker ([_onImportGpxPressed]) and an incoming Android share
  /// ([_handleSharedFiles]) — from "here's the file's text content" through
  /// parsing, the route-picker dialog, and [syncRoute]. [gpxText] is a
  /// `Future` (not a plain `String`) so callers can pass a not-yet-awaited
  /// read straight through without an extra `await`/try block of their own.
  Future<void> _importGpxFrom(Future<String> gpxText) async {
    List<GpxRoute> routes;
    try {
      routes = parseGpxRoutes(await gpxText);
    } on GpxParseException catch (e) {
      _showSnack('Could not read that GPX file: $e');
      return;
    } on Object catch (e) {
      _showSnack('Could not read that GPX file: $e');
      return;
    }
    if (routes.isEmpty) {
      _showSnack('No routes found in that GPX file.');
      return;
    }

    // See [_initDone]'s doc comment — this is the actual fix for the
    // cold-start-via-share bug (host read as null). Already-completed on
    // every non-cold-start path (toolbar button, or a share arriving while
    // the app was already running), so this is a no-op there.
    await _initDone.future;

    if (!mounted) return;
    final choice = await showDialog<_GpxImportChoice>(
      context: context,
      builder: (context) => _GpxImportDialog(routes: routes),
    );
    if (choice == null) return;
    final chosen = choice.route;

    // **addOrUpdateRoute (catalog-persistent save) intentionally NOT
    // called here as of 2026-08-15** — see this method's own top doc
    // comment for why. [syncRoute]/[encodeRoute] have no actual point-count
    // limit (the record format is built dynamically per point, see
    // route_sync.dart's own doc comment) — a hard "exactly 4 points" check
    // used to live here, but that was this method's own mistaken belief,
    // not a real constraint in route_sync.dart; removed 2026-08-15. Only
    // the 4-point case is verified against a real capture byte-for-byte,
    // though; an 8-point capture also exists but its `routeMarkerByte`
    // (route_sync.dart's [_kDefaultRouteMarkerByte] doc comment) differs
    // from what's actually sent, and point counts beyond that are wholly
    // untested — so this is optimistic, not proven, for anything other
    // than 4 points.

    // **Wait for a genuinely stable connection — and read [_session.lastHost]
    // only AFTER that wait, not before — added 2026-08-15, corrected the
    // same day.** Two things can otherwise go wrong: (a) this can run right
    // after an Android cold start via an incoming share intent, with no
    // saved host at all yet (first-ever connect on this install, or one
    // freshly reinstalled) — [_session]'s [HelmSessionController.connect]
    // only calls its own `_saveLastHost` on a SUCCESSFUL connect, so
    // reading `lastHost` before that finishes reliably returns null even
    // though [_init]'s [_autoDiscoverAndConnect] fallback is actively
    // finding and connecting to a plotter in the background — confirmed
    // live via debug logging (`host=null isConnected=false` immediately
    // after `_initDone` completes, because `_initDone` only waits for
    // `loadLastHost`, not for discovery+connect to finish). Reading `host`
    // only after [_waitForStableConnection] returns true fixes this: by
    // then, whichever path connected (saved host or discovery) has already
    // called `_saveLastHost`. (b) even once connected, live testing
    // elsewhere in this app found the plotter can be briefly unreliable
    // (refused/timed-out connections, even a transient full network drop)
    // when a second channel's handshake starts immediately after the first
    // settles, though each works fine in isolation once given a moment —
    // [_waitForStableConnection]'s settle delay covers that too.
    if (!mounted) return;
    _showSnack('Waiting for a stable connection…');
    final stable = await _waitForStableConnection();
    if (!stable) {
      _showSnack('Could not reach the plotter — GPX import cancelled.');
      return;
    }

    final host = _session.lastHost;
    if (host == null || host.isEmpty) {
      _showSnack('Could not determine the plotter address — GPX import cancelled.');
      return;
    }

    // The plotter may prompt the user to confirm activating navigation on
    // its own screen before syncRoute's handshake completes — [timeout]
    // raised well past the 6s default so that a slow tap doesn't get
    // reported as a failure while it's actually still waiting on the user.
    _showSnack('Sending "${chosen.name}" — confirm on the plotter to start navigating.');
    try {
      await syncRoute(host, chosen.name, chosen.points, timeout: const Duration(seconds: 30));
      _showSnack('Now navigating "${chosen.name}".');
    } on RouteSyncTimeoutException catch (e) {
      _showSnack('The plotter did not respond to the navigate request: $e');
    } on Object catch (e) {
      _showSnack('Failed to start navigating: $e');
    }
  }

  /// Blocks until [_session] reports a real, connected state, then waits a
  /// further settle period before returning — see the call site's doc
  /// comment (in [_importGpxFrom]) for why both halves matter. Returns
  /// `false` (without throwing) if the connection doesn't come up within
  /// [maxWait], so the caller can show one clear message instead of
  /// [syncRoute] failing later with a less obvious timeout.
  Future<bool> _waitForStableConnection({
    // Generous enough to cover a cold start with no saved host at all —
    // [_autoDiscoverAndConnect]'s own mDNS browse already budgets 5s, plus
    // however long the subsequent connect handshake takes, so 20s cut it
    // close in exactly the case this method exists for.
    Duration maxWait = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(maxWait);
    while (!_session.isConnected) {
      if (DateTime.now().isAfter(deadline)) return false;
      if (!mounted) return false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await Future<void>.delayed(settleDelay);
    return mounted && _session.isConnected;
  }

  Future<void> _onBrowseCatalogPressed() async {
    await showRouteCatalogDialog(context, _catalogService);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Result of [_GpxImportDialog]: which route to import. Only ever used to
/// start active navigation on it via [syncRoute] — see
/// `_HelmHomeScreenState._onImportGpxPressed`'s doc comment for why
/// [RouteCatalogConnection.addOrUpdateRoute] (catalog-persistent save) is
/// not used.
class _GpxImportChoice {
  final GpxRoute route;
  const _GpxImportChoice({required this.route});
}

/// Lets the user pick which `<rte>` to import (if a GPX file has more than
/// one). **Navigation-only as of 2026-08-15** — see
/// `_HelmHomeScreenState._onImportGpxPressed`'s own doc comment for why
/// the previous "start navigating immediately" checkbox (an optional
/// extra on top of always saving to the catalog) was removed: saving to
/// the catalog is disabled, so navigating immediately is now the only
/// thing importing does, not a checkbox.
class _GpxImportDialog extends StatefulWidget {
  final List<GpxRoute> routes;
  const _GpxImportDialog({required this.routes});

  @override
  State<_GpxImportDialog> createState() => _GpxImportDialogState();
}

class _GpxImportDialogState extends State<_GpxImportDialog> {
  late GpxRoute _selected = widget.routes.first;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import GPX route'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.routes.length > 1)
            DropdownButton<GpxRoute>(
              value: _selected,
              isExpanded: true,
              items: [
                for (final r in widget.routes)
                  DropdownMenuItem(value: r, child: Text('${r.name} (${r.points.length} points)')),
              ],
              onChanged: (r) => setState(() => _selected = r ?? _selected),
            )
          else
            Text('${_selected.name} (${_selected.points.length} points)'),
          const SizedBox(height: 8),
          const Text(
            'This starts navigating the route immediately — it does not save it to the '
            "plotter's route list. May prompt you to confirm on the plotter itself.",
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_GpxImportChoice(route: _selected)),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
