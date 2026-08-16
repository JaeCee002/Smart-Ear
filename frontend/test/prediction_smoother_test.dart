import 'package:flutter_test/flutter_test.dart';
import 'package:smartear_flutter/services/prediction_smoother.dart';

void main() {
  group('PredictionSmoother', () {
    test('waits for repeated evidence before switching labels', () {
      final smoother = PredictionSmoother(windowSize: 3, requiredVotes: 2);

      final first = smoother.update('siren', 0.9);
      expect(first.label, 'siren');
      expect(first.shouldUpdate, isTrue);

      final second = smoother.update('door_wood_knock', 0.88);
      expect(second.label, 'siren');
      expect(second.shouldUpdate, isFalse);
    });

    test('accepts a strong single prediction when no history exists', () {
      final smoother = PredictionSmoother(windowSize: 3, requiredVotes: 2);

      final result = smoother.update('crying_baby', 0.95);
      expect(result.label, 'crying_baby');
      expect(result.shouldUpdate, isTrue);
    });

    test('keeps the previous label for low-confidence predictions', () {
      final smoother = PredictionSmoother(windowSize: 3, requiredVotes: 2);

      smoother.update('siren', 0.9);
      final result = smoother.update('door_wood_knock', 0.2);

      expect(result.label, 'siren');
      expect(result.shouldUpdate, isFalse);
    });
  });
}
