import 'package:flutter/material.dart';

import 'ui/helm_home_screen.dart';
import 'ui/helm_video_view.dart';
import 'ui/platform_layout.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Tested forceSoftwareDecoder: true against a real plotter on Android —
  // it made the touch-to-video-update lag *worse*, not better, ruling out
  // the hardware decoder's frame queue as the dominant delay. Left as a
  // parameter (see registerHelmVideoPlayer's doc comment) rather than
  // removed, in case it's worth re-testing on other hardware, but the
  // default stays with hardware decoding.
  registerHelmVideoPlayer();
  await initializePlatformLayout();
  runApp(const RemoteHelmApp());
}

class RemoteHelmApp extends StatelessWidget {
  const RemoteHelmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Helm',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey)),
      darkTheme: ThemeData.dark(),
      home: const HelmHomeScreen(),
    );
  }
}
