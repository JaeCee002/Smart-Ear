class PredictionSmoother {
  PredictionSmoother({required this.windowSize, required this.requiredVotes}) {
    assert(windowSize >= 1);
    assert(requiredVotes >= 1);
    assert(requiredVotes <= windowSize);
  }

  final int windowSize;
  final int requiredVotes;

  final List<_PredictionVote> _history = <_PredictionVote>[];
  String? _currentLabel;

  void reset() {
    _history.clear();
    _currentLabel = null;
  }

  PredictionDecision update(String label, double confidence) {
    final normalizedLabel = label.trim().toLowerCase();
    if (normalizedLabel.isEmpty) {
      return PredictionDecision(label: _currentLabel ?? 'unknown', shouldUpdate: false);
    }

    if (confidence < 0.55) {
      return PredictionDecision(label: _currentLabel ?? normalizedLabel, shouldUpdate: false);
    }

    _history.add(_PredictionVote(normalizedLabel, confidence));
    if (_history.length > windowSize) {
      _history.removeAt(0);
    }

    final voteCounts = <String, int>{};
    final confidenceSums = <String, double>{};
    for (final vote in _history) {
      voteCounts[vote.label] = (voteCounts[vote.label] ?? 0) + 1;
      confidenceSums[vote.label] = (confidenceSums[vote.label] ?? 0.0) + vote.confidence;
    }

    final winner = voteCounts.entries.reduce(
      (best, current) =>
          current.value > best.value ||
                  (current.value == best.value &&
                      (confidenceSums[current.key] ?? 0.0) >
                          (confidenceSums[best.key] ?? 0.0))
              ? current
              : best,
    );

    if (_currentLabel == null) {
      _currentLabel = winner.key;
      return PredictionDecision(label: _currentLabel!, shouldUpdate: true);
    }

    final hasEnoughVotes = (voteCounts[winner.key] ?? 0) >= requiredVotes;
    if (hasEnoughVotes && winner.key != _currentLabel) {
      _currentLabel = winner.key;
      return PredictionDecision(label: _currentLabel!, shouldUpdate: true);
    }

    return PredictionDecision(label: _currentLabel!, shouldUpdate: false);
  }
}

class PredictionDecision {
  const PredictionDecision({required this.label, required this.shouldUpdate});

  final String label;
  final bool shouldUpdate;
}

class _PredictionVote {
  const _PredictionVote(this.label, this.confidence);

  final String label;
  final double confidence;
}
