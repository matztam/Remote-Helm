/// A dialog listing every route/waypoint/track on the connected plotter,
/// in three tabs, letting the user pick one to save (as a `.gpx` file) or
/// share (via the platform share sheet).
///
/// **Fetches each topic's real objects in one batch call per topic**
/// ([RouteCatalogConnection.fetchCatalog] then [RouteCatalogConnection.
/// fetchObjects]), not lazily per row. An earlier version of this dialog
/// fetched lazily (one [RouteCatalogConnection.fetchObject] call per row,
/// as it scrolled into view) after batch-downloading everything up front
/// repeatedly tripped the real plotter's protective lockout — but that
/// turned out to be caused by two separate, now-fixed bugs, not by
/// batching itself:
///
/// 1. **The catalog can list more raw entries than are real, individually
///    fetchable objects** — [RouteCatalogConnection.fetchCatalog] used to
///    return every raw record it found, but the plotter's own sync reply
///    carries a "real object count" field this library now decodes and
///    trims to (see `route_catalog.dart`'s [RouteCatalogConnection._syncCatalog]
///    doc comment). Asking for one of the non-real entries got no reply at
///    all from the plotter, which is what actually caused the lockouts —
///    not the batch size.
/// 2. **Client-side chunking of large batches was itself broken** — it used
///    to split >100-uuid requests into multiple sequential batch calls,
///    but the real app never does that (it always sends every uuid it
///    wants in one request), and the chunking's own re-sync step got no
///    reply, live, every time. Chunking has been removed.
///
/// With both fixed, a single [RouteCatalogConnection.fetchCatalog] +
/// [RouteCatalogConnection.fetchObjects] pair per topic is exactly what
/// the real app does, and has been confirmed live to reliably fetch the
/// plotter's entire real routes catalog (75, then 74 after a live
/// deletion), full waypoints catalog (118), and the saved track (5000
/// points) — see the memory system's `plotter-timeout-lockout` note for
/// the full investigation trail.
///
/// **Each tab loads independently** (its own connection-shared
/// [RouteCatalogConnection], its own [FutureBuilder] chain) so a slow or
/// failing topic doesn't block the others — switching to the Waypoints tab
/// while Routes is still loading works. [RouteCatalogConnection.
/// fetchObjects] itself decodes the batch reply (gzip inflate + JSON parse
/// + point-building for every object) on a background isolate, not this
/// widget's own event loop — live-observed necessary: decoding the
/// track's single ~367KB/5000-point object synchronously took long enough
/// that the OS flagged the whole app as "not responding".
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

/// Shows the catalog browser dialog for [host]. Fire-and-forget from the
/// caller's perspective — all success/error feedback happens via
/// [ScaffoldMessenger] inside the dialog itself.
Future<void> showRouteCatalogDialog(BuildContext context, String host) {
  return showDialog<void>(
    context: context,
    builder: (context) => RouteCatalogDialog(host: host),
  );
}

class RouteCatalogDialog extends StatefulWidget {
  final String host;
  const RouteCatalogDialog({super.key, required this.host});

  @override
  State<RouteCatalogDialog> createState() => _RouteCatalogDialogState();
}

class _RouteCatalogDialogState extends State<RouteCatalogDialog> {
  Future<RouteCatalogConnection>? _connFuture;

  /// Serializes every tab's load onto this one queue, so only one topic is
  /// ever being fetched at a time on the shared connection — all three
  /// tabs start loading as soon as the dialog opens (not just the visible
  /// one), but each [_TopicList.load] call chains onto whatever the
  /// previous one left here instead of running concurrently. Live testing
  /// this session found the underlying protocol doesn't handle concurrent
  /// requests on one connection well even across different topics — see
  /// `route_catalog.dart`'s `_syncInFlightByTopic`/`_getObjectQueueByTopic`
  /// doc comments for the same lesson learned the hard way for
  /// single-object fetches; this is the same idea one level up, for the
  /// catalog+batch-fetch pair each tab runs.
  Future<void> _loadQueue = Future<void>.value();

