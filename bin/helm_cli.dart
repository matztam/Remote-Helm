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

import 'package:remote_helm/helm/credential.dart';
import 'package:remote_helm/helm/discovery.dart';
import 'package:remote_helm/helm/helm_client.dart';

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
