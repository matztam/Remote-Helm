import 'dart:io';
import '../lib/helm/route_catalog.dart';

/// Manual live smoke test for [RouteCatalogConnection.addOrUpdateWaypoint]
/// against a real plotter. See [addOrUpdateWaypoint]'s own doc comment for
/// the current status: the message sends successfully (structurally
/// byte-perfect against the one real capture available) but has not yet
/// been confirmed to durably appear in the plotter's catalog afterward —
/// use [verify_waypoint_exists.dart] right after this to check.
Future<void> main() async {
  const host = '172.16.6.0';
  const testName = 'CLAUDE_TEST19';
  const testLat = 55.7;
  const testLon = 10.05;

  RouteCatalogConnection.debugTrace = true;

  stdout.writeln('Connecting to $host:$routeCatalogPort …');
  final conn = await RouteCatalogConnection.connect(host, timeout: const Duration(seconds: 15));

  stdout.writeln('addOrUpdateWaypoint("$testName", $testLat, $testLon) …');
  final uuid = await conn.addOrUpdateWaypoint(testName, testLat, testLon, timeout: const Duration(seconds: 15));
  stdout.writeln('addOrUpdateWaypoint() returned, no exception. uuid=$uuid');

  await conn.close();
}
