import 'dart:io';
import '../lib/helm/route_catalog.dart';

/// Manual live smoke test for [RouteCatalogConnection.addOrUpdateRoute]
/// against a real plotter. See that method's own doc comment for the
/// current status — the `points` shape it sends (embedded lon/lat, no
/// per-point waypoint references) is unvalidated against any real
/// capture. Use [verify_waypoint_exists.dart]'s pattern (topicRoutes
/// instead) right after this to check whether the route durably appeared.
Future<void> main() async {
  const host = '172.16.6.0';
  const testName = 'CLAUDE_ROUTE1';
  const points = [
    (55.70, 10.05),
    (55.71, 10.07),
    (55.72, 10.10),
  ];

  RouteCatalogConnection.debugTrace = true;

  stdout.writeln('Connecting to $host:$routeCatalogPort …');
  final conn = await RouteCatalogConnection.connect(host, timeout: const Duration(seconds: 15));

  stdout.writeln('addOrUpdateRoute("$testName", $points) …');
  final uuid = await conn.addOrUpdateRoute(testName, points, timeout: const Duration(seconds: 45));
  stdout.writeln('addOrUpdateRoute() returned, no exception. uuid=$uuid');

  await conn.close();
}