  /// Runs [load] only after every earlier-queued tab's own load has
  /// finished (successfully or not) — see [_loadQueue]'s doc comment.
  Future<T> _enqueueLoad<T>(Future<T> Function() load) {
    final previous = _loadQueue;
    final result = previous.then((_) => load());
    _loadQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  void initState() {
    super.initState();
    _connFuture = RouteCatalogConnection.connect(widget.host);
  }

  @override
  void dispose() {
    _connFuture?.then((c) => c.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Plotter routes, waypoints & tracks'),
      content: SizedBox(
        width: 420,
        height: 460,
        child: FutureBuilder<RouteCatalogConnection>(
          future: _connFuture,
          builder: (context, connSnapshot) {
            if (connSnapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (connSnapshot.hasError) {
              return Center(child: Text('Could not connect: ${connSnapshot.error}'));
            }
            return _CatalogTabs(conn: connSnapshot.data!, enqueueLoad: _enqueueLoad);
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
  final RouteCatalogConnection conn;
  final Future<T> Function<T>(Future<T> Function() load) enqueueLoad;
  const _CatalogTabs({required this.conn, required this.enqueueLoad});

  @override
  State<_CatalogTabs> createState() => _CatalogTabsState();
}

class _CatalogTabsState extends State<_CatalogTabs> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _visited = {0}; // tab 0 (Routes) is visible from the start

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      // .index changes as soon as a swipe/tap lands on a new tab, ahead of
      // the switch animation finishing — good enough to start that tab's
      // own load a little early rather than waiting for the animation.
      if (_visited.add(_tabController.index)) setState(() {});
    });
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
                conn: widget.conn,
                topic: topicRoutes,
                icon: Icons.route,
                label: 'Route',
                enqueueLoad: widget.enqueueLoad,
                startLoading: _visited.contains(0),
              ),
              _TopicList(
                conn: widget.conn,
                topic: topicWaypoints,
                icon: Icons.location_on,
                label: 'Waypoint',
                enqueueLoad: widget.enqueueLoad,
                startLoading: _visited.contains(1),
              ),
              _TopicList(
                conn: widget.conn,
                topic: topicTrack,
                icon: Icons.timeline,
                label: 'Track',
                enqueueLoad: widget.enqueueLoad,
                startLoading: _visited.contains(2),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One tab's contents: loads [topic]'s catalog, then its objects, showing
/// real load progress at each stage rather than just a spinner throughout.
class _TopicList extends StatefulWidget {
  final RouteCatalogConnection conn;
  final int topic;
  final IconData icon;
  final String label;
  final Future<T> Function<T>(Future<T> Function() load) enqueueLoad;

  /// Whether this tab should have started loading yet — `false` for a tab
  /// the user hasn't looked at. Found live 2026-08-07: all three tabs used
  /// to call [RouteCatalogConnection.fetchCatalog] as soon as the dialog
  /// opened, all sharing one queue (see [_RouteCatalogDialogState.
  /// _loadQueue]) so only one topic is ever mid-fetch at a time — but that
  /// meant the *visible* tab could be stuck showing "Connecting…" for as
  /// long as whichever other, invisible tab happened to be ahead of it in
  /// the queue, which is confusing (it's not actually still connecting,
  /// just waiting its turn behind something the user isn't even looking
  /// at). Now only the tab(s) the user has actually visited start loading
  /// at all — see [_CatalogTabsState._visited].
  final bool startLoading;

  const _TopicList({
    required this.conn,
    required this.topic,
    required this.icon,
    required this.label,
    required this.enqueueLoad,
    required this.startLoading,
  });

  @override
  State<_TopicList> createState() => _TopicListState();
}

/// What stage this tab's load is at, for the progress UI — see
/// [_TopicListState._load].
sealed class _LoadState {
  const _LoadState();
}

class _Loading extends _LoadState {
  /// `null` until the catalog sync itself has returned, so the UI can show
  /// "connecting…" first, then "N found, loading…" once a real count is
  /// known.
  final int? total;
  const _Loading(this.total);
}

class _Loaded extends _LoadState {
  final List<DownloadedObject> objects;
  const _Loaded(this.objects);
}

class _Failed extends _LoadState {
  final Object error;
  const _Failed(this.error);
}

class _TopicListState extends State<_TopicList> with AutomaticKeepAliveClientMixin {
  _LoadState _state = const _Loading(null);
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

  // Without this, TabBarView disposes each tab's State (and its cached
  // _state/_busyUuids) as soon as it scrolls off-screen, so switching back
  // to an already-loaded tab re-ran initState -> _load() and re-fetched
  // from the plotter every time — reported live 2026-08-07. Keeping this
  // tab's State alive for the dialog's lifetime, not just while visible,
  // fixes that: _load() only ever runs once per tab per dialog open.
  @override
  bool get wantKeepAlive => true;

  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (widget.startLoading) _startLoad();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void didUpdateWidget(_TopicList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Starts the load the moment this tab is actually visited (see
    // [_TopicList.startLoading]'s doc comment) — [_CatalogTabsState]
    // flips this true and rebuilds once the user switches to this tab.
    if (widget.startLoading && !_started) _startLoad();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _startLoad() {
    _started = true;
    _load();
  }

  Future<void> _load() async {
    try {
      // Queued (see [_RouteCatalogDialogState._loadQueue]'s doc comment):
      // every visited tab's load shares this one queue, so only one topic
      // is ever mid-fetch on the shared connection at a time. This
      // tab's own [setState] calls for its two load stages still happen
      // as soon as each network step actually completes, so its progress
      // text updates live even while queued behind another tab — only the
      // network calls themselves are serialized, not this widget's UI.
      final objects = await widget.enqueueLoad(() async {
        final entries = await widget.conn.fetchCatalog(widget.topic);
        if (mounted) setState(() => _state = _Loading(entries.length));
        if (entries.isEmpty) return const <DownloadedObject>[];
        return widget.conn.fetchObjects(widget.topic, entries.map((e) => e.uuid).toList());
      });
      if (!mounted) return;
      setState(() => _state = _Loaded(objects));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _state = _Failed(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final state = _state;
    if (state is _Loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            // By the time a _TopicList exists at all, the TCP connection
            // itself is already up (see _RouteCatalogDialogState.build's
            // own FutureBuilder around _connFuture, which gates whether
            // _CatalogTabs — and so any _TopicList — gets built in the
            // first place). So state.total == null here always means the
            // catalog sync (tCatalogSync, gated behind the protocol's own
            // ~10s preamble) is in flight, never that the socket itself is
            // still connecting — "Connecting…" was misleading about which
            // of those two (very different-feeling) waits was happening.
            Text(state.total == null ? 'Syncing catalog…' : 'Loading ${state.total} ${widget.label.toLowerCase()}s…'),
          ],
        ),
      );
    }
    if (state is _Failed) {
      return Center(child: Text('Could not load ${widget.label.toLowerCase()}s: ${state.error}'));
    }
    final allObjects = (state as _Loaded).objects;
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
                      title: Text(object.name),
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
      await widget.conn.deleteEntry(widget.topic, object.uuid, vstamp: object.vstamp);
      if (!mounted) return;
      final current = _state;
      if (current is _Loaded) {
        setState(() => _state = _Loaded(current.objects.where((o) => o.uuid != object.uuid).toList()));
      }
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
        await widget.conn.deleteEntry(widget.topic, object.uuid, vstamp: object.vstamp);
        deletedUuids.add(object.uuid);
      } on Object catch (e) {
        failures[object.name] = e;
      }
      if (mounted) setState(() {}); // refresh progress-relevant UI (busy state, counts)
    }
    if (!mounted) return;

    final current = _state;
    if (current is _Loaded) {
      setState(() => _state = _Loaded(current.objects.where((o) => !deletedUuids.contains(o.uuid)).toList()));
    }
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
