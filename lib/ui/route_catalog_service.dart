/// Owns a single, long-lived [RouteCatalogConnection] per topic (routes,
/// waypoints, tracks) and a local, in-memory copy of each topic's catalog
/// — kept in sync the same way the real ActiveCaptain app is: **one sync
/// on connect, then never again**, relying entirely on the plotter's own
/// unprompted [RouteCatalogConnection.pushes] to learn about anything that
/// changes afterward (this client's own writes, the real app's writes, or
/// changes made directly on the plotter's screen — all three arrive the
/// same way, see [RouteCatalogConnection.pushes]' own doc comment for the
/// real capture this is based on).
///
/// **Why not just re-sync when something changes?** Live testing against
/// a real plotter found this actively risky, not just wasteful: a second
/// [tCatalogSync] on an already-synced connection/topic reliably made the
/// plotter reset the connection outright at this catalog's size (200+
/// entries), and even a fresh second connection's sync reply sometimes
/// simply never arrived. The real app never re-syncs after its first
/// sync on a connection either, and neither does this service.
library;

import 'package:flutter/foundation.dart';

import '../helm/route_catalog.dart';

/// One topic's local catalog state: every object this service currently
/// believes exists on the plotter, keyed by uuid.
class TopicCatalog {
  final Map<String, DownloadedObject> _byUuid = {};

  List<DownloadedObject> get all => _byUuid.values.toList(growable: false);
  DownloadedObject? operator [](String uuid) => _byUuid[uuid];
  int get length => _byUuid.length;

  void _put(DownloadedObject object) => _byUuid[object.uuid] = object;
  void _remove(String uuid) => _byUuid.remove(uuid);
  void _replaceAll(Iterable<DownloadedObject> objects) {
    _byUuid.clear();
    for (final o in objects) {
      _byUuid[o.uuid] = o;
    }
  }
}

enum RouteCatalogServiceState { idle, connecting, syncing, ready, error }

/// App-wide catalog service — one instance, created alongside
/// [HelmSessionController] and connected/disconnected together with it.
class RouteCatalogService extends ChangeNotifier {
  RouteCatalogConnection? _conn;
  RouteCatalogServiceState _state = RouteCatalogServiceState.idle;
  String? _statusMessage;

  /// When the last catalog write (add/update/delete) on this connection
  /// finished, if any — see [_waitForWriteSpacing]'s doc comment.
  DateTime? _lastWriteAt;

  /// **Added 2026-08-13** after live-reproducing a plotter lockout
  /// (`no reply from the plotter` on the next request, "User data sharing
  /// disabled" screen) from sending three fire-and-forget catalog writes
  /// back-to-back with no pause at all (create a waypoint, delete it,
  /// create a route — all under 1ms apart in a real trace). None of these
  /// writes wait for a reply (the protocol doesn't send one), so nothing
  /// naturally paced them before this was added. This enforces a minimum
  /// gap between the end of one write and the start of the next on this
  /// connection, regardless of which of [addOrUpdateWaypoint]/
  /// [addOrUpdateRoute]/[deleteEntry] either one is.
  static const _minWriteSpacing = Duration(seconds: 2);

