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
  stdout.writeln('fetchCatalogUnfiltered(waypoints) …');
  final allEntries = await conn.fetchCatalogUnfiltered(topicWaypoints, timeout: const Duration(seconds: 60));
  stdout.writeln('  ${allEntries.length} raw entries (untrimmed -- includes any non-fetchable phantom entries fetchCatalog would trim out)');
  final found = allEntries.any((e) => e.uuid == targetUuid);
  stdout.writeln(found ? '=== FOUND: $targetUuid ===' : '!!! NOT FOUND: $targetUuid');
  await conn.close();
}
