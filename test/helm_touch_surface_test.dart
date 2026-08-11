import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/ui/helm_touch_surface.dart';

void main() {
  group('measuredVideoRect', () {
    testWidgets('returns null before the video box has been laid out', (tester) async {
      final key = GlobalKey();
      final ancestorKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(key: ancestorKey, width: 800, height: 600),
        ),
      );
      final ancestorBox = ancestorKey.currentContext!.findRenderObject()! as RenderBox;
      // `key` was never attached to anything in the pumped tree, matching
      // the state before HelmVideoView's AspectRatio has been built.
      expect(measuredVideoRect(key, ancestorBox), isNull);
    });

    testWidgets('measures the exact rect of a same-size child', (tester) async {
      final videoKey = GlobalKey();
      final ancestorKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            key: ancestorKey,
            width: 800,
            height: 600,
            child: SizedBox(key: videoKey, width: 800, height: 600),
          ),
        ),
      );
      final ancestorBox = ancestorKey.currentContext!.findRenderObject()! as RenderBox;
      final rect = measuredVideoRect(videoKey, ancestorBox);
      expect(rect, const Rect.fromLTWH(0, 0, 800, 600));
    });

    testWidgets(
      'portrait window with a landscape video: measures the letterboxed rect actually rendered',
      (tester) async {
        // Reproduces the reported bug scenario directly: a tablet in
        // portrait (narrower than tall) showing the plotter's fixed 16:9
        // landscape video via Center+AspectRatio, exactly like
        // HelmVideoView renders it. Measuring the real AspectRatio render
        // box (rather than recomputing its layout from a tracked
        // aspectRatio number) means this is the same rect the video is
        // actually drawn at, by construction — no way for the two to
        // diverge.
        tester.view.physicalSize = const Size(720, 1280);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final videoKey = GlobalKey();
        final ancestorKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox.expand(
              key: ancestorKey,
              child: Center(
                child: AspectRatio(
                  key: videoKey,
                  aspectRatio: 16 / 9,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        final ancestorBox = ancestorKey.currentContext!.findRenderObject()! as RenderBox;
        final rect = measuredVideoRect(videoKey, ancestorBox)!;

        expect(rect.width, 720);
        expect(rect.height, closeTo(405, 0.01)); // 720 / (16/9)
        expect(rect.left, 0);
        expect(rect.top, closeTo((1280 - 405) / 2, 0.01));
      },
    );

    testWidgets('a tap at the video rectangle\'s exact corners normalizes to (0,0) and (1,1)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final videoKey = GlobalKey();
      final ancestorKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            key: ancestorKey,
            child: Center(
              child: AspectRatio(
                key: videoKey,
                aspectRatio: 16 / 9,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      final ancestorBox = ancestorKey.currentContext!.findRenderObject()! as RenderBox;
      final rect = measuredVideoRect(videoKey, ancestorBox)!;

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
