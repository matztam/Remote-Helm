/// remote_helm command-line tool — verifies the Dart protocol layer against
/// a real plotter without needing the Flutter GUI.
///
/// Subcommands:
///   discover [--all] [--timeout SEC]         find Garmin services on the Wi-Fi
///   pair `<host>` [--port N] [--role R]      register this machine (prints
///                                             the identity JSON to save/reuse)
///   pair `<host>` --tag TAG --token N        re-request a role for an
///                                             already-registered identity
///   helm [--host IP] [--tap X Y]             open the Helm session, print
///                                             status, optionally send a test
///                                             tap, then print the RTSP URL
///
/// Run with `dart run bin/helm_cli.dart <subcommand> ...` from the project
/// root, or `dart bin/helm_cli.dart ...` once compiled.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:remote_helm/helm/credential.dart';
import 'package:remote_helm/helm/discovery.dart';
import 'package:remote_helm/helm/helm_client.dart';
import 'package:remote_helm/helm/route_catalog.dart';

Future<void> main(List<String> argv) async {
  if (argv.isEmpty) {
    _printUsage();
    exitCode = 2;
    return;
  }

  final cmd = argv.first;
  final rest = argv.skip(1).toList();
  switch (cmd) {
    case 'discover':
      exitCode = await _cmdDiscover(rest);
    case 'pair':
      exitCode = await _cmdPair(rest);
    case 'helm':
      exitCode = await _cmdHelm(rest);
    case 'catalog':
      exitCode = await _cmdCatalog(rest);
    case 'catalog-debug':
      exitCode = await _cmdCatalogDebug(rest);
    case 'catalog-replay':
      exitCode = await _cmdCatalogReplay(rest);
    default:
      stderr.writeln('Unknown subcommand: $cmd\n');
      _printUsage();
      exitCode = 2;
  }
}

void _printUsage() {
  stdout.writeln('''
Usage: dart run bin/helm_cli.dart <subcommand> [options]

Subcommands:
  discover [--all] [--timeout SEC]
      Find Garmin services on the Wi-Fi via mDNS. --all shows every Garmin
      service type, not just the Helm one.

  pair <host> [--port N] [--role guest|owner|dealer]
      Register this machine with the plotter's on-board bl-id HTTP service
      (default port 80). Prints the resulting identity as JSON — save it and
      pass --tag/--token next time to reuse the identity instead of
      registering a new "ActiveCaptain user" on every run.

  pair <host> --tag TAG --token N [--port N] [--role R]
      Re-request a role for an already-registered identity (skips
      re-registration).

  helm [--host IP] [--tap X Y]
      Open the Helm control session (mDNS-discovers the plotter if --host is
      omitted), print handshake/touch-context status and the RTSP video URL.
      --tap X Y sends one test tap at normalized [0,1] coordinates.

  catalog <host> [--topic routes|waypoints|both] [--fetch-objects]
      [--fetch-objects-limit N] [--fetch-objects-timeout SEC]
      Live-test fetchCatalog against a real plotter on port $routeCatalogPort.
      Prints every CatalogEntry found, or the RouteCatalogException on
      failure. Default --topic is both. --fetch-objects additionally calls
      fetchObjects (one batch tGetObject request) for every entry found and
      prints each decoded name + point count. --fetch-objects-limit caps how
      many of the found uuids are requested (start small — a single failed
      batch request has been observed to make the real plotter stop
      replying to ANY request for 15-20+ minutes afterward, so test with a
      handful of uuids before requesting a whole catalog). Default timeout
      is 30s; --fetch-objects-timeout overrides it.
''');
}