  Future<void> _waitForWriteSpacing() async {
    final last = _lastWriteAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < _minWriteSpacing) {
        await Future<void>.delayed(_minWriteSpacing - elapsed);
      }
    }
  }

  final TopicCatalog routes = TopicCatalog();
  final TopicCatalog waypoints = TopicCatalog();
  final TopicCatalog tracks = TopicCatalog();

  RouteCatalogServiceState get state => _state;
  String? get statusMessage => _statusMessage;
  bool get isReady => _state == RouteCatalogServiceState.ready;

  TopicCatalog _catalogForTopic(int topic) => switch (topic) {
    topicRoutes => routes,
    topicWaypoints => waypoints,
    topicTrack => tracks,
    _ => throw ArgumentError('unknown topic 0x${topic.toRadixString(16)}'),
  };

  void _setState(RouteCatalogServiceState s, {String? message}) {
    _state = s;
    _statusMessage = message;
    notifyListeners();
  }

  /// **Debug/investigation flag: when false, [connect] never passes
  /// `knownObjects`, always using the N=0 sync + full download.**
  ///
  /// Off by default again as of 2026-08-14 (was briefly `true` the same
  /// day). The crash this whole rework was for is fixed by the *other*
  /// half of it alone: a first-ever sync now sends exactly one unchunked
  /// batch [tGetObject] instead of the old chunked multi-request burst,
  /// and that alone was confirmed live, twice, to no longer crash the
  /// plotter (see `remote_helm_re/findings/00_STATUS.md` Update 76). The
  /// differential half (this flag) is a separate, non-essential
  /// optimization — a faster reconnect once a catalog is already cached —
  /// and live testing found the plotter simply never replies to the
  /// non-empty digest even though it's now byte-verified correct against
  /// a real capture (Update 75's fix to `_buildCatalogSyncBody`): no
  /// crash, just a silent timeout. Since the crash fix doesn't need this
  /// path, leave it off until the digest's actual reply requirements are
  /// understood, and flip back to `true` only for further differential-
  /// sync investigation, not for normal use.
  static bool debugUseDifferentialSync = false;

  /// Opens one [RouteCatalogConnection], does exactly one
  /// [RouteCatalogConnection.fetchCatalogAndObjects] per topic to seed the
  /// local copies, then leaves the connection open and listening on
  /// [RouteCatalogConnection.pushes] for the rest of this service's
  /// lifetime (until [disconnect]/[dispose]).
  ///
  /// **Sync/download shape reworked 2026-08-14** — one content request per
  /// topic, never a chunked burst: a first-ever sync downloads everything
  /// in a single batch request, a later sync sends the plotter this
  /// service's cached objects as a differential digest and downloads only
  /// the delta (merged over the cache inside
  /// [RouteCatalogConnection.fetchCatalogAndObjects] — see its doc comment
  /// for the crash-capture evidence that forced this rework, and
  /// [debugUseDifferentialSync] for the rollback flag).
  Future<void> connect(String host, {Duration timeout = const Duration(seconds: 30)}) async {
    // Captured before [disconnect] runs (below) -- disconnect() itself
    // never clears these, but reading them first removes any doubt about
    // ordering as this method evolves.
    final knownRoutes = debugUseDifferentialSync ? routes.all : const <DownloadedObject>[];
    final knownWaypoints = debugUseDifferentialSync ? waypoints.all : const <DownloadedObject>[];
    final knownTracks = debugUseDifferentialSync ? tracks.all : const <DownloadedObject>[];

    await disconnect();
    _setState(RouteCatalogServiceState.connecting, message: 'Connecting to $host…');
    final RouteCatalogConnection conn;
    try {
      conn = await RouteCatalogConnection.connect(host, timeout: timeout);
    } on Object catch (e) {
      _setState(RouteCatalogServiceState.error, message: 'Could not connect: $e');
      return;
    }
    _conn = conn;

    _setState(RouteCatalogServiceState.syncing, message: 'Loading catalog…');
    try {
      final routeObjects = await conn.fetchCatalogAndObjects(topicRoutes, knownObjects: knownRoutes);
      routes._replaceAll(routeObjects);
      // **Gap added 2026-08-15 (remote_helm_re/findings/00_STATUS.md
      // Updates 124/125) — the actual root cause of this whole session's
      // main crash.** A live-isolated minimal repro proved a SECOND
      // tCatalogSync for a DIFFERENT topic on the SAME connection, sent
      // within ~9-10s of a first topic's completed sync, reliably crashes
      // the plotter (RST ~9-10s later) -- with zero write operations and a
      // verified-empty catalog, ruling out every previous storage/content
      // theory. A single topic sync alone never crashes. A second sync
      // after a 15s gap is safe (also live-verified). This delay is a
      // confirmed-safe but not yet minimized workaround -- 15s was the
      // first value tried, not bisected down from the ~9-10s failure
      // window, so it likely has more margin than strictly needed.
      await Future<void>.delayed(const Duration(seconds: 15));
      final waypointObjects = await conn.fetchCatalogAndObjects(topicWaypoints, knownObjects: knownWaypoints);
      waypoints._replaceAll(waypointObjects);
      await Future<void>.delayed(const Duration(seconds: 15));
      final trackObjects = await conn.fetchCatalogAndObjects(topicTrack, knownObjects: knownTracks);
      tracks._replaceAll(trackObjects);
    } on Object catch (e) {
      _setState(RouteCatalogServiceState.error, message: 'Could not load catalog: $e');
      return;
    }

    conn.pushes.listen(
      _handlePush,
      onError: (Object _) {
        // A closed/broken connection surfaces here -- nothing to do beyond
        // what [disconnect] already handles; a caller noticing [state]
        // drop out of [RouteCatalogServiceState.ready] is expected to
        // reconnect explicitly rather than this service silently retrying.
      },
    );

    // Marks "now" as the last write-like activity on this connection, so
    // [_waitForWriteSpacing] also paces the FIRST write after connecting,
    // not just writes after each other. Added after a live plotter
    // crash/reboot on a GPX route import that happened seconds after
    // connecting — the exact same "plotter reset while a request was still
    // being processed" symptom [_minWriteSpacing] was added for between
    // consecutive writes, but never guarded against for the sync burst
    // [connect] itself just did (three chunked topic downloads) followed
    // immediately by a write.
    _lastWriteAt = DateTime.now();

    _setState(RouteCatalogServiceState.ready, message: 'Catalog ready.');
  }

  void _handlePush(CatalogPush push) {
    final catalog = _catalogForTopic(push.topic);
    switch (push) {
      case CatalogPushUpdate(:final object):
        catalog._put(object);
      case CatalogPushDelete(:final uuid):
        catalog._remove(uuid);
    }
    notifyListeners();
  }

  /// Creates/updates a waypoint and applies the same change to the local
  /// copy immediately — **not** by waiting for the plotter to push it
  /// back (unconfirmed whether it pushes a write back to the same
  /// connection that sent it, and waiting for that round-trip would
  /// reintroduce exactly the latency/reliability risk this service exists
  /// to avoid). If the plotter does also push it back, [_handlePush]
  /// simply applies the same (or corrected) state again — harmless, since
  /// both paths converge on the same [TopicCatalog._put] by uuid.
  Future<String> addOrUpdateWaypoint(String name, double lat, double lon, {String? uuid}) async {
    final conn = _requireConn();
    await _waitForWriteSpacing();
    final resultUuid = await conn.addOrUpdateWaypoint(name, lat, lon, uuid: uuid);
    _lastWriteAt = DateTime.now();
    waypoints._put(DownloadedObject(name: name, uuid: resultUuid, points: [RoutePoint(name: name, lat: lat, lon: lon)]));
    notifyListeners();
    return resultUuid;
  }

  /// **See [RouteCatalogConnection.addOrUpdateRoute]'s doc comment** for
  /// the editor-crash bug this used to have and the 2026-08-16 fix, since
  /// live-confirmed.
  ///
  /// Creates/updates a route — see [addOrUpdateWaypoint]'s doc comment for
  /// why the local copy is updated optimistically rather than by waiting
  /// for a push, and for [_waitForWriteSpacing].
  Future<String> addOrUpdateRoute(String name, List<(double lat, double lon)> points, {String? uuid}) async {
    final conn = _requireConn();
    await _waitForWriteSpacing();
    final resultUuid = await conn.addOrUpdateRoute(name, points, uuid: uuid);
    _lastWriteAt = DateTime.now();
    routes._put(
      DownloadedObject(
        name: name,
        uuid: resultUuid,
        points: [for (final (lat, lon) in points) RoutePoint(name: name, lat: lat, lon: lon)],
      ),
    );
    notifyListeners();
    return resultUuid;
  }

  /// Deletes an entry and applies the same change to the local copy
  /// immediately — see [addOrUpdateWaypoint]'s doc comment for why, and
  /// for [_waitForWriteSpacing]. [vstamp] is passed straight through to
  /// [RouteCatalogConnection.deleteEntry] — see its own doc comment for
  /// why a caller-supplied one should still be passed when known, even
  /// though that method re-syncs it if stale.
  Future<void> deleteEntry(int topic, String uuid, {int? vstamp}) async {
    final conn = _requireConn();
    await _waitForWriteSpacing();
    await conn.deleteEntry(topic, uuid, vstamp: vstamp);
    _lastWriteAt = DateTime.now();
    _catalogForTopic(topic)._remove(uuid);
    notifyListeners();
  }

  RouteCatalogConnection _requireConn() {
    final conn = _conn;
    if (conn == null || _state != RouteCatalogServiceState.ready) {
      throw StateError('RouteCatalogService is not connected/ready');
    }
    return conn;
  }

  /// **Deliberately does NOT clear [routes]/[waypoints]/[tracks] — changed
  /// 2026-08-13.** Used to reset all three local copies to empty; now
  /// leaves them exactly as last known, so a following [connect] can pass
  /// them as `knownEntries` for a differential sync (see [connect]'s own
  /// doc comment) instead of re-downloading the full catalog from scratch.
  /// [RouteCatalogDialog] already only renders these when [state] is
  /// [RouteCatalogServiceState.ready] (gated behind a loading view
  /// otherwise), so the now-stale data isn't shown while disconnected —
  /// it's only ever used again once a following [connect] succeeds.
  Future<void> disconnect() async {
    await _conn?.close();
    _conn = null;
    _lastWriteAt = null;
    if (_state != RouteCatalogServiceState.idle) {
      _setState(RouteCatalogServiceState.idle);
    }
  }

  @override
  void dispose() {
    _conn?.close();
    super.dispose();
  }
}
