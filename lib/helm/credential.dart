/// Pairing: register this machine with the plotter.
///
/// The plotter runs an on-board HTTP server (advertised as
/// `_garmin-bl-id._tcp` on port 80). Pairing is:
///
///   1. Discover the service.
///   2. `PUT /garmin/bl-ids/<tag>` with a protobuf `MobileDeviceIdentity`
///      `{device_identifier, client_generated_token, device_name}`. `<tag>` =
///      `base64(client_generated_token[4B LE] + 02 01 00 00)`. The plotter
///      returns 202 and shows "a new ActiveCaptain user was added" on screen.
///   3. `PUT /garmin/bl-ids/<tag>/set-role`  JSON `{"role": "guest"|"owner"|"dealer"}`.
///   4. On the plotter, set the global App-permission to "View and Control".
///
/// The identity should be persisted by the caller (see [HelmIdentity.toJson]/
/// [HelmIdentity.fromJson]) and reused so pairing doesn't create a new
/// "ActiveCaptain user" on the plotter every run. Once paired, connect with
/// [HelmClient] — the Helm session on :51200 is authorized by the registered
/// identity, no token needed at that layer.
///
/// Ported from the Python reference implementation
/// (github.com/Mrkvak/helm-linux, `helm/credential.py`).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'discovery.dart';

const String credentialService = '_garmin-mrn-cred._tcp.local';
const String blIdService = '_garmin-bl-id._tcp.local';

/// A registered device identity (persisted by the caller across runs).
class HelmIdentity {
  final String deviceIdentifier;
  final int clientGeneratedToken;
  final String deviceName;
  final String tag;

  const HelmIdentity({
    required this.deviceIdentifier,
    required this.clientGeneratedToken,
    required this.deviceName,
    required this.tag,
  });

  /// Creates a fresh identity. `tag = base64(token[4 LE] + 02 01 00 00)`.
  factory HelmIdentity.create({String name = 'remote_helm'}) {
    final token = Random().nextInt(0x100000000);
    final tagBytes = Uint8List(8);
    ByteData.view(tagBytes.buffer).setUint32(0, token, Endian.little);
    tagBytes[4] = 0x02;
    tagBytes[5] = 0x01;
    tagBytes[6] = 0x00;
    tagBytes[7] = 0x00;
    final tag = base64.encode(tagBytes).replaceAll('=', '');
    return HelmIdentity(
      deviceIdentifier: _uuidV4(),
      clientGeneratedToken: token,
      deviceName: name,
      tag: tag,
    );
  }

  factory HelmIdentity.fromJson(Map<String, dynamic> json) => HelmIdentity(
    deviceIdentifier: json['device_identifier'] as String,
    clientGeneratedToken: json['client_generated_token'] as int,
    deviceName: json['device_name'] as String,
    tag: json['tag'] as String,
  );

  Map<String, dynamic> toJson() => {
    'device_identifier': deviceIdentifier,
    'client_generated_token': clientGeneratedToken,
    'device_name': deviceName,
    'tag': tag,
  };
}

String _uuidV4() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10xx
  String hex(int start, int len) =>
      bytes.sublist(start, start + len).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 2)}-${hex(6, 2)}-${hex(8, 2)}-${hex(10, 6)}';
}

// --- minimal protobuf wire encoding (no runtime dependency, matches the
// Python reference's hand-rolled encoder for these two field types) --------

Uint8List _varint(int n) {
  final out = <int>[];
  var v = n;
  while (true) {
    final b = v & 0x7F;
    v >>= 7;
    out.add(v != 0 ? (b | 0x80) : b);
    if (v == 0) break;
  }
  return Uint8List.fromList(out);
}

List<int> _pbString(int field, String s) {
  final b = utf8.encode(s);
  return [field << 3 | 2, ..._varint(b.length), ...b];
}

List<int> _pbUint32(int field, int n) {
  return [field << 3 | 0, ..._varint(n & 0xFFFFFFFF)];
}

/// Encodes `CSM.Proto.Common.MobileDeviceIdentity`:
/// `required string device_identifier = 1;`
/// `required uint32 client_generated_token = 2;`
/// `optional string device_name = 3;`
Uint8List encodeMobileDeviceIdentity(
  String deviceIdentifier,
  int clientGeneratedToken,
  String deviceName,
) {
  return Uint8List.fromList([
    ..._pbString(1, deviceIdentifier),
    ..._pbUint32(2, clientGeneratedToken),
    ..._pbString(3, deviceName),
  ]);
}