String? _optionValue(List<String> args, String name) {
  final idx = args.indexOf(name);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

bool _hasFlag(List<String> args, String name) => args.contains(name);

Future<int> _cmdDiscover(List<String> args) async {
  final all = _hasFlag(args, '--all');
  final timeoutSec = double.tryParse(_optionValue(args, '--timeout') ?? '') ?? 5.0;
  final types = all ? garminServiceTypes : const [helmService];
  final label = all ? 'all Garmin services' : 'Helm devices';
  stdout.writeln('Browsing for $label (~${timeoutSec.toStringAsFixed(0)}s)…');

  final results = await browse(
    serviceTypes: types,
    timeout: Duration(milliseconds: (timeoutSec * 1000).round()),
  );
  if (results.isEmpty) {
    stdout.writeln("Nothing found. Are you on the plotter's Wi-Fi network?");
    return 1;
  }
  for (final s in results) {
    stdout.writeln('\n  ${s.name}');
    stdout.writeln('      service : ${s.serviceType}');
    stdout.writeln('      address : ${s.address.isEmpty ? s.host : s.address}:${s.port}');
    for (final entry in s.txt.entries) {
      stdout.writeln('      txt     : ${entry.key}=${entry.value}');
    }
  }
  return 0;
}

Future<int> _cmdPair(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('pair requires a <host> argument (plotter IP or bl-id service IP).');
    return 2;
  }
  final host = positional.first;
  final port = int.tryParse(_optionValue(args, '--port') ?? '') ?? 80;
  final role = _optionValue(args, '--role') ?? 'guest';
  final tagArg = _optionValue(args, '--tag');
  final tokenArg = _optionValue(args, '--token');

  HelmIdentity? existing;
  if (tagArg != null && tokenArg != null) {
    existing = HelmIdentity(
      deviceIdentifier: '', // unused when reusing an identity (setRole only)
      clientGeneratedToken: int.parse(tokenArg),
      deviceName: 'remote_helm',
      tag: tagArg,
    );
  }

  stdout.writeln('Pairing with $host:$port (role=$role)…');
  final result = await pair(host, port, existingIdentity: existing, role: role);

  if (!result.ok) {
    stderr.writeln('Registration failed (HTTP ${result.registerStatus}).');
    return 1;
  }
  if (result.wasNewIdentity) {
    stdout.writeln('Registered new identity (HTTP ${result.registerStatus}).');
    stdout.writeln('Save this to reuse on the next run:');
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.identity.toJson()));
  } else {
    stdout.writeln('Reused existing identity (tag ${result.identity.tag}).');
  }
  stdout.writeln('set-role $role: HTTP ${result.setRoleStatus}');
  stdout.writeln(
    "\nOn the plotter, set App permissions to 'View and Control', then run:"
    '\n  dart run bin/helm_cli.dart helm --host $host',
  );
  return 0;
}

Future<int> _cmdHelm(List<String> args) async {
  var host = _optionValue(args, '--host');
  final tapIdx = args.indexOf('--tap');
  double? tx, ty;
  if (tapIdx >= 0 && tapIdx + 2 < args.length) {
    tx = double.tryParse(args[tapIdx + 1]);
    ty = double.tryParse(args[tapIdx + 2]);
  }

  if (host == null) {
    final svcs = await browse(timeout: const Duration(seconds: 5));
    if (svcs.isEmpty) {
      stdout.writeln("No Helm device found. Join the plotter's Wi-Fi.");
      return 1;
    }
    if (svcs.length > 1) {
      stdout.writeln('Multiple plotters found — pick one with --host <ip>:');
      for (final s in svcs) {
        stdout.writeln('  ${s.name}  ->  --host ${s.address.isEmpty ? s.host : s.address}');
      }
      return 1;
    }
    host = svcs.first.address.isEmpty ? svcs.first.host : svcs.first.address;
    stdout.writeln('Found ${svcs.first.name} at $host');
  }

  final client = HelmClient(host);
  stdout.writeln('Opening Helm session $host:${client.port} …');
  try {
    await client.connect();
  } on SocketException catch (e) {
    stderr.writeln('  session failed: $e\n  (paired? App-permission View and Control?)');
    return 1;
  }
  stdout.writeln(
    '  handshake ok; touch control: '
    '${client.touchCtx != null ? "enabled" : "NOT granted (check permission)"}',
  );
  stdout.writeln('  video: ${client.rtspUrl}');
  if (tx != null && ty != null) {
    await client.tap(tx, ty);
    stdout.writeln('  sent test tap at ($tx, $ty)');
  }
  client.close();
  return 0;
}

