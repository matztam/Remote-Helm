/// Minimal GPX 1.1 route parsing — just enough to extract `<rte>` elements
/// (name + ordered `<rtept>` points) for [syncRoute] (`route_sync.dart`).
///
/// Deliberately narrow: this reads routes only, not waypoints (`<wpt>`) or
/// tracks (`<trk>`) at the top level, since [syncRoute] only knows how to
/// push a single route. A GPX file with multiple `<rte>` elements yields
/// multiple [GpxRoute]s; the caller picks which one(s) to sync.
library;

import 'package:xml/xml.dart';

import 'route_sync.dart';

/// One `<rte>` from a GPX file: its `<name>` (or a fallback if absent) and
/// ordered points, already in the shape [syncRoute] needs.
class GpxRoute {
  final String name;
  final List<RoutePoint> points;
  const GpxRoute({required this.name, required this.points});
}

class GpxParseException implements Exception {
  final String message;
  const GpxParseException(this.message);
  @override
  String toString() => 'GPX parse error: $message';
}

/// Parses every `<rte>` element in [gpxXml] (a full GPX document as text).
/// Routes with zero points are skipped (nothing meaningful to sync).
/// Throws [GpxParseException] if [gpxXml] isn't well-formed XML at all;
/// individual malformed points (missing/unparseable `lat`/`lon`) are
/// skipped rather than failing the whole parse, since a single bad point
/// in an otherwise-fine file shouldn't block importing the rest.
List<GpxRoute> parseGpxRoutes(String gpxXml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(gpxXml);
  } on XmlException catch (e) {
    throw GpxParseException(e.message);
  }

  final routes = <GpxRoute>[];
  for (final rte in doc.findAllElements('rte')) {
    final points = <RoutePoint>[];
    for (final rtept in rte.findElements('rtept')) {
      final lat = double.tryParse(rtept.getAttribute('lat') ?? '');
      final lon = double.tryParse(rtept.getAttribute('lon') ?? '');
      if (lat == null || lon == null) continue;
      final name = rtept.findElements('name').firstOrNull?.innerText.trim();
      points.add(RoutePoint(name: name?.isNotEmpty == true ? name! : 'Waypoint', lat: lat, lon: lon));
    }
    if (points.isEmpty) continue;
    final routeName = rte.findElements('name').firstOrNull?.innerText.trim();
    routes.add(GpxRoute(name: routeName?.isNotEmpty == true ? routeName! : 'Route', points: points));
  }
  return routes;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
