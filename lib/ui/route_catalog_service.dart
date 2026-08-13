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

  /// Opens one [RouteCatalogConnection], does exactly one
  /// [RouteCatalogConnection.fetchCatalogAndObjects] per topic to seed the
  /// local copies, then leaves the connection open and listening on
  /// [RouteCatalogConnection.pushes] for the rest of this service's
  /// lifetime (until [disconnect]/[dispose]).
  Future<void> connect(String host, {Duration timeout = const Duration(seconds: 30)}) async {
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
      final routeObjects = await conn.fetchCatalogAndObjects(topicRoutes);
      routes._replaceAll(routeObjects);
      final waypointObjects = await conn.fetchCatalogAndObjects(topicWaypoints);
      waypoints._replaceAll(waypointObjects);
      final trackObjects = await conn.fetchCatalogAndObjects(topicTrack);
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
    final resultUuid = await conn.addOrUpdateWaypoint(name, lat, lon, uuid: uuid);
    waypoints._put(DownloadedObject(name: name, uuid: resultUuid, points: [RoutePoint(name: name, lat: lat, lon: lon)]));
    notifyListeners();
    return resultUuid;
  }

  /// Creates/updates a route — see [addOrUpdateWaypoint]'s doc comment for
  /// why the local copy is updated optimistically rather than by waiting
  /// for a push.
  Future<String> addOrUpdateRoute(String name, List<(double lat, double lon)> points, {String? uuid}) async {
    final conn = _requireConn();
    final resultUuid = await conn.addOrUpdateRoute(name, points, uuid: uuid);
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
  /// immediately — see [addOrUpdateWaypoint]'s doc comment for why.
  /// [vstamp] is passed straight through to
  /// [RouteCatalogConnection.deleteEntry] — see its own doc comment for
  /// why a caller-supplied one should still be passed when known, even
  /// though that method re-syncs it if stale.
  Future<void> deleteEntry(int topic, String uuid, {int? vstamp}) async {
    final conn = _requireConn();
    await conn.deleteEntry(topic, uuid, vstamp: vstamp);
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

  Future<void> disconnect() async {
    await _conn?.close();
    _conn = null;
    routes._replaceAll(const []);
    waypoints._replaceAll(const []);
    tracks._replaceAll(const []);
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