Future<int> _cmdCatalogDebug(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('catalog-debug requires a <host> argument (plotter IP).');
    return 2;
  }
  final host = positional.first;
  RouteCatalogConnection.debugTrace = true;

  // Hypotheses to try, in order, each on its own fresh connection (so one
  // rejected attempt closing the connection doesn't block the next try).
  // fieldA/fieldB/fieldC per this file's fetchCatalog doc comment: real
  // captures gave fieldA=27*N+intercept, fieldB=fieldA-10, fieldC=0x0102
  // always. N=100/topicRoutes real capture: fieldA=5319, fieldB=5309.
  final attempts = <(String, int, int, int)>[
    ('guessed N=0 (2619/2609/0x102) — same as fetchCatalog sends today', 2619, 2609, 0x0102),
  ];

  var anySucceeded = false;
  for (final (label, fieldA, fieldB, fieldC) in attempts) {
    stdout.writeln('\n--- Trying: $label (fieldA=$fieldA fieldB=$fieldB fieldC=0x${fieldC.toRadixString(16)}) ---');
    RouteCatalogConnection conn;
    try {
      conn = await RouteCatalogConnection.connect(host, timeout: const Duration(seconds: 6));
    } on SocketException catch (e) {
      stderr.writeln('  connection failed: $e');
      continue;
    }
    try {
      final replyBytes = await conn.debugSendRawCatalogSync(
        topicRoutes,
        fieldA: fieldA,
        fieldB: fieldB,
        fieldC: fieldC,
        timeout: const Duration(seconds: 8),
      );
      stdout.writeln('  SUCCESS: got a tCatalogSyncReply, ${replyBytes.length} bytes!');
      stdout.writeln('  first 80 bytes: ${replyBytes.take(80).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      anySucceeded = true;
    } on RouteCatalogException catch (e) {
      stderr.writeln('  no reply: $e');
    } finally {
      await conn.close();
    }
  }

  return anySucceeded ? 0 : 1;
}

Future<int> _cmdCatalog(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('catalog requires a <host> argument (plotter IP).');
    return 2;
  }
  final host = positional.first;
  RouteCatalogConnection.debugTrace = args.contains('--trace');
  if (args.contains('--sync-other-topics')) {
    RouteCatalogConnection.debugSyncOtherTopics = true;
  } else if (args.contains('--no-sync-other-topics')) {
    RouteCatalogConnection.debugSyncOtherTopics = false;
  } // else: leave the library default (false as of 2026-08-06) alone.
  final topicArg = _optionValue(args, '--topic') ?? 'both';
  final topics = switch (topicArg) {
    'routes' => [topicRoutes],
    'waypoints' => [topicWaypoints],
    'track' => [topicTrack],
    'both' => [topicWaypoints, topicRoutes],
    _ => throw ArgumentError('unknown --topic value: $topicArg'),
  };

  stdout.writeln('Connecting to $host:$routeCatalogPort …');
  final RouteCatalogConnection conn;
  try {
    conn = await RouteCatalogConnection.connect(host, timeout: const Duration(seconds: 6));
  } on SocketException catch (e) {
    stderr.writeln('  connection failed: $e');
    return 1;
  }

  final fetchObjects = args.contains('--fetch-objects');
  final fetchObjectsLimit = int.tryParse(_optionValue(args, '--fetch-objects-limit') ?? '');

  var ok = true;
  for (final topic in topics) {
    final name = topic == topicRoutes ? 'routes' : (topic == topicTrack ? 'track' : 'waypoints');
    if (!fetchObjects) {
      stdout.writeln('\nfetchCatalog($name) …');
      try {
        final entries = await conn.fetchCatalog(topic, timeout: const Duration(seconds: 15));
        stdout.writeln('  ${entries.length} entries:');
        for (final e in entries) {
          stdout.writeln('    ${e.uuid}');
        }
      } on RouteCatalogException catch (e) {
        stderr.writeln('  FAILED: $e');
        ok = false;
      }
      continue;
    }

    // fetchCatalogAndObjects, not a separate fetchCatalog()-then-
    // fetchObjects() pair: a live test found the plotter rejects the
    // batch tGetObject with an explicit error when it arrives as a
    // later, separate call after fetchCatalog already returned — see
    // fetchCatalogAndObjects' doc comment.
    final timeoutSec = int.tryParse(_optionValue(args, '--fetch-objects-timeout') ?? '') ?? 60;
    stdout.writeln('\nfetchCatalogAndObjects($name, limit=$fetchObjectsLimit, timeout=${timeoutSec}s) …');
    try {
      final objs = await conn.fetchCatalogAndObjects(
        topic,
        catalogTimeout: Duration(seconds: timeoutSec),
        objectsTimeout: Duration(seconds: timeoutSec),
        objectsLimit: fetchObjectsLimit,
      );
      stdout.writeln('  decoded ${objs.length} objects:');
      for (final obj in objs) {
        stdout.writeln('    ${obj.uuid} "${obj.name}" (${obj.points.length} points)');
      }
    } on RouteCatalogException catch (e) {
      stderr.writeln('  FAILED: $e');
      ok = false;
    }
  }

  await conn.close();
  return ok ? 0 : 1;
}

