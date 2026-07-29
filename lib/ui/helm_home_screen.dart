/// The app's single screen: video + touch control, with a connect/discover
/// control bar that's always visible on desktop and hidden (behind a small
/// edge tap) on Android, where the video should fill the whole display.
library;

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../helm/discovery.dart';
import 'helm_session_controller.dart';
import 'helm_touch_surface.dart';
import 'helm_video_view.dart';
import 'platform_layout.dart';

class HelmHomeScreen extends StatefulWidget {
  const HelmHomeScreen({super.key});

  @override
  State<HelmHomeScreen> createState() => _HelmHomeScreenState();
}

class _HelmHomeScreenState extends State<HelmHomeScreen> {
  final _session = HelmSessionController();
  final _hostController = TextEditingController();
  bool _controlsVisible = true; // desktop: always effectively true (shown)
  bool _isFullscreen = false;

  // Attached to HelmVideoView's AspectRatio widget so HelmTouchSurface can
  // measure its actual on-screen rectangle directly, instead of recomputing
  // it from a separately-tracked aspect ratio value that could drift out of
  // sync with what's actually rendered.
  final _videoBoxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _controlsVisible = isDesktopPlatform; // Android starts hidden (immersive)
    // This is meant to run full-screen on a tablet mounted at the helm —
    // the screen timing out mid-use would defeat the point. Held only for
    // this screen's lifetime, not globally, so it releases automatically
    // if the app is ever backgrounded or closed.
    WakelockPlus.enable();
    _init();
  }

  Future<void> _init() async {
    await _session.loadLastHost();
    final last = _session.lastHost;
    if (last != null && last.isNotEmpty) {
      _hostController.text = last;
      await _session.connect(last);
    } else {
      await _autoDiscoverAndConnect();
    }
  }

  Future<void> _autoDiscoverAndConnect() async {
    final results = await _session.discover();
    if (!mounted) return;
    if (results.length == 1) {
      final host = _addressOf(results.first);
      _hostController.text = host;
      await _session.connect(host);
    }
    // Zero or multiple results: leave it to the user to pick via the
    // control bar (which lists discovered plotters below the host field).
  }

  String _addressOf(HelmServiceInfo s) => s.address.isEmpty ? s.host : s.address;

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    final nowFull = await toggleDesktopFullscreen();
    setState(() => _isFullscreen = nowFull);
  }

  Future<void> _revealControls() async {
    if (!isDesktopPlatform) await revealAndroidSystemUiTemporarily();
    setState(() => _controlsVisible = true);
  }

  Future<void> _hideControls() async {
    if (!isDesktopPlatform) await hideAndroidSystemUi();
    setState(() => _controlsVisible = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // Android is meant to run edge-to-edge/immersive; SafeArea only
        // meaningfully insets on desktop where it's a no-op anyway alongside
        // the normal window chrome.
        top: isDesktopPlatform,
        bottom: isDesktopPlatform,
        child: Column(
          children: [
            if (_controlsVisible) _buildControlBar(context),
            Expanded(child: _buildVideoArea(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea(BuildContext context) {
    final client = _session.client;
    final rtspUrl = client?.rtspUrl;

    final video = rtspUrl == null
        ? const Center(
            child: Text('Not connected.', style: TextStyle(color: Colors.white70)),
          )
        : HelmVideoView(rtspUrl: rtspUrl, videoBoxKey: _videoBoxKey);

    final withTouch = HelmTouchSurface(
      client: client,
      videoBoxKey: _videoBoxKey,
      child: video,
    );

    if (isDesktopPlatform) return withTouch;

    // Android: tapping a thin strip at the very top reveals the hidden
    // controls (mirrors the "swipe from edge" affordance immersive mode
    // already offers for system bars, but ties it to our own UI too).
    return Stack(
      children: [
        Positioned.fill(child: withTouch),
        if (!_controlsVisible)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 24,
            child: GestureDetector(
              onTap: _revealControls,
              child: Container(color: Colors.transparent),
            ),
          ),
      ],
    );
  }

  Widget _buildControlBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Plotter',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Discover',
              icon: const Icon(Icons.search),
              onPressed: _onDiscoverPressed,
            ),
            FilledButton(
              onPressed: _onConnectPressed,
              child: Text(_session.isConnected ? 'Disconnect' : 'Connect'),
            ),
            if (isDesktopPlatform) ...[
              const Spacer(),
              IconButton(
                tooltip: _isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
                icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                onPressed: _toggleFullscreen,
              ),
            ] else ...[
              const Spacer(),
              IconButton(
                tooltip: 'Hide controls',
                icon: const Icon(Icons.expand_less),
                onPressed: _hideControls,
              ),
            ],
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _session.statusMessage ?? '',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onDiscoverPressed() async {
    final results = await _session.discover();
    if (!mounted) return;
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No plotter found. Join the plotter's Wi-Fi.")),
      );
      return;
    }
    if (results.length == 1) {
      _hostController.text = _addressOf(results.first);
      return;
    }
    final chosen = await showDialog<HelmServiceInfo>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select a plotter'),
        children: [
          for (final s in results)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(s),
              child: Text('${s.name}  (${_addressOf(s)})'),
            ),
        ],
      ),
    );
    if (chosen != null) _hostController.text = _addressOf(chosen);
  }

  Future<void> _onConnectPressed() async {
    if (_session.isConnected) {
      _session.disconnect();
      return;
    }
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    await _session.connect(host);
  }
}
