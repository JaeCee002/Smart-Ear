import 'package:flutter/material.dart';

import '../services/alert_history_service.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({
    super.key,
    required this.entries,
    required this.onClear,
  });

  final List<AlertHistoryEntry> entries;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'ALERT HISTORY',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              if (entries.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _confirmClear(context),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear'),
                ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No critical sounds have been recorded yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _urgencyColor(entry.urgency),
                          child: const Icon(Icons.hearing, color: Colors.white),
                        ),
                        title: Text(entry.displayName),
                        subtitle: Text(_dateTime(entry.detectedAt)),
                        trailing: Text(
                          '${(entry.confidence * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear alert history?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onClear();
  }

  static Color _urgencyColor(String urgency) => switch (urgency) {
    'high' => const Color(0xFFD32F2F),
    'medium' => const Color(0xFFF57C00),
    _ => const Color(0xFF00838F),
  };

  static String _dateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
