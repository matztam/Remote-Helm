import 'package:flutter/material.dart';

import 'ui/helm_home_screen.dart';
import 'ui/helm_video_view.dart';
import 'ui/platform_layout.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerHelmVideoPlayer();
  await initializePlatformLayout();
  runApp(const RemoteHelmApp());
}

class RemoteHelmApp extends StatelessWidget {
  const RemoteHelmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'remote_helm',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey)),
      darkTheme: ThemeData.dark(),
      home: const HelmHomeScreen(),
    );
  }
}
