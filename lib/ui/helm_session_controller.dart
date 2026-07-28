/// Owns the HelmClient connection lifecycle and exposes it as a
/// ChangeNotifier so widgets can react to connect/disconnect/status changes
/// without each screen re-implementing discovery + connect + persistence.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helm/discovery.dart';
import '../helm/helm_client.dart';
import 'android_multicast.dart';

enum HelmSessionState { idle, discovering, connecting, connected, error }

class HelmSessionController extends ChangeNotifier {
  static const _lastHostKey = 'remote_helm.last_host';

  HelmClient? _client;
  HelmSessionState _state = HelmSessionState.idle;
  String? _lastHost;
  String? _statusMessage;

  HelmSessionState get state => _state;
  String? get statusMessage => _statusMessage;
  HelmClient? get client => _client;
  bool get isConnected => _state == HelmSessionState.connected;
  bool get hasTouchControl => _client?.touchCtx != null;

  Future<void> loadLastHost() async {
    final prefs = await SharedPreferences.getInstance();
    _lastHost = prefs.getString(_lastHostKey);
    notifyListeners();
  }

  String? get lastHost => _lastHost;

  Future<void> _saveLastHost(String host) async {
    _lastHost = host;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastHostKey, host);
  }

  void _setState(HelmSessionState s, {String? message}) {
    _state = s;
    _statusMessage = message;
    notifyListeners();
  }

  /// Browses mDNS for a Helm device. Returns the found services (empty if
  /// none within [timeout]); does not connect.
  Future<List<HelmServiceInfo>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _setState(HelmSessionState.discovering, message: 'Searching for plotters…');
    try {
      final results = await browse(
        timeout: timeout,
        withMulticastLock: withAndroidMulticastLock,
      );
      _setState(
        _state == HelmSessionState.discovering ? HelmSessionState.idle : _state,
      );
      return results;
    } catch (e) {
      _setState(HelmSessionState.error, message: 'Discovery failed: $e');
      return const [];
    }
  }

  Future<void> connect(String host) async {
    _setState(HelmSessionState.connecting, message: 'Connecting to $host…');
    _client?.close();
    final client = HelmClient(host);
    try {
      await client.connect();
    } on Object catch (e) {
      _setState(
        HelmSessionState.error,
        message: 'Session error: $e — paired and permission set to '
            '"View and Control"?',
      );
      return;
    }
    _client = client;
    await _saveLastHost(host);
    if (client.touchCtx == null) {
      _setState(
        HelmSessionState.connected,
        message: 'Connected but NO touch context — control disabled '
            '(check the plotter\'s App-permission).',
      );
    } else {
      _setState(HelmSessionState.connected, message: 'Connected to $host.');
    }
  }

  void disconnect() {
    _client?.close();
    _client = null;
    _setState(HelmSessionState.idle, message: 'Disconnected.');
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}
