# remote_helm

A cross-platform (Windows, Linux, Android) remote control app for Garmin
chartplotters that support the ActiveCaptain Helm remote — the same
video-plus-touch protocol the official Garmin ActiveCaptain mobile app
uses. Run it full-screen on a tablet mounted at the helm, or windowed on a
laptop at the nav station.

It shows the plotter's live screen (RTSP/H.264 video) and forwards
touch/mouse/scroll input back to it (tap, drag, pinch-to-zoom), so it works
as an alternative touchscreen for the plotter over Wi-Fi.

## Credit

This project is a Flutter/Dart port and continuation of
[Mrkvak/helm-linux](https://github.com/Mrkvak/helm-linux) — a Python
reference implementation for the same protocol, reverse-engineered from a
live capture plus static analysis of the ActiveCaptain app's native core.
The wire protocol (`lib/helm/protocol.dart`, `lib/helm/helm_client.dart`)
and pairing flow (`lib/helm/credential.dart`) are ported from that project;
without that prior reverse-engineering work this app wouldn't exist. Like
`helm-linux`, this project is released under the MIT license.

If you only need a Linux desktop client (GTK/GStreamer or mpv-backed, no
Flutter toolchain required), `helm-linux` is a lighter-weight option. This
project exists for cross-platform reach (Windows, Linux, and Android from
one codebase) and a touch-first UI meant to run full-screen on a tablet.

## Features

- **Live video**: the plotter's screen over RTSP/H.264, letterboxed to fit
  the window/screen without cropping.
- **Touch control**: tap, drag, and two-finger pinch-to-zoom map directly
  onto the plotter's screen. Desktop mouse: click-drag + scroll wheel for
  zoom.
- **Discovery & pairing**: finds plotters via mDNS
  (`_garmin-helm._tcp.local`) and handles the one-time pairing handshake
  with the plotter's on-board bl-id service — no manual IP entry required
  (though it's supported as a fallback).
- **Fullscreen on Android**: immersive mode by default, since the point of
  running this on a tablet is to give the video the whole screen. A
  thin edge-tap reveals the connect/discover controls when needed.
- **Windowed on desktop**: normal resizable window by default on
  Windows/Linux, with an explicit fullscreen toggle, so it coexists with
  other windows at a nav station.
- **Screen stays on** while the app is running (wakelock), since a screen
  timing out mid-use at the helm would defeat the point.

## Requirements

- A Garmin chartplotter with ActiveCaptain Helm remote support, reachable
  over the same Wi-Fi network as the device running this app.
- The plotter's App Permission (Settings → Communications → Wireless
  Devices/ActiveCaptain, or similar, depending on your plotter's menu
  layout) set to **"View and Control"** — "View only" will pair and show
  video but touch input will silently do nothing.

## Building

This is a standard Flutter project targeting Windows, Linux, and Android.

```sh
flutter pub get
flutter run -d linux     # or -d windows, or -d <android-device-id>
```

Release builds:

```sh
flutter build linux --release
flutter build windows --release
flutter build apk --release
```

Windows can't be cross-compiled from Linux/macOS — building it requires an
actual Windows host. This repo includes a GitHub Actions workflow
(`.github/workflows/windows-build.yml`) that builds it on a hosted Windows
runner on every push and uploads the result as a downloadable artifact, if
you don't have a Windows machine handy.

### Android build note

`fvp` (the RTSP-capable video backend, see below) pulls in a `jni` package
version that breaks `flutter build apk` on recent Android Gradle Plugin
versions ("Could not find method kotlin()"). This is worked around with a
`dependency_overrides: jni: ^1.0.2` pin in `pubspec.yaml` — already in
place, no action needed, but worth knowing about if you see that error
after upgrading dependencies.

## Command-line protocol tool

`bin/helm_cli.dart` exercises the protocol layer directly, without the
Flutter GUI — useful for verifying discovery/pairing/session setup against
a real plotter, or for debugging:

```sh
dart run bin/helm_cli.dart discover
dart run bin/helm_cli.dart pair <plotter-ip>
dart run bin/helm_cli.dart helm --host <plotter-ip> --tap 0.5 0.5
```

## How it works

- **Discovery**: mDNS browsing for `_garmin-helm._tcp.local`
  (`lib/helm/discovery.dart`).
- **Pairing**: an HTTP/protobuf handshake with the plotter's `_garmin-bl-
  id._tcp` service registers this device and obtains a role/token
  (`lib/helm/credential.dart`).
- **Touch/control session**: a persistent TCP connection on port 51200
  using a small proprietary binary framing (`[u16 type LE][u16
  0xBEEF][u32 length LE][payload]`), documented and implemented in
  `lib/helm/protocol.dart` and `lib/helm/helm_client.dart`. After the
  initial handshake grants a touch context, the plotter expects ongoing
  touch activity as a keepalive for the *whole* session — including the
  separate video stream — so this client sends a periodic inert touch
  frame once every 5 seconds for as long as it's connected (see
  `helm_client.dart`'s doc comment for the full story of how that
  requirement was found).
- **Video**: the plotter serves H.264 over RTSP on port 554, UDP transport
  only. `video_player` has no RTSP support on its own, so `fvp` (an
  FFmpeg/mdk-based platform implementation) is registered in its place
  (`lib/ui/helm_video_view.dart`).

## License

MIT — see [LICENSE](LICENSE). Portions of the protocol implementation are
ported from [Mrkvak/helm-linux](https://github.com/Mrkvak/helm-linux),
also MIT-licensed.
