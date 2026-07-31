/// Platform-specific window/chrome handling.
///
/// - Android: fullscreen (immersive, hiding system bars) is the default —
///   the point of running this on a tablet is to give the plotter video the
///   whole screen. A screen-edge swipe still temporarily reveals system UI
///   (immersiveSticky), and the app can be told to reveal/hide it (e.g. to
///   show connect controls).
/// - Windows/Linux: a normal resizable window with visible controls, since
///   desktop use is meant to coexist with other windows. Fullscreen is an
///   explicit opt-in toggle (F11-style), not the default.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

bool get isDesktopPlatform => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// Must be called once, early in `main()`, before `runApp`.
Future<void> initializePlatformLayout() async {
  if (isDesktopPlatform) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1100, 700),
      minimumSize: Size(480, 320),
      center: true,
      title: 'Remote Helm',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // Windows gets its window/taskbar icon from the compiled .ico resource
    // (see windows/runner/resources/app_icon.ico) automatically; only
    // Linux (GTK) needs it set explicitly at runtime like this.
    if (Platform.isLinux) {
      await windowManager.setIcon('assets/icon/app_icon.png');
    }
  } else if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Landscape isn't forced (the plotter's video works either way with
    // letterboxing), but most plotter screens are wide, so landscape is
    // preferred when the OS/device allows rotation.
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
}

/// Toggles fullscreen on desktop platforms. No-op (returns false) elsewhere —
/// Android fullscreen is the permanent default set in
/// [initializePlatformLayout], not a runtime toggle.
Future<bool> toggleDesktopFullscreen() async {
  if (!isDesktopPlatform) return false;
  final isFull = await windowManager.isFullScreen();
  await windowManager.setFullScreen(!isFull);
  return !isFull;
}

Future<bool> isDesktopFullscreen() async {
  if (!isDesktopPlatform) return false;
  return windowManager.isFullScreen();
}

/// Temporarily reveals Android's system bars (e.g. so the user can reach the
/// connect/discover controls), then hides them again. No-op on desktop.
Future<void> revealAndroidSystemUiTemporarily() async {
  if (!Platform.isAndroid) return;
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
}

/// Re-hides Android's system bars after [revealAndroidSystemUiTemporarily].
/// No-op on desktop.
Future<void> hideAndroidSystemUi() async {
  if (!Platform.isAndroid) return;
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}
