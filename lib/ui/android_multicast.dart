/// Flutter-side WifiManager MulticastLock handling for [browse]'s
/// `withMulticastLock` parameter (see `helm/discovery.dart` for why this
/// isn't imported directly from there — it needs to stay pure Dart).
library;

import 'package:flutter_multicast_lock/flutter_multicast_lock.dart';

/// Acquires the Android multicast lock, runs [body], and releases the lock
/// afterwards. A no-op passthrough on non-Android platforms (the underlying
/// plugin already handles that; see its method channel implementation).
Future<T> withAndroidMulticastLock<T>(Future<T> Function() body) async {
  final lock = FlutterMulticastLock();
  await lock.acquireMulticastLock();
  try {
    return await body();
  } finally {
    await lock.releaseMulticastLock();
  }
}
