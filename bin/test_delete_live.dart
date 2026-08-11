import 'dart:io';
import '../lib/helm/route_catalog.dart';

Future<void> main(List<String> args) async {
  const host = '172.16.6.0';

  if (args.isEmpty) {
    stdout.writeln('Usage: dart bin/test_delete_live.dart [<uuid-to-delete>]');
    stdout.writeln('  (no args: just list the catalog)');
  }

  RouteCatalogConnection.debugTrace = true;

  // **Isolation test, 2026-08-09**: deliberately NOT setting
  // debugClientUnitId this run (leaving it at its random 20-bit
  // per-process fallback) to check whether mirroring this plotter's real
  // hardware unit-id (0x32d44, learned from its own sync replies) was
  // actually necessary for the first successful delete, or just cosmetic
  // -- the del_vstamp field-tag fix (see route_catalog.dart's
  // _buildDeleteTrailer doc comment) is the confirmed root-cause fix;
  // this run isolates whether unitId matters on top of that.

  if (args.isEmpty) {
    stdout.writeln('Connecting to $host:$routeCatalogPort …');
    final conn = await RouteCatalogConnection.connect(host);
    stdout.writeln('fetchCatalog(routes) …');
    final entries = await conn.fetchCatalog(topicRoutes);
    stdout.writeln('  ${entries.length} entries');
    for (final e in entries) {
      stdout.writeln('    ${e.uuid}  vstamp=${e.vstamp}');
    }
    await conn.close();
    return;
  }

  // **Reverted 2026-08-09**: `debugSyncOtherTopics = true` (the 3-topic
  // burst) was enabled here based on a capture that showed the real app
  // doing that on one delete's connection -- but this file's own
  // long-documented history (see fetchCatalog's doc comment) already
  // found topic 0x4's sync reliably gets NO reply on this real plotter,
  // which is why the library defaults this OFF. Four separate live
  // attempts today (this file, and a no-op write diagnostic on both
  // topicWaypoints and topicRoutes) all failed at the SYNC step itself
  // once debugSyncOtherTopics was on, while plain single-topic
  // fetchCatalog kept working reliably throughout. Going back to the
  // library's own default (single-topic sync only) to test the
  // corrected delete wire format without this confound.
  stdout.writeln('Connecting (single connection, default single-topic sync) …');
  final conn = await RouteCatalogConnection.connect(host);

  final target = args[0];
  stdout.writeln('\nDeleting $target …');
  await conn.deleteEntry(topicRoutes, target);
  stdout.writeln('deleteEntry() returned, no exception.');

  await conn.close();

  stdout.writeln('\nWaiting 5s, then reconnecting fresh to verify …');
  await Future<void>.delayed(const Duration(seconds: 5));

  final conn2 = await RouteCatalogConnection.connect(host);
  final after = await conn2.fetchCatalog(topicRoutes);
  stdout.writeln('  ${after.length} entries');
  final stillThere = after.any((e) => e.uuid == target);
  stdout.writeln(stillThere ? '\n!!! STILL PRESENT — delete did NOT work' : '\n=== GONE — delete WORKED ===');
  await conn2.close();
}
