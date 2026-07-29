import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/ui/helm_touch_surface.dart';

void main() {
  group('videoRect', () {
    test('with no aspect ratio, returns the full container (pre-letterboxing behavior)', () {
      const size = Size(800, 400);
      expect(videoRect(size, null), const Rect.fromLTWH(0, 0, 800, 400));
    });

    test('with a non-positive aspect ratio, returns the full container', () {
      const size = Size(800, 400);
      expect(videoRect(size, 0), const Rect.fromLTWH(0, 0, 800, 400));
      expect(videoRect(size, -1), const Rect.fromLTWH(0, 0, 800, 400));
    });

    test('when container and video aspect ratios match, fills the container exactly', () {
      // 16:9 container, 16:9 video.
      const size = Size(1600, 900);
      final rect = videoRect(size, 16 / 9);
      expect(rect, const Rect.fromLTWH(0, 0, 1600, 900));
    });

    test('portrait window with a landscape video: letterboxed top/bottom, centered', () {
      // A tablet rotated to portrait (narrower than tall), showing the
      // plotter's fixed 16:9 landscape video — this is the case that
      // broke before videoRect existed: the video is width-constrained
      // and much shorter than the full container height.
      const size = Size(720, 1280);
      final rect = videoRect(size, 16 / 9);

      expect(rect.width, 720);
      expect(rect.height, closeTo(405, 0.01)); // 720 / (16/9)
      expect(rect.left, 0);
      expect(rect.top, closeTo((1280 - 405) / 2, 0.01));
    });

    test('landscape window much wider than a landscape video: letterboxed left/right, centered', () {
      const size = Size(2000, 900);
      final rect = videoRect(size, 16 / 9);

      expect(rect.height, 900);
      expect(rect.width, closeTo(1600, 0.01)); // 900 * (16/9)
      expect(rect.top, 0);
      expect(rect.left, closeTo((2000 - 1600) / 2, 0.01));
    });

    test('a tap at the video rectangle\'s exact corners normalizes to (0,0) and (1,1)', () {
      // Regression check for the actual bug report: after a rotation, taps
      // at the visible edges of the (now letterboxed) video must still map
      // to the plotter's own screen edges, not to the edges of the full
      // (larger) container.
      const size = Size(720, 1280);
      final rect = videoRect(size, 16 / 9);

      Offset normalize(Offset local) {
        final x = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
        final y = ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
        return Offset(x, y);
      }

      expect(normalize(rect.topLeft), const Offset(0, 0));
      expect(normalize(rect.bottomRight), const Offset(1, 1));
      expect(normalize(rect.center), const Offset(0.5, 0.5));

      // A tap in the letterboxed dead zone (above the video, since it's
      // vertically centered) clamps to the nearest video edge rather than
      // producing an out-of-range or negative coordinate.
      final aboveVideo = Offset(rect.center.dx, 0);
      expect(normalize(aboveVideo).dy, 0);
    });
  });
}
