import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/ui/helm_video_view.dart';

void main() {
  group('isStalled', () {
    test('not stalled while not playing (paused/buffering holds position)', () {
      expect(
        isStalled(
          isPlaying: false,
          lastPosition: const Duration(seconds: 5),
          position: const Duration(seconds: 5),
        ),
        isFalse,
      );
    });

    test('not stalled on the first check (no prior position yet)', () {
      expect(
        isStalled(
          isPlaying: true,
          lastPosition: null,
          position: const Duration(seconds: 5),
        ),
        isFalse,
      );
    });

    test('not stalled while position is still advancing', () {
      expect(
        isStalled(
          isPlaying: true,
          lastPosition: const Duration(seconds: 5),
          position: const Duration(seconds: 8),
        ),
        isFalse,
      );
    });

    test('stalled when playing but position has not moved since the last check', () {
      expect(
        isStalled(
          isPlaying: true,
          lastPosition: const Duration(seconds: 5),
          position: const Duration(seconds: 5),
        ),
        isTrue,
      );
    });

    test('stalled when playing but position went backwards', () {
      // Shouldn't normally happen for a live stream, but treat it the same
      // as "not advancing" rather than as healthy playback.
      expect(
        isStalled(
          isPlaying: true,
          lastPosition: const Duration(seconds: 5),
          position: const Duration(seconds: 3),
        ),
        isTrue,
      );
    });
  });
}