/// The real captured tCatalogSync `rest` payload (everything after
/// [topicId][msgType] on the wire, including its own 2-byte length field),
/// 101 records on topicRoutes — see route_catalog.dart's top doc comment for
/// where this came from. Used by [_cmdCatalogReplay] to test whether the
/// registration-timing fix alone is enough once the record content is
/// known-good, isolated from fetchCatalog's still-unconfirmed N=0 header
/// guess.
const _realCapturedCatalogSyncRest =
    'e214a74dd43208030000d814020149091c02071110295c176977eb4ed784a9f1f27a01f1940d'
    'f6a2f0e51302071110d394f591c50d4f13a497900940c3b2390df993c9d33902071110281032'
    '58ac2a4993821f4eb63755e49f0dedddeaef230207111093ad0de32681403c8bef42ef18c7c0'
    '270dde9fa2ea1e02071110637905a524e241e79a7d2ca7fa9c0e030db5879cf91602071110de'
    'd9fa4e040c4298b342e0f348e0162c0dfafcc2961202071110494f785bfdd942cbb7b0173dc7'
    'a4d0a50df1d7cfbc12020711101028ac246e104881b155a356af8b9dc70d8accc2e715020711'
    '107e0a90aca8b94b3892bd8fac2a8729520de68dbfd71802071110f523fc27f0014389bc8867'
    'f9d7e571740decedb6c01b020711107ac118680d6b445d9221bb8638d330100deea9bbfe1d02'
    '07111052bb0dce6d7f48a08f777b4acfa2f3af0de0d890a05602071110797009d3cf0a42acb2'
    '4bf425026529f50ddbe2e29e1802071110b438cb8670e541869ac162e4dadcf4270df4e6b8a4'
    '1802071110cf92160f5adc4be0abc97ccefc99f18b0ef2d1b0908001020711103efa8666957b'
    '4104a785364ac501ae2b0dcccae88b350207111095e6bfc4f09b462aa48a8d8c031600180db3'
    '9ca29c1702071110d39b68deadb943cdaae736b63600cf640df1bd93df1e020711102dc75431'
    '41d34fe8a367e423b9d85fea0ddf93ace81b020711103d87b2ce1fb6456a9f15375b4dbe2f42'
    '0dd2ddb1af190207111040838f86aa4842c8aaa9f698a287c0150df4e3a3b11702071110e425'
    'df9464124fc2ad4c94d34228bc940df5f79fbe1902071110cba07a871d57427686e8ac377efd'
    '5d750dfaf9c7ae1002071110d0eb31b387a248798d94363ba9b86c790eabc3c5de9201020711'
    '10de10b87dc644496e9745d51c38f589a70d90f2a4bf1802071110b540567e98564dfb84db81'
    '80d7793c970d8fa9e7ee54020711105994a0f74e03417eb7c3ba7efeb6ae240efba5e8bd9d01'
    '02071110e2af17cb27f34faf965eb5751620ca300da0acf9d42b020711106d62db81ad104369'
    '9bf4cd085b0266be0dbfedd6891c0207111012203525a10549e49b7c36cf71989c4a0dc2b8e4'
    'c0170207111052371392d70744baa24444c1b822ccb90df7a8a9941302071110378344478c7e'
    '4e7eb16f9d1c105ee6570d83bb8bf72f020711103e92885860c24b6d8d8d72f4ab64c9d40d94'
    '9aefc72802071110935626f18b62419993be42b91035d7fb0ddac483ba2b0207111054d30660'
    'bb554d8da6a0f72b5b80cfb50df9b9aaf82902071110cd26736112c94f2a93afb7e4a91a62e3'
    '0d81e5c1b13502071110274ab638aa714d9ba6846eef011bf6770d8eb6f6c61702071110247b'
    'a84fbb1f44d3b74451a7029763660d98e09da91c0207111083f9a8609f6a4966934ed00c9156'
    '5cd90edfecd599e70102071110624bf58538ca4826b73e6d812eb7819b0dd7daf5a610020711'
    '10f30a6f78f8b445c0b32c0ed06ef1be280efc9890cdc001020711100b8f586dc7c04649b0bc'
    '7163816a06fb0dd1be9dd33c020711102255281ddc0f471ebbdf6de0320405ae0efc9593f29b'
    '0302071110a3b974e8d7bd4042a6464514617897190e9ccea7a3ff010207111011a1c2ac0a48'
    '459ab8498cf77b436b5f0dc9c6b8e91902071110b3c46e4fb5ef43e7a2d21c49cf2bcb050e83'
    'dcbaf8840102071110885009ec71a14d918150c129da4504680d98c5f8a31c02071110c2996e'
    '1566404681a1631a4053bbff630de3d6ccc1120207111031ea56756ad749fa8dae6d5255d1a2'
    'a50dc6fdf9cd2d02071110dca866c3518348d7a0a2dbff3aca69260de9b890862f0207111064'
    'd6e8526a57426c973abbefd0f7b5080d97b9c0892a02071110c003fc2c678743c7b5c9ed01b9'
    '78c77a0d94c1fdd024020711100eabf27676e641958d41af162d8753d20dc2a1eccf3c020711'
    '10f429bcac59f9429888d70482f744cad60d94b094a72402071110d92c28eb8e834de4a4455f'
    '27166444bc0d9d96ebd72702071110b32a399bb8cd4a2ca595b23fc79bdc830ecca29a9fe808'
    '02071110c69223d9dbfa4661837e08a2cd0c1da60df3c093cb23020711101080e14d845f4567'
    'a49e5a559f657f100de2b78da03902071110746d31535e7a4604b68b9d1ceab244cf0db7a69c'
    'bf2302071110809df9ae48e5433ead43f080cee13e6f0de5dabaf32f0207111037a22a9afc18'
    '4df885e35f300ad0ad490dc4979d834f02071110d8b7e0b4faec49f2b778476f147d19420ec5'
    'efb2f2e30102071110a459b3b824214a4488a6657bdfb14b950de9dbbf863b020711101acef9'
    '9292204a658604e85fa6e4980c0ee1dfcbbdbb0202071110644e6b0544834b4faac03094577e'
    '67080ece9aa59cd20302071110bcce5f748f16481698dc89bc87c39ba90e94999cd686020207'
    '11100e54da7fc0014113a08ec7ac32314f520daab4ffb33302071110924df35e649c417db889'
    'ae48099239280dadacecaa2e0207111015f27d53d14a4261abbafd8334c1fa8a0dd3ead7d82b'
    '0207111046ee78f197054167884b75c87286ef440edbc2d1b2f602020711101f6e0eb62fc047'
    '21b4965f15c50890880dedeceff42102071110a662b53c16d64abd81386c84544100c40dfcde'
    'e1ec24020711103a2d29f0d5824ebf877aff9f503e52110ec2d787a9b001020711101201fd43'
    '97f2493c871f97984f03baeb0dcf9ba1966002071110bca4bae0310b4ac7a2aa69f4ad6682ff'
    '0da9a7ddc73f02071110fefcc77b52c54d2e88d275b185b7f9780dc0c893ea2d020711108582'
    'b01fc1844e0f979deab19f1e383a0dd2d6ddff26020711100c6c971a4ad84e33826eb7120947'
    'd2220d8e8cb7a72f0207111077670134068f4a11969b3c0f59f209be0ddec8c3a92c02071110'
    '087269d3b07244eaae6971d24081b5c90dbabe92e02b020711104ebc92c054ae4cb592dc90d6'
    '7f1b757a0d86888c85210207111067f736a2d02c4eaa95819edc91a9c8a30d9dab8cf92d0207'
    '1110da155bff6ff34731a0325e33fd13cc520ddfbff3ae3c02071110eca791a1acc84b0395ea'
    'cd7c48f587b40dac85adae3f02071110d7226181275c4d7b9f7ab23ec4c888920d8f9d87bd3d'
    '02071110058e9326d3cc4ca5908bee5a30b508650df0c680942e020711105c04a3e04b8a46de'
    '8c8ebee4131cf9520d93e783be2f0207111049740d6a8ecd48b0bd485ab889b30a7f0dcb8daa'
    'aa29020711103fc3fadfacd84be6b051cfb4aa4a520f0dedea8791220207111008879b4ce82d'
    '4b02b4de9bacc55de1770ddc9cdcfe2402071110cf852e64e7284a0b8d86e2aa2a5bac320dd3'
    'd582ed2c02071110c31e7944abf74d19b5fafe5929a350b30de9d4959f3d020711108ffadaed'
    'f1d24635989b97254299cd050de8a7b1ed4802071110ffc2f3a1c8f04d988f9a7742b7480f2e'
    '0ec5ff8ea0b00e0207111004c6d98dbc084d6288de5495254816260ed7f69cfdc20202071110'
    'fd4bca0c29944e84960f26dae0e6b9a90d9ea1c39f3e020711106a7798b57c694ff1a27d9f6e'
    'e5ab0f700ddade9cbd4202071110f1451b3924ae4f209e360102c3cd95670d8ab3afce330207'
    '11108ffc43c6788d46829b9ec53ee117dbdb0de3f7d7bf3802071110959ff271c2564243b0c5'
    '68eda3acb9250df3c0cc883b0207111025668afe032f492f85d96c198d6f1f1d0d81e78fbd3f';

