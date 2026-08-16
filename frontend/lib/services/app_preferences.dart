import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppPreferences {
  const AppPreferences({
    this.enabledLabels = const {
      'siren',
      'car_horn',
      'glass_breaking',
      'baby_crying',
      'door_knocking',
    },
    this.minimumConfidence = 0.55,
    this.vibrationEnabled = true,
    this.flashEnabled = true,
    this.alertDurationSeconds = 4,
  });

  final Set<String> enabledLabels;
  final double minimumConfidence;
  final bool vibrationEnabled;
  final bool flashEnabled;
  final int alertDurationSeconds;

  AppPreferences copyWith({
    Set<String>? enabledLabels,
    double? minimumConfidence,
    bool? vibrationEnabled,
    bool? flashEnabled,
    int? alertDurationSeconds,
  }) => AppPreferences(
    enabledLabels: enabledLabels ?? this.enabledLabels,
    minimumConfidence: minimumConfidence ?? this.minimumConfidence,
    vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
    flashEnabled: flashEnabled ?? this.flashEnabled,
    alertDurationSeconds: alertDurationSeconds ?? this.alertDurationSeconds,
  );

  Map<String, dynamic> toJson() => {
    'enabledLabels': enabledLabels.toList()..sort(),
    'minimumConfidence': minimumConfidence,
    'vibrationEnabled': vibrationEnabled,
    'flashEnabled': flashEnabled,
    'alertDurationSeconds': alertDurationSeconds,
  };

  factory AppPreferences.fromJson(Map<String, dynamic> json) {
    final defaults = const AppPreferences();
    return AppPreferences(
      enabledLabels:
          (json['enabledLabels'] as List<dynamic>?)
              ?.whereType<String>()
              .toSet() ??
          defaults.enabledLabels,
      minimumConfidence:
          (json['minimumConfidence'] as num?)
              ?.toDouble()
              .clamp(0.4, 0.9)
              .toDouble() ??
          defaults.minimumConfidence,
      vibrationEnabled:
          json['vibrationEnabled'] as bool? ?? defaults.vibrationEnabled,
      flashEnabled: json['flashEnabled'] as bool? ?? defaults.flashEnabled,
      alertDurationSeconds:
          (json['alertDurationSeconds'] as num?)
              ?.toInt()
              .clamp(2, 10)
              .toInt() ??
          defaults.alertDurationSeconds,
    );
  }
}

class AppPreferencesStore {
  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/smart_ear_preferences.json');
  }

  Future<AppPreferences> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const AppPreferences();
      final json = jsonDecode(await file.readAsString());
      return AppPreferences.fromJson(json as Map<String, dynamic>);
    } catch (_) {
      return const AppPreferences();
    }
  }

  Future<void> save(AppPreferences preferences) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(preferences.toJson()), flush: true);
  }
}
