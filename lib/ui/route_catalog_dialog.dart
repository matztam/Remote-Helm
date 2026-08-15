/// A dialog listing every route/waypoint/track on the connected plotter,
/// in three tabs, letting the user pick one to save (as a `.gpx` file) or
/// share (via the platform share sheet).
///
/// **Reads from [RouteCatalogService]'s already-loaded local catalog
/// copy — does not sync anything itself, ever, including on open.**
/// An earlier version of this dialog opened its own
/// [RouteCatalogConnection] and ran a fresh [RouteCatalogConnection.
/// fetchCatalog]/[RouteCatalogConnection.fetchObjects] pair per topic
/// every time it opened. That was already an improvement over an even
/// earlier per-row-lazy-fetch version (see git history for that trail),
/// but was itself found live to be a reliability risk: opening this
/// dialog shortly after a write (e.g. right after importing a route)
/// could trigger the same "second sync on/around an already-synced
/// topic" failure mode [RouteCatalogService]'s own top doc comment
/// describes in detail — up to and including the plotter resetting the
/// TCP connection outright. Reading from [RouteCatalogService]'s
/// continuously-updated local copy instead means this dialog never
/// triggers a sync of its own, no matter when it's opened relative to a
/// recent write.
///
/// [RouteCatalogService] keeps its local copy live via the plotter's own
/// unprompted push messages ([RouteCatalogConnection.pushes]) — so this
/// dialog updates in real time if the catalog changes while it's open
/// (a delete elsewhere in the app, a change made directly on the
/// plotter, or another app's write), via [AnimatedBuilder]/
/// [ListenableBuilder] on the shared [RouteCatalogService].
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../helm/gpx.dart';
import '../helm/route_catalog.dart';
import 'route_catalog_service.dart';

/// Shows the catalog browser dialog, reading from [service]'s local
/// catalog copy. Fire-and-forget from the caller's perspective — all
/// success/error feedback happens via [ScaffoldMessenger] inside the
/// dialog itself.
Future<void> showRouteCatalogDialog(BuildContext context, RouteCatalogService service) {
  return showDialog<void>(
    context: context,
    builder: (context) => RouteCatalogDialog(service: service),
  );
}

class RouteCatalogDialog extends StatelessWidget {
  final RouteCatalogService service;
  const RouteCatalogDialog({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    // **Fixed `width: 420`/`height: 460` made responsive 2026-08-15** —
    // live-reproduced two related overflow bugs on a phone screen: (a) a
    // list row's trailing action buttons pushed off the right edge, since
    // 420dp left too little margin around the dialog for the row's three
    // IconButtons to fit; (b) once (a) was fixed, a second report showed
    // the dialog's fixed 460dp height left almost no room for the actual
    // list (below the tab bar/search field/AlertDialog's own title+actions
    // chrome) on a phone in landscape, where the whole screen is only
    // ~400-450dp tall to begin with. Both dimensions are now capped at
    // their old fixed values (unchanged on tablet/desktop, where those
    // were always comfortable) but shrink to fit smaller screens instead
    // of forcing the old fixed size regardless.
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(420.0, screenSize.width - 48);
    // 160 budgets for the AlertDialog's own title, action buttons, and
    // padding around this content box — not exact, but enough margin that
    // the whole dialog reliably fits on-screen instead of being clipped by
    // the display edges (which showDialog doesn't otherwise prevent).
    final dialogHeight = math.min(460.0, screenSize.height - 160);
    return AlertDialog(
      title: const Text('Plotter routes, waypoints & tracks'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            if (!service.isReady) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(service.statusMessage ?? 'Loading…'),
                  ],
                ),
              );
            }
            return _CatalogTabs(service: service);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}

/// The three-tab body, once a connection is available. Split out from
/// [_RouteCatalogDialogState] so each tab's own [_TopicList] can own its
/// load state independently without the dialog-level state juggling three
/// futures itself.
///
/// **Only the tab the user has actually looked at starts loading** — see
/// [_TopicList.startLoading]'s doc comment for why. [TabBarView] builds all
/// three [_TopicList] widgets up front regardless (it's not lazy), so this
/// tracks which tabs have been visited via the shared [TabController] and
/// passes that down as a flag, rather than each [_TopicList] deciding for
/// itself when to start.
class _CatalogTabs extends StatefulWidget {
  final RouteCatalogService service;
  const _CatalogTabs({required this.service});

  @override
  State<_CatalogTabs> createState() => _CatalogTabsState();
}

