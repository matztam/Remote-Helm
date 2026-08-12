import 'dart:io';
import '../lib/helm/route_catalog.dart';

Future<void> main(List<String> args) async {
  const host = '172.16.6.0';
  if (args.isEmpty) {
    stdout.writeln('Usage: dart bin/verify_waypoint_exists.dart <uuid>');
    exit(2);
  }
  final targetUuid = args[0];

  stdout.writeln('Connecting to $host:$routeCatalogPort …');
  final conn = await RouteCatalogConnection.connect(host, timeout: const Duration(seconds: 10));
  stdout.writeln('fetchCatalog(waypoints) …');
  final entries = await conn.fetchCatalog(topicWaypoints, timeout: const Duration(seconds: 60));
  stdout.writeln('  ${entries.length} entries');
  final found = entries.any((e) => e.uuid == targetUuid);
  stdout.writeln(found ? '=== FOUND: $targetUuid ===' : '!!! NOT FOUND: $targetUuid');
  await conn.close();
}
