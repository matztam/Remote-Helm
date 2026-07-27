/// mDNS discovery of Garmin Helm services.
///
/// The ActiveCaptain app finds chartplotters by browsing the Bonjour/mDNS
/// service type `_garmin-helm._tcp.local`. Each plotter that offers the Helm
/// feature advertises a service record with its hostname, IPv4 address, TCP
/// port and TXT key/value pairs.
///
/// Ported from the Python reference implementation
/// (github.com/Mrkvak/helm-linux, `helm/discovery.py`), but built on the
/// official `multicast_dns` package instead of hand-rolled DNS parsing.
library;

import 'package:multicast_dns/multicast_dns.dart';

const String helmService = '_garmin-helm._tcp.local';

/// Other Garmin service types you may see on a boat network, for reference:
///   _garmin-mrn-cred._tcp   marine credential service (pairing)
///   _garmin-bl-id._tcp      BlueLink identity (on-board HTTP pairing server)
///   _garmin-bl-app._tcp     BlueLink app messaging bus
///   _garmin-mrn-html._tcp   on-device HTML/web UI
///   _garmin-marine._udp     general marine network announce
const List<String> garminServiceTypes = [
  helmService,
  '_garmin-mrn-cred._tcp.local',
  '_garmin-bl-id._tcp.local',
  '_garmin-bl-app._tcp.local',
  '_garmin-mrn-html._tcp.local',
  '_garmin-marine._udp.local',
];

/// A discovered Garmin service instance.
class HelmServiceInfo {
  /// Full instance name, e.g. `"GPSMAP 1243xsv._garmin-helm._tcp.local"`.
  final String instance;
  final String serviceType;

  /// Target hostname, e.g. `"gpsmap-1243.local"`.
  final String host;

  /// Resolved IPv4 address, if found.
  final String address;
  final int port;
  final Map<String, String> txt;

  const HelmServiceInfo({
    required this.instance,
    required this.serviceType,
    this.host = '',
    this.address = '',
    this.port = 0,
    this.txt = const {},
  });

  /// Human name (the instance label before the service type).
  String get name {
    final idx = instance.indexOf('._garmin');
    return idx < 0 ? instance : instance.substring(0, idx);
  }

  @override
  String toString() {
    final loc = '${address.isEmpty ? host : address}:$port';
    final extra = txt.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return '$name  [$loc]${extra.isEmpty ? '' : '  $extra'}';
  }
}

/// Browses the network for Garmin services. Defaults to just the Helm
/// service type; pass [garminServiceTypes] to see everything Garmin
/// advertises on the network.
Future<List<HelmServiceInfo>> browse({
  List<String> serviceTypes = const [helmService],
  Duration timeout = const Duration(seconds: 4),
}) async {
  final client = MDnsClient();
  await client.start();
  try {
    final found = <String, HelmServiceInfo>{};

    for (final serviceType in serviceTypes) {
      await for (final ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(serviceType),
            timeout: timeout,
          )
          .timeout(
            timeout,
            onTimeout: (sink) => sink.close(),
          )) {
        final instance = ptr.domainName;
        String host = '';
        int port = 0;
        await for (final srv in client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(instance),
              timeout: timeout,
            )
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          host = srv.target;
          port = srv.port;
          break; // first SRV record is sufficient
        }

        final txt = <String, String>{};
        await for (final txtRecord in client
            .lookup<TxtResourceRecord>(
              ResourceRecordQuery.text(instance),
              timeout: timeout,
            )
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          txt.addAll(_parseTxt(txtRecord.text));
          break;
        }

        var address = '';
        if (host.isNotEmpty) {
          await for (final a in client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(host),
                timeout: timeout,
              )
              .timeout(timeout, onTimeout: (sink) => sink.close())) {
            address = a.address.address;
            break;
          }
        }

        found[instance] = HelmServiceInfo(
          instance: instance,
          serviceType: serviceType.replaceAll('.local', ''),
          host: host,
          address: address,
          port: port,
          txt: txt,
        );
      }
    }

    return found.values.toList();
  } finally {
    client.stop();
  }
}

/// Parses `multicast_dns`'s raw TXT record text (newline-joined `key=value`
/// entries) into a map, mirroring `_parse_txt` in the Python client.
Map<String, String> _parseTxt(String rawText) {
  final out = <String, String>{};
  for (final line in rawText.split('\n')) {
    if (line.isEmpty) continue;
    final eq = line.indexOf('=');
    if (eq < 0) {
      out[line] = '';
    } else {
      out[line.substring(0, eq)] = line.substring(eq + 1);
    }
  }
  return out;
}
