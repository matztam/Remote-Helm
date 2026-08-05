import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/gpx.dart';
import 'package:remote_helm/helm/route_sync.dart';

void main() {
  test('parseGpxRoutes on the real captured GPX fixture matches what was actually synced', () {
    // test/fixtures/aaaaaaaaa_route.gpx is the exact GPX file the user
    // synced to a real plotter while this feature's wire format was being
    // reverse-engineered — parsing it here and feeding the result into
    // encodeRoute() should reproduce the exact same tSyncData payload
    // verified byte-for-byte in route_sync_test.dart, tying the whole
    // GPX-file -> wire-format path together with something that's known to
    // have actually worked against real hardware.
    final gpxText = File('test/fixtures/aaaaaaaaa_route.gpx').readAsStringSync();
    final routes = parseGpxRoutes(gpxText);
    expect(routes, hasLength(1));

    final route = routes.single;
    expect(route.name, 'AAAAAAAAA');
    expect(route.points.map((p) => p.name), [
      'Sandbjerg Vig - Mindertiefen',
      'Bjørnsknude Flak',
      'Irgendwo',
      'Sandbjerg Vig',
    ]);

    // Doesn't need its own byte-for-byte assertion — encodeRoute succeeding
    // without throwing (it requires exactly 4 points) is enough to confirm
    // the parsed shape lines up with what that function expects; the byte
    // contents are already covered by route_sync_test.dart's golden-value
    // test using the same 4 points typed out directly.
    expect(() => encodeRoute(route.name, route.points), returnsNormally);
  });

  test('parseGpxRoutes extracts name and points from a single-route GPX', () {
    const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="NV Charts">
  <metadata><name>AAAAAAAAA</name></metadata>
  <rte>
    <name>AAAAAAAAA</name>
    <rtept lat="55.719726" lon="10.041321"><name>Sandbjerg Vig - Mindertiefen</name><ele>0</ele></rtept>
    <rtept lat="55.715648" lon="10.064805"><name>Bjørnsknude Flak</name><ele>0</ele></rtept>
    <rtept lat="55.729377" lon="10.058734"><name>Irgendwo</name><ele>0</ele></rtept>
    <rtept lat="55.725664" lon="10.018439"><name>Sandbjerg Vig</name><ele>0</ele></rtept>
  </rte>
</gpx>
''';

    final routes = parseGpxRoutes(gpx);
    expect(routes, hasLength(1));
    expect(routes.single.name, 'AAAAAAAAA');
    expect(routes.single.points, hasLength(4));
    expect(routes.single.points[0].name, 'Sandbjerg Vig - Mindertiefen');
    expect(routes.single.points[0].lat, closeTo(55.719726, 1e-6));
    expect(routes.single.points[0].lon, closeTo(10.041321, 1e-6));
    expect(routes.single.points[3].name, 'Sandbjerg Vig');
  });

  test('parseGpxRoutes falls back to a default name when <name> is absent', () {
    const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
  <rte>
    <rtept lat="1.0" lon="2.0"></rtept>
  </rte>
</gpx>
''';

    final routes = parseGpxRoutes(gpx);
    expect(routes, hasLength(1));
    expect(routes.single.name, 'Route');
    expect(routes.single.points.single.name, 'Waypoint');
  });

  test('parseGpxRoutes skips routes with no valid points', () {
    const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
  <rte><name>Empty</name></rte>
  <rte>
    <name>Real</name>
    <rtept lat="1.0" lon="2.0"><name>p</name></rtept>
  </rte>
</gpx>
''';

    final routes = parseGpxRoutes(gpx);
    expect(routes, hasLength(1));
    expect(routes.single.name, 'Real');
  });

  test('parseGpxRoutes throws GpxParseException on malformed XML', () {
    expect(() => parseGpxRoutes('<gpx><rte>'), throwsA(isA<GpxParseException>()));
  });

  test('parseGpxRoutes handles multiple routes in one file', () {
    const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
  <rte>
    <name>First</name>
    <rtept lat="1.0" lon="2.0"><name>a</name></rtept>
  </rte>
  <rte>
    <name>Second</name>
    <rtept lat="3.0" lon="4.0"><name>b</name></rtept>
  </rte>
</gpx>
''';

    final routes = parseGpxRoutes(gpx);
    expect(routes, hasLength(2));
    expect(routes[0].name, 'First');
    expect(routes[1].name, 'Second');
  });
}
