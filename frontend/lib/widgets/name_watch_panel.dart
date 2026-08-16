import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/audio_service.dart';
import '../services/name_watch_service.dart';

class NameWatchPanel extends StatefulWidget {
  const NameWatchPanel({super.key});

  @override
  State<NameWatchPanel> createState() => _NameWatchPanelState();
}

class _NameWatchPanelState extends State<NameWatchPanel> {
  static const int _analysisWindowSeconds = 2;
  static const int _alertCooldownSeconds = 5;
  static const int _requiredConsecutiveHits = 3;

  final AudioService _audioService = AudioService();
  final NameWatchService _nameWatchService = NameWatchService();
  final TextEditingController _nameController = TextEditingController();

  StreamSubscription<Uint8List>? _audioSubscription;
  Timer? _alertTimer;
  final List<int> _rollingPcm = [];
  int _bytesSinceDetection = 0;
  bool _isMonitoring = false;
  bool _isRecordingSample = false;
  bool _isSavingSample = false;
  String _statusMessage = 'Record a few samples of a name to enroll it.';
  NameMatchResult? _lastMatch;
  List<NameProfile> _profiles = [];
  DateTime _lastAlertAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _candidateName;
  int _candidateHits = 0;
  double _candidateConfidenceSum = 0;
  bool _isDetecting = false;

  int get _windowBytes => AudioService.sampleRate * 2 * _analysisWindowSeconds;
  int get _hopBytes => AudioService.sampleRate * 2;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void dispose() {
    _alertTimer?.cancel();
    _audioSubscription?.cancel();
    _audioService.stopPcmStream();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    final profiles = await _nameWatchService.listProfiles();
    if (!mounted) return;
    setState(() => _profiles = profiles);
  }