Future<int> _cmdCatalogReplay(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('catalog-replay requires a <host> argument (plotter IP).');
    return 2;
  }
  final host = positional.first;
  RouteCatalogConnection.debugTrace = args.contains('--trace');

  final capturedBytes = Uint8List(_realCapturedCatalogSyncRest.length ~/ 2);
  for (var i = 0; i < capturedBytes.length; i++) {
    capturedBytes[i] = int.parse(_realCapturedCatalogSyncRest.substring(i * 2, i * 2 + 2), radix: 16);
  }
  stdout.writeln('Replaying a real captured tCatalogSync (${capturedBytes.length} bytes, 101 real UUID records) '
      'against $host:$routeCatalogPort, patching only the correlation id …');

  final RouteCatalogConnection conn;
  try {
    conn = await RouteCatalogConnection.connect(host, timeout: const Duration(seconds: 6));
  } on SocketException catch (e) {
    stderr.writeln('  connection failed: $e');
    return 1;
  }
  try {
    final reply = await conn.debugReplayRawCatalogSync(topicRoutes, capturedBytes, timeout: const Duration(seconds: 10));
    stdout.writeln('SUCCESS: got a tCatalogSyncReply, ${reply.length} bytes.');
    stdout.writeln('first 80 bytes: ${reply.take(80).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    return 0;
  } on RouteCatalogException catch (e) {
    stderr.writeln('FAILED: $e');
    return 1;
  } finally {
    await conn.close();
  }
}
