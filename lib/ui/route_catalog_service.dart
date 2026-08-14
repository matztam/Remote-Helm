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

  /// This topic's currently-known entries as `[uuid, vstamp]` pairs, in
  /// the shape [RouteCatalogConnection.fetchCatalogAndObjects]'s
  /// `knownEntries` parameter expects for a differential sync on a later
  /// `connect()` — see that parameter's own doc comment. `topic` is
  /// irrelevant to what a differential sync request encodes (only
  /// uuid/vstamp are), so any fixed value works; `topicRoutes` is used
  /// arbitrarily rather than adding a topic parameter nothing reads.
  ///
  /// Uses [DownloadedObject.vstamp] (the object's own JSON `"vstamp"`
  /// field), not a separately-tracked catalog-entry vstamp — this service
  /// never stores the latter once an object is fully downloaded. Both are
  /// documented as the plotter's version-stamp for the same object from
  /// two different messages (see [CatalogEntry.vstamp]'s and
  /// [DownloadedObject.vstamp]'s own doc comments) — treated as
  /// interchangeable here, consistent with how [RouteCatalogConnection.
  /// deleteEntry] already uses a [DownloadedObject]-sourced vstamp as
  /// `del_vstamp`. Not independently confirmed for a differential sync
  /// request specifically.
  List<CatalogEntry> get _knownEntries => [
    for (final o in _byUuid.values) CatalogEntry(uuid: o.uuid, topic: topicRoutes, vstamp: o.vstamp),
  ];
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

  /// **Debug/investigation flag: when false (the default), [connect] never
  /// passes `knownEntries`, always using the N=0 sync — added 2026-08-13.**
  /// The differential sync itself ([RouteCatalogConnection._buildCatalogSyncBody])
  /// got NO reply at all, twice in a row, in live testing of a second
  /// `connect()` on the same session (63-75 known routes/waypoints) — see
  /// `remote_helm_re/findings/00_STATUS.md` Update 34. Not yet understood
  /// whether that's the one unresolved record-encoding edge case (Update
  /// 33), the un-chunked sync request itself being too large at this
  /// entry count (never tested smaller), or something else — kept off by
  /// default so a second-or-later [connect] doesn't reliably fail while
  /// this is unresolved. [TopicCatalog._knownEntries] and the wiring below
  /// are otherwise complete and ready once this is confirmed safe.
  static bool debugUseDifferentialSync = false;

  /// Opens one [RouteCatalogConnection], does exactly one
  /// [RouteCatalogConnection.fetchCatalogAndObjects] per topic to seed the
  /// local copies, then leaves the connection open and listening on
  /// [RouteCatalogConnection.pushes] for the rest of this service's
  /// lifetime (until [disconnect]/[dispose]).
  ///
  /// **Chunked since 2026-08-13** — a single unchunked batch content
  /// download for a topic this size (currently 64 real routes, each
  /// carrying many embedded points) was live-confirmed to reset the
  /// plotter's TCP connection outright; see [RouteCatalogConnection.
  /// fetchObjectsChunked]'s doc comment. Live-confirmed working end-to-end
  /// through this method specifically (not just in isolation): a real
  /// connect loaded 63 routes/128 waypoints/1 track with no reset.
  ///
  /// **Differential sync gated behind [debugUseDifferentialSync] (off by
  /// default)** — see that flag's own doc comment for why: passing
  /// [TopicCatalog._knownEntries] as `knownEntries` (so a second-or-later
  /// connect only needs the plotter to describe what's new/changed) is
  /// implemented but not yet live-confirmed safe.
  Future<void> connect(String host, {Duration timeout = const Duration(seconds: 30)}) async {
    // Captured before [disconnect] runs (below) -- disconnect() itself
    // never clears these, but reading them first removes any doubt about
    // ordering as this method evolves.
    final knownRoutes = debugUseDifferentialSync ? routes._knownEntries : const <CatalogEntry>[];
    final knownWaypoints = debugUseDifferentialSync ? waypoints._knownEntries : const <CatalogEntry>[];
    final knownTracks = debugUseDifferentialSync ? tracks._knownEntries : const <CatalogEntry>[];

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
      final routeObjects = await conn.fetchCatalogAndObjects(topicRoutes, knownEntries: knownRoutes);
      routes._replaceAll(routeObjects);
      final waypointObjects = await conn.fetchCatalogAndObjects(topicWaypoints, knownEntries: knownWaypoints);
      waypoints._replaceAll(waypointObjects);
      final trackObjects = await conn.fetchCatalogAndObjects(topicTrack, knownEntries: knownTracks);
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