class _CatalogTabsState extends State<_CatalogTabs> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Routes', icon: Icon(Icons.route)),
            Tab(text: 'Waypoints', icon: Icon(Icons.location_on)),
            Tab(text: 'Tracks', icon: Icon(Icons.timeline)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _TopicList(
                service: widget.service,
                topic: topicRoutes,
                icon: Icons.route,
                label: 'Route',
              ),
              _TopicList(
                service: widget.service,
                topic: topicWaypoints,
                icon: Icons.location_on,
                label: 'Waypoint',
              ),
              _TopicList(
                service: widget.service,
                topic: topicTrack,
                icon: Icons.timeline,
                label: 'Track',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One tab's contents: reads directly from [service]'s already-loaded
/// local copy of [topic]'s catalog — never fetches anything itself, and
/// stays live-updated via [service]'s own [ChangeNotifier] notifications
/// (fed by [RouteCatalogConnection.pushes] — see this file's own top doc
/// comment).
class _TopicList extends StatefulWidget {
  final RouteCatalogService service;
  final int topic;
  final IconData icon;
  final String label;

  const _TopicList({required this.service, required this.topic, required this.icon, required this.label});

  @override
  State<_TopicList> createState() => _TopicListState();
}

class _TopicListState extends State<_TopicList> with AutomaticKeepAliveClientMixin {
  final _busyUuids = <String>{};
  final _searchController = TextEditingController();
  String _query = '';

  /// Multi-select mode — entered via the "select" toolbar action, exited
  /// by clearing the selection or backing out explicitly. Kept separate
  /// from [_selectedUuids] being merely non-empty so an explicit "cancel
  /// selection" action can distinguish "user wants to pick entries" from
  /// "user just deselected the last one, but is still in selection mode".
  bool _selecting = false;
  final _selectedUuids = <String>{};
  bool _bulkDeleting = false;

  // No fetching happens per-tab anymore (see this class' own doc
  // comment), but TabBarView still disposes non-kept-alive tabs' State
  // when they scroll off-screen, which would otherwise drop
  // _selectedUuids/_selecting/_searchController's text on every tab
  // switch — kept alive so that in-progress selection/search state
  // survives switching tabs and back, same as before.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final catalog = switch (widget.topic) {
      final t when t == topicRoutes => widget.service.routes,
      final t when t == topicWaypoints => widget.service.waypoints,
      _ => widget.service.tracks,
    };
    final allObjects = catalog.all;
    if (allObjects.isEmpty) {
      return Center(child: Text('No ${widget.label.toLowerCase()}s found on the plotter.'));
    }
    final objects = _query.isEmpty
        ? allObjects
        : allObjects.where((o) => o.name.toLowerCase().contains(_query)).toList();
    return Column(
      children: [
        if (_selecting)
          _SelectionToolbar(
            selectedCount: _selectedUuids.length,
            totalCount: objects.length,
            allSelected: objects.isNotEmpty && objects.every((o) => _selectedUuids.contains(o.uuid)),
            busy: _bulkDeleting,
            onSelectAll: () => setState(() {
              if (objects.every((o) => _selectedUuids.contains(o.uuid))) {
                _selectedUuids.removeAll(objects.map((o) => o.uuid));
              } else {
                _selectedUuids.addAll(objects.map((o) => o.uuid));
              }
            }),
            onCancel: () => setState(() {
              _selecting = false;
              _selectedUuids.clear();
            }),
            onDeleteSelected: _selectedUuids.isEmpty ? null : () => _deleteSelected(allObjects),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search ${widget.label.toLowerCase()}s…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(icon: const Icon(Icons.clear), onPressed: _searchController.clear),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                if (allObjects.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Select ${widget.label.toLowerCase()}s to delete',
                    icon: const Icon(Icons.checklist),
                    onPressed: () => setState(() => _selecting = true),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: objects.isEmpty
              ? const Center(child: Text('No matches.'))
              : ListView.builder(
                  itemCount: objects.length,
                  itemBuilder: (context, i) {
                    final object = objects[i];
                    final busy = _busyUuids.contains(object.uuid);
                    final selected = _selectedUuids.contains(object.uuid);
                    return ListTile(
                      leading: _selecting
                          ? Checkbox(
                              value: selected,
                              onChanged: _bulkDeleting
                                  ? null
                                  : (_) => setState(() {
                                      if (selected) {
                                        _selectedUuids.remove(object.uuid);
                                      } else {
                                        _selectedUuids.add(object.uuid);
                                      }
                                    }),
                            )
                          : Icon(widget.icon),
                      title: Text(object.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_subtitleFor(object)),
                      onTap: _selecting && !_bulkDeleting
                          ? () => setState(() {
                              if (selected) {
                                _selectedUuids.remove(object.uuid);
                              } else {
                                _selectedUuids.add(object.uuid);
                              }
                            })
                          : null,
                      trailing: _selecting
                          ? null
                          : busy
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Save as .gpx',
                                  icon: const Icon(Icons.save_alt),
                                  onPressed: () => _handle(object, _saveEntry),
                                ),
                                IconButton(
                                  tooltip: 'Share as .gpx',
                                  icon: const Icon(Icons.share),
                                  onPressed: () => _handle(object, _shareEntry),
                                ),
                                IconButton(
                                  tooltip: 'Delete from plotter',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _deleteEntry(object),
                                ),
                              ],
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// [widget.label] plus, for multi-point objects (routes/tracks — a lone
  /// waypoint's single point has no length), the total distance along
  /// [object]'s points. The plotter's own object data has no length field
  /// of its own (checked — only name/uuid/points), so this is computed
  /// client-side from the coordinates rather than shown as some real
  /// device-reported value.
  String _subtitleFor(DownloadedObject object) {
    if (object.points.length < 2) return widget.label;
    final nm = _totalDistanceNm(object.points);
    return '${widget.label} · ${nm.toStringAsFixed(1)} nm';
  }

  Future<void> _handle(DownloadedObject object, Future<void> Function(BuildContext, DownloadedObject) action) async {
    setState(() => _busyUuids.add(object.uuid));
    try {
      await action(context, object);
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _busyUuids.remove(object.uuid));
    }
  }

  /// Confirms, then deletes [object] from the plotter's catalog via
  /// [RouteCatalogConnection.deleteEntry] — see that method's doc comment
  /// for the wire format. Passes [object.vstamp] — safe to do because
  /// [deleteEntry] only trusts a caller-supplied `vstamp` on its fast path
  /// (this connection already primed the topic once — see
  /// [RouteCatalogConnection]'s `_mergePrimedTopics` doc comment), which
  /// never re-syncs anyway; on the slower first-delete-on-this-connection
  /// path it still prefers its own fresh sync's vstamp over whatever's
  /// passed here. **This was a real bug once** (2026-08-10, before the
  /// fast path existed): back then a caller-supplied `vstamp` unconditionally
  /// won even on the syncing path, so a load-time value could go stale by
  /// the time a user actually clicked delete, silently breaking it — see
  /// [deleteEntry]'s own doc comment for the full story. Not an issue now
  /// that [deleteEntry] itself decides which vstamp source is safe to
  /// trust. The confirmation
  /// dialog says this can't be undone from within the app,
  /// since unlike save/share there's no way to reverse it here.
  Future<void> _deleteEntry(DownloadedObject object) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete from plotter?'),
        content: Text(
          'This permanently removes "${object.name}" from the plotter\'s catalog. '
          'This cannot be undone from within this app — make sure you have a backup '
          '(e.g. exported as .gpx) if you might want it back.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    setState(() => _busyUuids.add(object.uuid));
    try {
      // No manual local-list update needed here — RouteCatalogService.
      // deleteEntry updates its own local copy and notifies listeners,
      // which rebuilds this widget via the ListenableBuilder in build().
      await widget.service.deleteEntry(widget.topic, object.uuid, vstamp: object.vstamp);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted "${object.name}".')));
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
    } finally {
      if (mounted) setState(() => _busyUuids.remove(object.uuid));
    }
  }

  /// Deletes every currently-selected entry from [allObjects], one at a
  /// time. Sequential, not parallel — running deletes concurrently on one
  /// shared connection is untested and not something the real app is known
  /// to do (two real captures of it deleting several routes, one batched,
  /// one one-at-a-time, both showed strictly sequential deletes on a
  /// single reused connection — see [RouteCatalogConnection.deleteEntry]'s
  /// doc comment). Passes each object's own [DownloadedObject.vstamp] —
  /// safe here even across multiple deletes in one loop, since each
  /// object's `vstamp` only reflects *that object's* own version history,
  /// not the topic's shared `remote_ver` (which DOES need to chain between
  /// deletes, but [deleteEntry] handles that internally via its own
  /// per-connection cache, not something this loop needs to manage).
  /// Continues past individual
  /// failures rather than aborting the whole batch, and reports a summary
  /// at the end so a partial failure is visible rather than silently
  /// swallowed.
  Future<void> _deleteSelected(List<DownloadedObject> allObjects) async {
    final targets = allObjects.where((o) => _selectedUuids.contains(o.uuid)).toList();
    if (targets.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${targets.length} ${widget.label.toLowerCase()}${targets.length == 1 ? '' : 's'}?'),
        content: Text(
          'This permanently removes ${targets.length} ${widget.label.toLowerCase()}${targets.length == 1 ? '' : 's'} '
          'from the plotter\'s catalog. This cannot be undone from within this app — make sure you have a backup '
          '(e.g. exported as .gpx) if you might want any of them back.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    setState(() => _bulkDeleting = true);
    final deletedUuids = <String>{};
    final failures = <String, Object>{};
    for (final object in targets) {
      try {
        // No manual local-list update needed — see the single-delete
        // path's own comment above.
        await widget.service.deleteEntry(widget.topic, object.uuid, vstamp: object.vstamp);
        deletedUuids.add(object.uuid);
      } on Object catch (e) {
        failures[object.name] = e;
      }
      if (mounted) setState(() {}); // refresh progress-relevant UI (busy state, counts)
    }
    if (!mounted) return;

    setState(() {
      _bulkDeleting = false;
      _selecting = false;
      _selectedUuids.clear();
    });

    final message = failures.isEmpty
        ? 'Deleted ${deletedUuids.length} ${widget.label.toLowerCase()}${deletedUuids.length == 1 ? '' : 's'}.'
        : 'Deleted ${deletedUuids.length} of ${targets.length}; failed: ${failures.keys.join(', ')}.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The toolbar shown in place of the search field while [_TopicListState]
/// is in multi-select mode: a "select all/none" toggle, a running count,
/// and the bulk-delete action itself (disabled with nothing selected).
class _SelectionToolbar extends StatelessWidget {
  final int selectedCount;
  final int totalCount;
  final bool allSelected;
  final bool busy;
  final VoidCallback onSelectAll;
  final VoidCallback onCancel;
  final VoidCallback? onDeleteSelected;

  const _SelectionToolbar({
    required this.selectedCount,
    required this.totalCount,
    required this.allSelected,
    required this.busy,
    required this.onSelectAll,
    required this.onCancel,
    required this.onDeleteSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: allSelected ? 'Deselect all' : 'Select all',
            icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
            onPressed: busy || totalCount == 0 ? null : onSelectAll,
          ),
          Expanded(
            child: Text(
              busy ? 'Deleting…' : '$selectedCount selected',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            IconButton(
              tooltip: 'Delete selected',
              icon: const Icon(Icons.delete_outline),
              onPressed: onDeleteSelected,
            ),
            IconButton(tooltip: 'Cancel selection', icon: const Icon(Icons.close), onPressed: onCancel),
          ],
        ],
      ),
    );
  }
}

Future<void> _saveEntry(BuildContext context, DownloadedObject object) async {
  final gpx = buildGpxDocument(object.name, object.points);
  final fileName = '${_sanitizeFileName(object.name)}.gpx';
  final location = await getSaveLocation(suggestedName: fileName);
  if (location == null) return;
  final file = XFile.fromData(Uint8List.fromList(utf8.encode(gpx)), mimeType: 'application/gpx+xml', name: fileName);
  await file.saveTo(location.path);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved "${object.name}".')));
}

Future<void> _shareEntry(BuildContext context, DownloadedObject object) async {
  final gpx = buildGpxDocument(object.name, object.points);
  final fileName = '${_sanitizeFileName(object.name)}.gpx';
  final dir = await Directory.systemTemp.createTemp('remote_helm_gpx');
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(gpx);
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path, mimeType: 'application/gpx+xml', name: fileName)], fileNameOverrides: [fileName]),
  );
}

String _sanitizeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return cleaned.isEmpty ? 'route' : cleaned;
}

const double _earthRadiusNm = 3440.065; // mean Earth radius, in nautical miles

/// Total great-circle distance along consecutive [points], in nautical
/// miles — the sum of each leg's haversine distance. Not the plotter's own
/// value (it doesn't send one — see [_TopicListState._subtitleFor]); this
/// is a straight-line leg sum like a GPX viewer would compute, not
/// following any route-following/rhumb-line correction the plotter's own
/// UI might apply, so treat it as an estimate.
double _totalDistanceNm(List<RoutePoint> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += _haversineNm(points[i - 1], points[i]);
  }
  return total;
}

double _haversineNm(RoutePoint a, RoutePoint b) {
  final lat1 = a.lat * math.pi / 180;
  final lat2 = b.lat * math.pi / 180;
  final dLat = (b.lat - a.lat) * math.pi / 180;
  final dLon = (b.lon - a.lon) * math.pi / 180;
  final sinDLat = math.sin(dLat / 2);
  final sinDLon = math.sin(dLon / 2);
  final h = sinDLat * sinDLat + math.cos(lat1) * math.cos(lat2) * sinDLon * sinDLon;
  final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  return _earthRadiusNm * c;
}
