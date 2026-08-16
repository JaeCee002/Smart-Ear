import 'package:flutter_test/flutter_test.dart';
import 'package:smartear_flutter/services/app_preferences.dart';

void main() {
  test('preferences serialize and restore', () {
    final original = const AppPreferences().copyWith(
      enabledLabels: {'siren', 'baby_crying'},
      minimumConfidence: 0.7,
      vibrationEnabled: false,
      alertDurationSeconds: 8,
    );

    final restored = AppPreferences.fromJson(original.toJson());

    expect(restored.enabledLabels, {'siren', 'baby_crying'});
    expect(restored.minimumConfidence, 0.7);
    expect(restored.vibrationEnabled, isFalse);
    expect(restored.flashEnabled, isTrue);
    expect(restored.alertDurationSeconds, 8);
  });

  test('unsafe numeric values are clamped', () {
    final restored = AppPreferences.fromJson({
      'minimumConfidence': 2,
      'alertDurationSeconds': 100,
    });

    expect(restored.minimumConfidence, 0.9);
    expect(restored.alertDurationSeconds, 10);
  });
}