/// Finds the plotter's on-board HTTP identity service. Advertised as
/// `_garmin-bl-id._tcp` (port 80; TXT: tag, hasDisplay, version), which hosts
/// `/garmin/bl-ids/` used for pairing. (`_garmin-mrn-cred._tcp` is the same
/// service on some units.)
Future<HelmServiceInfo?> discoverCredentialService({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final svcs = await browse(
    serviceTypes: const [credentialService, blIdService],
    timeout: timeout,
  );
  svcs.sort((a, b) {
    final aCred = a.serviceType.contains('cred') ? 0 : 1;
    final bCred = b.serviceType.contains('cred') ? 0 : 1;
    return aCred.compareTo(bCred);
  });
  return svcs.isEmpty ? null : svcs.first;
}

/// HTTP client for the plotter's on-board identity service (bl-ids).
class CredentialClient {
  final String baseUrl;
  final Duration timeout;
  final http.Client _http;

  CredentialClient(String host, int port, {this.timeout = const Duration(seconds: 8), http.Client? client})
    : baseUrl = 'http://$host:$port',
      _http = client ?? http.Client();

  /// `PUT /garmin/bl-ids/<tag>` with a protobuf `MobileDeviceIdentity`.
  /// Returns 202 on success; the plotter shows "a new ActiveCaptain user was
  /// added".
  Future<http.Response> registerBlId(HelmIdentity ident) {
    final body = encodeMobileDeviceIdentity(
      ident.deviceIdentifier,
      ident.clientGeneratedToken,
      ident.deviceName,
    );
    return _http
        .put(
          Uri.parse('$baseUrl/garmin/bl-ids/${ident.tag}'),
          headers: {'Content-Type': 'application/octet-stream'},
          body: body,
        )
        .timeout(timeout);
  }

  /// `PUT /garmin/bl-ids/<tag>/set-role`  JSON `{"role": ...}`.
  Future<http.Response> setRole(String tag, {String role = 'guest'}) {
    return _http
        .put(
          Uri.parse('$baseUrl/garmin/bl-ids/$tag/set-role'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'role': role}),
        )
        .timeout(timeout);
  }

  void close() => _http.close();
}

/// Result of [pair]: whether a new identity was created (vs. reusing a
/// previously-saved one) and the final identity/role HTTP status codes.
class PairResult {
  final HelmIdentity identity;
  final bool wasNewIdentity;
  final int? registerStatus;
  final int? setRoleStatus;

  const PairResult({
    required this.identity,
    required this.wasNewIdentity,
    required this.registerStatus,
    required this.setRoleStatus,
  });

  bool get ok => wasNewIdentity ? (registerStatus != null && registerStatus! < 300) : true;
}

/// Registers this machine with the plotter (once; pass a previously-saved
/// [existingIdentity] to reuse it and skip re-registration) and requests a
/// role. After this succeeds, the plotter's global App-permission must be
/// set to "View and Control" on-device before a Helm session will grant
/// touch control.
Future<PairResult> pair(
  String host,
  int port, {
  HelmIdentity? existingIdentity,
  String deviceName = 'remote_helm',
  String role = 'guest',
}) async {
  final client = CredentialClient(host, port);
  try {
    if (existingIdentity != null) {
      final st = await client.setRole(existingIdentity.tag, role: role);
      return PairResult(
        identity: existingIdentity,
        wasNewIdentity: false,
        registerStatus: null,
        setRoleStatus: st.statusCode,
      );
    }

    final ident = HelmIdentity.create(name: deviceName);
    final registerResp = await client.registerBlId(ident);
    if (registerResp.statusCode >= 300) {
      return PairResult(
        identity: ident,
        wasNewIdentity: true,
        registerStatus: registerResp.statusCode,
        setRoleStatus: null,
      );
    }
    final roleResp = await client.setRole(ident.tag, role: role);
    return PairResult(
      identity: ident,
      wasNewIdentity: true,
      registerStatus: registerResp.statusCode,
      setRoleStatus: roleResp.statusCode,
    );
  } finally {
    client.close();
  }
}
