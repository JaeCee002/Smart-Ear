import 'package:flutter/material.dart';

import '../services/app_preferences.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.preferences,
    required this.onChanged,
  });

  final AppPreferences preferences;
  final ValueChanged<AppPreferences> onChanged;

  static const labels = {
    'siren': 'Emergency sirens',
    'car_horn': 'Car horns',
    'glass_breaking': 'Breaking glass',
    'baby_crying': 'Baby crying',
    'door_knocking': 'Door knocking',
  };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        const Text('SETTINGS', style: _headingStyle),
        const SizedBox(height: 8),
        const Text(
          'Choose which sounds should interrupt you and how alerts behave.',
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 24),
        const Text('SOUND ALERTS', style: _sectionStyle),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: labels.entries.map((entry) {
              final enabled = preferences.enabledLabels.contains(entry.key);
              return SwitchListTile(
                title: Text(entry.value),
                value: enabled,
                onChanged: (value) {
                  final updated = Set<String>.from(preferences.enabledLabels);
                  value ? updated.add(entry.key) : updated.remove(entry.key);
                  onChanged(preferences.copyWith(enabledLabels: updated));
                },
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 20),
        const Text('SENSITIVITY', style: _sectionStyle),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${(preferences.minimumConfidence * 100).round()}% minimum confidence',
                ),
                Slider(
                  value: preferences.minimumConfidence,
                  min: 0.4,
                  max: 0.9,
                  divisions: 10,
                  label: '${(preferences.minimumConfidence * 100).round()}%',
                  onChanged: (value) =>
                      onChanged(preferences.copyWith(minimumConfidence: value)),
                ),
                const Text(
                  'Lower values detect more sounds but may increase false alerts.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text('ALERT EFFECTS', style: _sectionStyle),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Vibration'),
                subtitle: const Text('Available on supported Android devices'),
                value: preferences.vibrationEnabled,
                onChanged: (value) =>
                    onChanged(preferences.copyWith(vibrationEnabled: value)),
              ),
              SwitchListTile(
                title: const Text('Camera flash'),
                subtitle: const Text('Used only for high-priority alerts'),
                value: preferences.flashEnabled,
                onChanged: (value) =>
                    onChanged(preferences.copyWith(flashEnabled: value)),
              ),
              ListTile(
                title: const Text('On-screen alert duration'),
                trailing: DropdownButton<int>(
                  value: preferences.alertDurationSeconds,
                  items: const [2, 4, 6, 8, 10]
                      .map(
                        (seconds) => DropdownMenuItem(
                          value: seconds,
                          child: Text('$seconds sec'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      onChanged(
                        preferences.copyWith(alertDurationSeconds: value),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Smart Ear currently monitors only while this screen is active. '
          'Background monitoring will be added after physical-device battery testing.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }

  static const _headingStyle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w900,
    letterSpacing: 1.5,
  );
  static const _sectionStyle = TextStyle(
    color: Color(0xFF00E5FF),
    fontWeight: FontWeight.bold,
    letterSpacing: 1.2,
  );
}