  Future<void> _recordSample() async {
    if (_isRecordingSample || _isSavingSample) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(
        () => _statusMessage = 'Enter a name before recording a sample.',
      );
      return;
    }

    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      setState(() {
        _statusMessage =
            'Microphone recording is not supported on this platform.';
      });
      return;
    }

    setState(() {
      _isRecordingSample = true;
      _statusMessage = 'Recording a sample for $name...';
      _lastMatch = null;
    });

    try {
      for (var second = 2; second > 0; second--) {
        if (!mounted) throw StateError('Recording cancelled.');
        setState(() => _statusMessage = 'Say "$name" in $second...');
        await Future.delayed(const Duration(seconds: 1));
      }

      final filePath = await _audioService.startRecording();
      if (filePath == null) {
        throw Exception('Failed to start recording');
      }
      if (mounted) setState(() => _statusMessage = 'Say "$name" now!');
      await Future.delayed(const Duration(milliseconds: 1800));

      final audioBytes = await _audioService.stopRecording();
      if (audioBytes == null || audioBytes.isEmpty) {
        throw Exception('Failed to capture audio sample');
      }

      setState(() => _isSavingSample = true);
      final profile = await _nameWatchService.enrollSample(name, audioBytes);
      final profiles = await _nameWatchService.listProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _statusMessage =
            'Saved sample ${profile.sampleCount} for ${profile.name}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _statusMessage = error.toString());
    } finally {
      if (!mounted) return;
      setState(() {
        _isRecordingSample = false;
        _isSavingSample = false;
      });
    }
  }

  Future<void> _startMonitoring() async {
    if (_isMonitoring) return;
    if (_profiles.isEmpty) {
      setState(
        () => _statusMessage = 'Enroll at least one name before monitoring.',
      );
      return;
    }
    if (_profiles.any((profile) => profile.sampleCount < 3)) {
      setState(() {
        _statusMessage =
            'Please record at least 3 samples for each enrolled name before monitoring.';
      });
      return;
    }

    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      setState(() {
        _statusMessage =
            'Continuous monitoring is not supported on this platform.';
      });
      return;
    }

    try {
      final stream = await _audioService.startPcmStream(channels: 1);
      _rollingPcm.clear();
      _bytesSinceDetection = 0;
      await _audioSubscription?.cancel();
      _audioSubscription = stream.listen(
        _handlePcmChunk,
        onError: _handleStreamError,
        onDone: _handleStreamDone,
        cancelOnError: true,
      );
      if (!mounted) return;
      setState(() {
        _isMonitoring = true;
        _statusMessage = 'Listening for enrolled names...';
        _lastMatch = null;
        _candidateName = null;
        _candidateHits = 0;
        _candidateConfidenceSum = 0;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Could not start monitoring: $error');
    }
  }

  Future<void> _stopMonitoring() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _audioService.stopPcmStream();
    _rollingPcm.clear();
    _bytesSinceDetection = 0;
    if (!mounted) return;
    setState(() {
      _isMonitoring = false;
      _statusMessage = 'Monitoring stopped.';
      _candidateName = null;
      _candidateHits = 0;
      _candidateConfidenceSum = 0;
    });
  }

  void _handlePcmChunk(Uint8List chunk) {
    if (!_isMonitoring || chunk.isEmpty) return;

    _rollingPcm.addAll(chunk);
    _bytesSinceDetection += chunk.length;
    if (_rollingPcm.length > _windowBytes) {
      _rollingPcm.removeRange(0, _rollingPcm.length - _windowBytes);
    }

    if (_rollingPcm.length == _windowBytes &&
        _bytesSinceDetection >= _hopBytes) {
      _bytesSinceDetection = 0;
      _detectWindow(List<int>.from(_rollingPcm));
    }
  }

  Future<void> _detectWindow(List<int> pcmWindow) async {
    if (_isDetecting) return;
    _isDetecting = true;
    NameMatchResult? match;
    try {
      match = await _nameWatchService.detectFromPcm(pcmWindow);
    } finally {
      _isDetecting = false;
    }
    if (!mounted || !_isMonitoring) return;
    if (match == null) {
      _candidateHits = 0;
      _candidateConfidenceSum = 0;
      _candidateName = null;
      return;
    }
    final confirmedMatch = match;

    if (_candidateName == confirmedMatch.name) {
      _candidateHits++;
      _candidateConfidenceSum += confirmedMatch.confidence;
    } else {
      _candidateName = confirmedMatch.name;
      _candidateHits = 1;
      _candidateConfidenceSum = confirmedMatch.confidence;
    }

    if (_candidateHits < _requiredConsecutiveHits) {
      setState(() {
        _statusMessage =
            'Possible ${confirmedMatch.name} ($_candidateHits/$_requiredConsecutiveHits), confirming...';
      });
      return;
    }

    final averagedConfidence = (_candidateConfidenceSum / _candidateHits)
        .clamp(0.0, 1.0)
        .toDouble();

    setState(() {
      _lastMatch = NameMatchResult(
        name: confirmedMatch.name,
        score: confirmedMatch.score,
        confidence: averagedConfidence,
      );
      _statusMessage =
          'Detected ${confirmedMatch.name} with ${(averagedConfidence * 100).toStringAsFixed(1)}% confidence.';
    });
    _candidateHits = 0;
    _candidateConfidenceSum = 0;
    _candidateName = null;

    final now = DateTime.now();
    if (now.difference(_lastAlertAt).inSeconds < _alertCooldownSeconds) {
      return;
    }

    _lastAlertAt = now;
    HapticFeedback.mediumImpact();
    _alertTimer?.cancel();
    _alertTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _lastMatch = null);
    });
  }

  void _handleStreamError(Object error, StackTrace stackTrace) {
    if (!mounted) return;
    setState(() {
      _isMonitoring = false;
      _statusMessage = 'Audio stream error: $error';
    });
  }

  void _handleStreamDone() {
    if (!mounted) return;
    setState(() {
      _isMonitoring = false;
      _statusMessage = 'Audio stream closed.';
    });
  }

  Future<void> _deleteProfile(String name) async {
    await _nameWatchService.deleteProfile(name);
    final profiles = await _nameWatchService.listProfiles();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _statusMessage = 'Removed $name.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final lastMatch = _lastMatch;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF121214),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NAME WATCH',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 2,
                    color: Color(0xFF00E5FF),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Record a few samples of each name, then let the app listen for those voice patterns locally on the device.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Name to enroll',
                    hintText: 'e.g. Chanda, Mulenga, Bwalya',
                    filled: true,
                    fillColor: const Color(0xFF1A1A1C),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: (_isRecordingSample || _isSavingSample)
                          ? null
                          : _recordSample,
                      icon: const Icon(Icons.mic),
                      label: Text(
                        _isRecordingSample
                            ? 'Recording...'
                            : _isSavingSample
                            ? 'Saving...'
                            : 'Record sample',
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _isMonitoring
                          ? _stopMonitoring
                          : _startMonitoring,
                      icon: Icon(_isMonitoring ? Icons.stop : Icons.hearing),
                      label: Text(
                        _isMonitoring ? 'Stop monitoring' : 'Start monitoring',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _profiles.isEmpty
                          ? null
                          : () async {
                              await _nameWatchService.clearAll();
                              final profiles = await _nameWatchService
                                  .listProfiles();
                              if (!mounted) return;
                              setState(() {
                                _profiles = profiles;
                                _statusMessage = 'Cleared all enrolled names.';
                              });
                            },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear all'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Tip: record 3 samples per name for better matching.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (lastMatch != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00E5FF), Color(0xFF004B5A)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: Colors.white,
                    child: Icon(
                      Icons.record_voice_over,
                      color: Color(0xFF00E5FF),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Detected ${lastMatch.name}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Confidence ${(lastMatch.confidence * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1C),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              _statusMessage,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Enrolled names',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.5,
              color: Colors.white54,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          if (_profiles.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF121214),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                'No names enrolled yet.',
                style: TextStyle(color: Colors.white54),
              ),
            )
          else
            ..._profiles.map(
              (profile) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121214),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 20,
                        backgroundColor: Color(0xFF00E5FF),
                        child: Icon(Icons.person, color: Colors.black),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${profile.sampleCount} sample${profile.sampleCount == 1 ? '' : 's'} saved',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Delete ${profile.name}',
                        onPressed: () => _deleteProfile(profile.name),
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
