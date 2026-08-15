// Manual, one-off live test against a real plotter -- NOT part of the
// normal `flutter test` suite (this directory is separate from `test/`).
// Run explicitly: `flutter test test_manual/debug_crash_repro_test.dart`
//
// Reproduces the exact sequence the user reported causing the plotter to
// crash/reboot: create a waypoint, delete it via the app, then import a
// route -- all in quick succession on one long-lived RouteCatalogService
// connection. Two fixes (36ac63a: stop always re-syncing before a write;
// 576f267: keep _remoteVerByTopic current from incoming pushes) did NOT
// resolve it when the user retried live. This script reproduces it under
// full trace to see the actual byte sequence right before the plotter
// stops responding.
//
// **Known limitation**: step 1 creates the waypoint via this same client
// (addOrUpdateWaypoint) rather than literally on the plotter's own touch
// screen, since this script can't drive the physical plotter. The user's
// original report was a real on-plotter creation arriving as a push; this
// substitutes a self-created waypoint instead. If this script does NOT
// reproduce the crash, that difference (push-originated vs. self-sent)
// is one clear place the real cause could still be hiding -- see this
// file's own findings write-up in remote_helm_re for that reasoning.
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/route_catalog.dart';
import 'package:remote_helm/ui/route_catalog_service.dart';

void main() {
  test('reproduce: create waypoint, delete it, immediately import a route', () async {
    const host = '172.16.6.0';
    void log(String msg) => print('[${DateTime.now().toIso8601String()}] $msg');

    RouteCatalogConnection.debugTrace = true;
    final service = RouteCatalogService();

    log('Step 0: service.connect() …');
    await service.connect(host);
    log('  state=${service.state} message=${service.statusMessage}');
    expect(service.state, RouteCatalogServiceState.ready, reason: service.statusMessage);
    log('  routes=${service.routes.length} waypoints=${service.waypoints.length} tracks=${service.tracks.length}');

    log('Step 1: addOrUpdateWaypoint("CLAUDE_CRASH_WPT", ...) — substitute for a real on-plotter creation, see this file\'s own doc comment …');
    final wptUuid = await service.addOrUpdateWaypoint('CLAUDE_CRASH_WPT', 55.70, 10.05);
    log('  waypoint created, uuid=$wptUuid');

    log('Step 2: service.deleteEntry(topicWaypoints, $wptUuid) — immediately, no pause …');
    await service.deleteEntry(topicWaypoints, wptUuid);
    log('  deleteEntry returned, no exception.');

    log('Step 3: service.addOrUpdateRoute("CLAUDE_CRASH_REPRO", ...) — immediately after, no pause, as a fast user click sequence would …');
    String? routeUuid;
    try {
      routeUuid = await service.addOrUpdateRoute('CLAUDE_CRASH_REPRO', const [
        (55.70, 10.05),
        (55.71, 10.07),
        (55.72, 10.10),
        (55.73, 10.12),
      ]);
      log('  addOrUpdateRoute returned, no exception. uuid=$routeUuid');
    } on Object catch (e) {
      log('  addOrUpdateRoute FAILED: $e');
    }

    log('Step 4: waiting 5s, then checking whether the plotter still responds (ping) …');
    await Future<void>.delayed(const Duration(seconds: 5));

    // ping from within Dart via a raw socket probe is unreliable across
    // platforms; the actual ping check happens from the shell right after
    // this test run (see the agent prompt) -- this test itself just
    // confirms whether the SERVICE connection is still usable afterward.
    log('Step 5: probing whether THIS connection still works (a fresh fetchCatalogUnfiltered on a NEW connection) …');
    try {
      final probeConn = await RouteCatalogConnection.connect(host, timeout: const Duration(seconds: 15));
      final entries = await probeConn.fetchCatalogUnfiltered(topicRoutes, timeout: const Duration(seconds: 30));
      await probeConn.close();
      log('  Probe OK: plotter still responds, ${entries.length} route entries.');
    } on Object catch (e) {
      log('  Probe FAILED: plotter unresponsive after the sequence above: $e');
    }

    await service.disconnect();
    log('Done.');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
