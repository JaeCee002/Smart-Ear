import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AlertHistoryEntry {
  const AlertHistoryEntry({
    required this.label,
    required this.displayName,
    required this.confidence,
    required this.urgency,
    required this.detectedAt,
  });

  final String label;
  final String displayName;
  final double confidence;
  final String urgency;
  final DateTime detectedAt;

  Map<String, dynamic> toJson() => {
    'label': label,
    'displayName': displayName,
    'confidence': confidence,
    'urgency': urgency,
    'detectedAt': detectedAt.toUtc().toIso8601String(),
  };

  factory AlertHistoryEntry.fromJson(Map<String, dynamic> json) =>
      AlertHistoryEntry(
        label: json['label'] as String,
        displayName: json['displayName'] as String,
        confidence: (json['confidence'] as num).toDouble(),
        urgency: json['urgency'] as String,
        detectedAt: DateTime.parse(json['detectedAt'] as String).toLocal(),
      );
}

class AlertHistoryService {
  static const int maximumEntries = 200;

  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/smart_ear_alert_history.json');
  }

  Future<List<AlertHistoryEntry>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final values = jsonDecode(await file.readAsString()) as List<dynamic>;
      return values
          .map(
            (value) =>
                AlertHistoryEntry.fromJson(value as Map<String, dynamic>),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<AlertHistoryEntry>> add(AlertHistoryEntry entry) async {
    final entries = await load();
    entries.insert(0, entry);
    if (entries.length > maximumEntries) {
      entries.removeRange(maximumEntries, entries.length);
    }
    await _write(entries);
    return entries;
  }

  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  Future<void> _write(List<AlertHistoryEntry> entries) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
      flush: true,
    );
  }
}
