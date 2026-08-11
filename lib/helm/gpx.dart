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

/// Builds a minimal GPX 1.1 document containing a single `<rte>` (route) or
/// `<wpt>` (waypoint) — the export counterpart of [parseGpxRoutes], used to
/// save/share an object downloaded from the plotter (see
/// `route_catalog.dart`). [points] with exactly one entry and [isTrack]
/// false are written as a lone `<wpt>` rather than a one-point route, since
/// that's what every other GPX consumer (including ActiveCaptain's own
/// export) expects for a standalone waypoint.
String buildGpxDocument(String name, List<RoutePoint> points, {bool isTrack = false}) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="remote_helm" '
      'xmlns="http://www.topografix.com/GPX/1/1" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
      'http://www.topografix.com/GPX/1/1/gpx.xsd">',
    );

  if (!isTrack && points.length == 1) {
    final p = points.first;
    buffer.writeln('  <wpt lat="${p.lat}" lon="${p.lon}">');
    buffer.writeln('    <name>${_xmlEscape(name)}</name>');
    buffer.writeln('  </wpt>');
  } else {
    final tag = isTrack ? 'trk' : 'rte';
    final ptTag = isTrack ? 'trkpt' : 'rtept';
    buffer.writeln('  <$tag>');
    buffer.writeln('    <name>${_xmlEscape(name)}</name>');
    if (isTrack) buffer.writeln('    <trkseg>');
    for (final p in points) {
      final indent = isTrack ? '      ' : '    ';
      buffer.writeln('$indent<$ptTag lat="${p.lat}" lon="${p.lon}">');
      if (p.name.isNotEmpty) buffer.writeln('$indent  <name>${_xmlEscape(p.name)}</name>');
      buffer.writeln('$indent</$ptTag>');
    }
    if (isTrack) buffer.writeln('    </trkseg>');
    buffer.writeln('  </$tag>');
  }

  buffer.writeln('</gpx>');
  return buffer.toString();
}

String _xmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
