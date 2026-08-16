import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'services/audio_service.dart';
import 'services/alert_history_service.dart';
import 'services/app_preferences.dart';
import 'services/edge_ai_service.dart';
import 'services/prediction_smoother.dart';
import 'services/yamnet_edge_ai_service.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  runApp(const SmartEarApp());
}

class SmartEarApp extends StatelessWidget {
  const SmartEarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Ear',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0B0C),
        primaryColor: const Color(0xFF00E5FF),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  static const MethodChannel _alertChannel = MethodChannel(
    'com.example.smartear_flutter/alerts',
  );
  _DashboardMode _dashboardMode = _DashboardMode.soundAlerts;
  //late AnimationController _pulseController;
  late AnimationController _recordingController;

  final AudioService _audioService = AudioService();
  final AppPreferencesStore _preferencesStore = AppPreferencesStore();
  final AlertHistoryService _historyService = AlertHistoryService();
  final PredictionSmoother _predictionSmoother = PredictionSmoother(
    windowSize: 4,
    requiredVotes: 2,
  );
  static const String _aiEngine = String.fromEnvironment(
    'SMART_EAR_AI_ENGINE',
    defaultValue: 'yamnet',
  );
  final SoundInferenceService _edgeAiService = _aiEngine == 'yamnet'
      ? YamnetEdgeAiService()
      : EdgeAiService();
  String detectedSound = "Listening...";
  double confidence = 0.0;
  bool isRecording = false;
  bool isProcessing = false;
  bool _isStartingListening = false;
  StreamSubscription<Uint8List>? _audioSubscription;
  final List<int> _rollingPcm = [];
  int _bytesSincePrediction = 0;
  DateTime _ignoreAudioUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _alertDismissTimer;
  static const int _pcmBytesPerSample = 2;
  int get _pcmBytesPerSecond => AudioService.sampleRate * _pcmBytesPerSample;
  int get _windowBytes => AudioService.durationSeconds * _pcmBytesPerSecond;
  int get _predictionHopBytes => 2 * _pcmBytesPerSecond;
  int recordingCountdown = 5;
  String errorMessage = "";
  _SoundAlert? _activeAlert;
  AppPreferences _preferences = const AppPreferences();
  List<AlertHistoryEntry> _alertHistory = const [];

  @override
  void initState() {
    super.initState();
    // _pulseController = AnimationController(
    //   vsync: this,
    //   duration: const Duration(seconds: 3),
    // )..repeat();

    _recordingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);

    _requestPermissionsAndInit();
    _loadSavedState();
  }

  Future<void> _loadSavedState() async {
    final results = await Future.wait<dynamic>([
      _preferencesStore.load(),
      _historyService.load(),
    ]);
    if (!mounted) return;
    setState(() {
      _preferences = results[0] as AppPreferences;
      _alertHistory = results[1] as List<AlertHistoryEntry>;
    });
  }

  Future<void> _updatePreferences(AppPreferences preferences) async {
    setState(() => _preferences = preferences);
    await _preferencesStore.save(preferences);
    if (preferences.flashEnabled && Platform.isAndroid) {
      await _audioService.requestCameraPermission();
    }
  }

  Future<void> _clearHistory() async {
    await _historyService.clear();
    if (mounted) setState(() => _alertHistory = const []);
  }

  Future<void> _setDashboardMode(_DashboardMode mode) async {
    if (_dashboardMode == mode) return;
    if (_dashboardMode == _DashboardMode.soundAlerts && isRecording) {
      await _stopContinuousListening();
    }
    if (!mounted) return;
    if (mode != _DashboardMode.soundAlerts) {
      _dismissAlert();
    }
    setState(() {
      _dashboardMode = mode;
    });
  }

  Future<void> _requestPermissionsAndInit() async {
    print("Smart Ear inference engine: $_aiEngine");
    final granted = await _audioService.requestMicrophonePermission();
    if (!granted) {
      if (!mounted) return;
      setState(() {
        errorMessage = "Microphone permission denied";
      });
      return;
    }
    try {
      await _edgeAiService.initialize();
      await _audioService.requestCameraPermission();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        errorMessage = "Could not load the on-device sound model: $error";
      });
    }
  }

  @override
  void dispose() {
    _alertDismissTimer?.cancel();
    _audioSubscription?.cancel();
    _audioService.stopPcmStream();
    // _pulseController.dispose();
    _recordingController.dispose();
    _audioService.dispose();
    _edgeAiService.dispose();
    super.dispose();
  }

  /// Record audio for 5 seconds and get prediction
  Future<void> recordAndPredict() async {
    if (isRecording || isProcessing) return;

    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      setState(() {
        errorMessage =
            "Microphone recording is not supported on this platform.";
        detectedSound = "Error";
        confidence = 0.0;
      });
      return;
    }

    setState(() {
      isRecording = true;
      isProcessing = false;
      errorMessage = "";
      recordingCountdown = 5;
    });

    try {
      // Start recording
      print("🎤 Starting recording...");
      final filePath = await _audioService.startRecording();

      if (filePath == null) {
        throw Exception("Failed to start recording");
      }

      // Wait for 5 seconds while showing countdown
      for (int i = 5; i > 0; i--) {
        setState(() {
          recordingCountdown = i;
        });
        await Future.delayed(const Duration(seconds: 1));
      }

      // Stop recording and get audio bytes
      print("⏹️ Stopping recording...");
      final audioBytes = await _audioService.stopRecording();

      if (audioBytes == null || audioBytes.isEmpty) {
        throw Exception("Failed to get audio data");
      }

      print("✅ Recording complete. Audio size: ${audioBytes.length} bytes");

      setState(() {
        isRecording = false;
        isProcessing = true;
        detectedSound = "Processing...";
      });

      print("Running $_aiEngine on-device prediction...");
      final result = await _edgeAiService.predict(audioBytes);

      setState(() {
        isProcessing = false;
        detectedSound = result["label"] ?? "Unknown";
        confidence = (result["confidence"] ?? 0.0).toDouble();
      });

      print(
        "✅ Prediction: $detectedSound (${(confidence * 100).toStringAsFixed(1)}%)",
      );
    } catch (e, stackTrace) {
      print("❌ Error: $e");
      print(stackTrace);
      setState(() {
        isRecording = false;
        isProcessing = false;
        errorMessage = e.toString();
        detectedSound = "Error";
        confidence = 0.0;
      });
    }
  }

  Future<void> toggleContinuousListening() async {
    if (_isStartingListening) return;
    if (isRecording) {
      await _stopContinuousListening();
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      setState(() {
        errorMessage =
            "Microphone recording is not supported on this platform.";
        detectedSound = "Error";
      });
      return;
    }

    _isStartingListening = true;
    try {
      final stream = await _audioService.startPcmStream(channels: 1);
      _rollingPcm.clear();
      _bytesSincePrediction = 0;
      _ignoreAudioUntil = DateTime.fromMillisecondsSinceEpoch(0);
      _predictionSmoother.reset();
      await _audioSubscription?.cancel();
      _audioSubscription = stream.listen(
        _handlePcmChunk,
        onError: _handleStreamError,
        onDone: _handleStreamDone,
        cancelOnError: true,
      );
      if (!mounted) return;
      setState(() {
        isRecording = true;
        isProcessing = false;
        errorMessage = "";
        detectedSound = "Listening...";
        confidence = 0.0;
      });
    } catch (error, stackTrace) {
      print("Could not start continuous listening: $error");
      print(stackTrace);
      if (!mounted) return;
      setState(() {
        isRecording = false;
        isProcessing = false;
        errorMessage = error.toString();
        detectedSound = "Error";
      });
    } finally {
      _isStartingListening = false;
    }
  }

  void _handlePcmChunk(Uint8List chunk) {
    if (!isRecording || chunk.isEmpty) return;
    if (DateTime.now().isBefore(_ignoreAudioUntil)) {
      _rollingPcm.clear();
      _bytesSincePrediction = 0;
      return;
    }
    _rollingPcm.addAll(chunk);
    _bytesSincePrediction += chunk.length;
    if (_rollingPcm.length > _windowBytes) {
      _rollingPcm.removeRange(0, _rollingPcm.length - _windowBytes);
    }
    if (_rollingPcm.length == _windowBytes &&
        _bytesSincePrediction >= _predictionHopBytes &&
        !isProcessing) {
      _bytesSincePrediction = 0;
      _predictContinuousWindow(List<int>.from(_rollingPcm));
    }
  }

  Future<void> _predictContinuousWindow(List<int> pcmWindow) async {
    if (!mounted || !isRecording || isProcessing) return;
    setState(() => isProcessing = true);
    try {
      final result = await _edgeAiService.predict(
        AudioService.pcm16ToWav(pcmWindow),
      );
      if (!mounted || !isRecording) return;
      final label = result["label"] ?? "Unknown";
      final score = (result["confidence"] ?? 0.0).toDouble();
      final normalizedLabel = label.toString().toLowerCase();
      final accepted =
          _preferences.enabledLabels.contains(normalizedLabel) &&
          score >= _preferences.minimumConfidence;
      final decision = _predictionSmoother.update(
        accepted ? normalizedLabel : 'unknown',
        accepted ? score : 0.0,
      );
      if (!decision.shouldUpdate) {
        if (mounted) setState(() => confidence = score);
        return;
      }
      setState(() {
        detectedSound = decision.label;
        confidence = score;
        errorMessage = "";
      });
      _showCriticalAlert(decision.label, score);
      print(
        "Continuous $_aiEngine prediction: $label "
        "(${(score * 100).toStringAsFixed(1)}%)",
      );
    } catch (error, stackTrace) {
      print("Continuous inference error: $error");
      print(stackTrace);
      if (mounted) setState(() => errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => isProcessing = false);
    }
  }

  void _showCriticalAlert(String label, double score) {
    final alert = _SoundAlert.fromPrediction(label, score);
    if (!mounted) return;
    if (alert == null) {
      _dismissAlert();
      return;
    }

    // Exclude the phone's own vibration from subsequent inference windows.
    _ignoreAudioUntil = DateTime.now().add(const Duration(seconds: 2));
    _rollingPcm.clear();
    _bytesSincePrediction = 0;
    _alertDismissTimer?.cancel();
    _alertDismissTimer = Timer(
      Duration(seconds: _preferences.alertDurationSeconds),
      _dismissAlert,
    );
    setState(() => _activeAlert = alert);
    _recordAlert(label, alert);
    _triggerNativeAlert(alert);
  }

  Future<void> _recordAlert(String label, _SoundAlert alert) async {
    try {
      final entries = await _historyService.add(
        AlertHistoryEntry(
          label: label,
          displayName: alert.displayName,
          confidence: alert.confidence,
          urgency: alert.urgency.name,
          detectedAt: DateTime.now(),
        ),
      );
      if (mounted) setState(() => _alertHistory = entries);
    } catch (error) {
      debugPrint('Could not save alert history: $error');
    }
  }

  Future<void> _triggerNativeAlert(_SoundAlert alert) async {
    if (!Platform.isAndroid) return;
    try {
      await _alertChannel.invokeMethod<void>('triggerAlert', {
        'urgency': alert.urgency.name,
        'vibrationEnabled': _preferences.vibrationEnabled,
        'flashEnabled': _preferences.flashEnabled,
      });
    } on PlatformException catch (error) {
      print("Native alert effect failed: ${error.message}");
    } on MissingPluginException {
      print("Native alert effects are unavailable on this platform.");
    }
  }

  void _dismissAlert() {
    _alertDismissTimer?.cancel();
    _alertDismissTimer = null;
    if (mounted && _activeAlert != null) setState(() => _activeAlert = null);
  }

  Future<void> _stopContinuousListening() async {
    if (mounted) {
      setState(() {
        isRecording = false;
        isProcessing = false;
        detectedSound = "Listening stopped";
      });
    }
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _audioService.stopPcmStream();
    _rollingPcm.clear();
    _bytesSincePrediction = 0;
  }

  void _handleStreamError(Object error, StackTrace stackTrace) {
    print("Audio stream error: $error");
    if (!mounted) return;
    setState(() {
      isRecording = false;
      isProcessing = false;
      errorMessage = error.toString();
      detectedSound = "Error";
    });
  }

  void _handleStreamDone() {
    if (!mounted || !isRecording) return;
    setState(() {
      isRecording = false;
      isProcessing = false;
      detectedSound = "Listening stopped";
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'SMART EAR',
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.w900,
            fontSize: 18,
            color: Color(0xFF00E5FF),
          ),
        ),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 20),
                if (_dashboardMode == _DashboardMode.soundAlerts) ...[
                  Center(child: _buildRadarDisplay()),
                  const SizedBox(height: 20),
                  _buildMetricsSection(),
                  _recordButton(),
                ] else if (_dashboardMode == _DashboardMode.history) ...[
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height - 150,
                    child: HistoryScreen(
                      entries: _alertHistory,
                      onClear: _clearHistory,
                    ),
                  ),
                ] else ...[
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height - 150,
                    child: SettingsScreen(
                      preferences: _preferences,
                      onChanged: _updatePreferences,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_activeAlert != null)
            Positioned.fill(child: _buildFullScreenAlert(_activeAlert!)),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildFullScreenAlert(_SoundAlert alert) {
    return Material(
      color: alert.color.withValues(alpha: 0.97),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${alert.urgency.displayName.toUpperCase()} PRIORITY',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss alert',
                    onPressed: _dismissAlert,
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 32,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: alert.iconPath == null
                    ? Icon(alert.fallbackIcon, color: alert.color, size: 100)
                    : _buildFlaticonIcon(
                        alert.iconPath!,
                        color: alert.color,
                        size: 110,
                        fallback: alert.fallbackIcon,
                      ),
              ),
              const SizedBox(height: 36),
              const Text(
                'CRITICAL SOUND DETECTED',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                alert.displayName.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 36,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '${(alert.confidence * 100).toStringAsFixed(1)}% confidence',
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: FilledButton(
                  onPressed: _dismissAlert,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: alert.color,
                  ),
                  child: const Text(
                    'DISMISS',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRadarDisplay() {
    return SizedBox(
      width: 300,
      height: 300,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background Rings
          for (var i = 1; i <= 3; i++)
            Container(
              width: 100.0 * i,
              height: 100.0 * i,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.03)),
              ),
            ),

          // This is an activity display, not a sound-direction indicator.
          const Positioned(
            top: 6,
            child: Text(
              'SOUND MONITOR',
              style: TextStyle(
                color: Color(0xFFBAC9CD),
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          //         // Animated Pulse
          //         // _RadarPulseRing(animation: _pulseController),

          //         // The Glass Radar Face
          //         Container(
          //           width: 240,
          //           height: 240,
          //           decoration: BoxDecoration(
          //             shape: BoxShape.circle,
          //             gradient: RadialGradient(
          //               colors: [
          //                 const Color(0xFF00E5FF).withOpacity(0.05),
          //                 Colors.transparent,
          //               ],
          //             ),
          //             border: Border.all(color: Colors.white10),
          //           ),
          //         ),

          // CENTER ICON
          // ScaleTransition(
          //   scale: isRecording
          //       ? Tween(begin: 1.0, end: 1.2).animate(_recordingController)
          //       : AlwaysStoppedAnimation(1.0),
          //   child: Container(
          //     padding: const EdgeInsets.all(20),
          //     decoration: BoxDecoration(
          //       shape: BoxShape.circle,
          //       color: const Color(0xFF1A1A1C),
          //       boxShadow: [
          //         BoxShadow(
          //           color: isRecording
          //               ? const Color(0xFFFF5252).withOpacity(0.5)
          //               : const Color(0xFF00E5FF).withOpacity(0.1),
          //           blurRadius: 20,
          //           spreadRadius: 5,
          //         ),
          //       ],
          //     ),
          //     child: Icon(
          //       isRecording ? Icons.mic : Icons.sensors,
          //       color: isRecording
          //           ? const Color(0xFFFF5252)
          //           : const Color(0xFF00E5FF),
          //       size: 40,
          //     ),
          //   ),
          // ),

          // THE DIRECTIONAL ARROW
          // RotationTransition(
          //   turns: _arrowController,
          //   child: SizedBox(
          //     width: 200,
          //     height: 200,
          //     child: Stack(
          //       children: [
          //         Align(
          //           alignment: Alignment.topCenter,
          //           child: Column(
          //             children: [
          //               const Icon(
          //                 Icons.navigation,
          //                 color: Color(0xFF00E5FF),
          //                 size: 30,
          //               ),
          //               Container(
          //                 width: 2,
          //                 height: 40,
          //                 decoration: BoxDecoration(
          //                   gradient: LinearGradient(
          //                     begin: Alignment.topCenter,
          //                     end: Alignment.bottomCenter,
          //                     colors: [
          //                       const Color(0xFF00E5FF),
          //                       const Color(0xFF00E5FF).withOpacity(0),
          //                     ],
          //                   ),
          //                 ),
          //               ),
          //             ],
          //           ),
          //         ),
          //       ],
          //     ),
          //   ),
          // ),

          // Recording Countdown
          // if (isRecording)
          //   Center(
          //     child: Text(
          //       recordingCountdown.toString(),
          //       style: const TextStyle(
          //         fontSize: 48,
          //         fontWeight: FontWeight.bold,
          //         color: Color(0xFFFF5252),
          //       ),
          //     ),
          //   ),

          // Detected Sound Icon
          if (detectedSound == "siren")
            Center(
              child: _buildFlaticonIcon(
                'assets/icons/Icons/alarm.png',
                color: const Color(0xFFFF5252),
                size: 120,
                fallback: Icons.warning_amber,
              ),
            )
          else if (detectedSound == "crying_baby" ||
              detectedSound == "baby_crying")
            Center(
              child: _buildFlaticonIcon(
                'assets/icons/Icons/baby.png',
                color: const Color.fromARGB(143, 255, 82, 82),
                size: 120,
                fallback: Icons.baby_changing_station,
              ),
            )
          else if (detectedSound == "door_wood_knock" ||
              detectedSound == "door_knocking")
            Center(
              child: _buildFlaticonIcon(
                'assets/icons/Icons/door.png',
                color: const Color(0xFF00E5FF),
                size: 120,
                fallback: Icons.door_back_door,
              ),
            )
          else if (detectedSound == "glass_breaking")
            Center(
              child: _buildFlaticonIcon(
                'assets/icons/Icons/broken-glass.png',
                color: const Color(0xFFFFD54F),
                size: 120,
                fallback: Icons.wine_bar,
              ),
            )
          else if (detectedSound == "car_horn")
            const Center(
              child: Icon(
                Icons.directions_car,
                color: Color(0xFFFFD54F),
                size: 80,
              ),
            )
          else
            Center(
              child: Icon(
                isRecording ? Icons.graphic_eq : Icons.hearing,
                color: isRecording ? const Color(0xFF00E5FF) : Colors.white24,
                size: 88,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFlaticonIcon(
    String imagePath, {
    required Color color,
    required double size,
    required IconData fallback,
  }) {
    Widget fallbackIcon(
      BuildContext context,
      Object error,
      StackTrace? stackTrace,
    ) {
      return Icon(fallback, color: color, size: size);
    }

    if (imagePath.startsWith('http')) {
      return Image.network(
        imagePath,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: fallbackIcon,
      );
    }

    return Image.asset(
      imagePath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      errorBuilder: fallbackIcon,
    );
  }

  //record button
  Widget _recordButton() {
    return SizedBox(
      width: 80,
      height: 80,
      child: ScaleTransition(
        scale: isRecording
            ? Tween<double>(begin: 1.0, end: 1.2).animate(_recordingController)
            : const AlwaysStoppedAnimation<double>(1.0),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF1A1A1C),
            boxShadow: [
              BoxShadow(
                color: isRecording
                    ? const Color(0xFFFF5252).withOpacity(0.5)
                    : const Color(0xFF00E5FF).withOpacity(0.1),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: _isStartingListening ? null : toggleContinuousListening,
            style: ElevatedButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
              backgroundColor: (isRecording || isProcessing)
                  ? Colors.grey
                  : const Color(0xFF00E5FF),
            ),
            child: isRecording
                ? const Icon(Icons.stop, color: Colors.black, size: 40)
                : isProcessing
                ? const Text(
                    'Processing...',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : const Icon(Icons.mic, color: Colors.black, size: 40),
          ),
        ),
      ),
    );
  }

  Widget _buildMetricsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // const Text(
          //   "LIVE SPECTRUM",
          //   style: TextStyle(
          //     fontSize: 12,
          //     fontWeight: FontWeight.bold,
          //     letterSpacing: 1.5,
          //     color: Colors.white38,
          //   ),
          // ),
          // const SizedBox(height: 16),
          // _buildFrequencyBar(),
          const SizedBox(height: 15),
          _buildCriticalAlert(),
          const SizedBox(height: 15),
          if (errorMessage.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFF5252).withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFF5252)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      errorMessage,
                      style: const TextStyle(
                        color: Color(0xFFFF8A80),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _requestPermissionsAndInit,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          // SizedBox(
          //   width: double.infinity,
          //   child: ElevatedButton(
          //     onPressed: (isRecording || isProcessing)
          //         ? null
          //         : recordAndPredict,
          //     style: ElevatedButton.styleFrom(
          //       backgroundColor: (isRecording || isProcessing)
          //           ? Colors.grey
          //           : const Color(0xFF00E5FF),
          //       shape: RoundedRectangleBorder(
          //         borderRadius: BorderRadius.circular(16),
          //       ),
          //       padding: const EdgeInsets.symmetric(
          //         horizontal: 24,
          //         vertical: 16,
          //       ),
          //     ),
          // child: Text(
          //   isRecording
          //       ? '$recordingCountdown'
          //       : isProcessing
          //       ? "Processing..."
          //       : "Start Recording",
          //   style: const TextStyle(
          //     color: Colors.black,
          //     fontWeight: FontWeight.bold,
          //   ),
          // ),
          //         ),
          //       ),
          //       const SizedBox(height: 24),
        ],
      ),
    );
  }

  // Widget _buildFrequencyBar() {
  //   return Container(
  //     padding: const EdgeInsets.all(20),
  //     decoration: BoxDecoration(
  //       color: const Color(0xFF1A1A1C),
  //       borderRadius: BorderRadius.circular(24),
  //     ),
  //     child: Row(
  //       mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //       crossAxisAlignment: CrossAxisAlignment.end,
  //       children: List.generate(20, (index) {
  //         return Container(
  //           width: 6,
  //           height: 10.0 + math.Random().nextInt(40),
  //           decoration: BoxDecoration(
  //             color: index > 14
  //                 ? const Color(0xFFFF5252)
  //                 : const Color(0xFF00E5FF),
  //             borderRadius: BorderRadius.circular(10),
  //           ),
  //         );
  //       }),
  //     ),
  //   );
  // }

  Widget _buildCriticalAlert() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF5252).withOpacity(0.2),
            const Color(0xFF1A1A1C),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFFF5252).withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFFF5252),
            child: Icon(Icons.warning_amber_rounded, color: Colors.white),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detectedSound.toUpperCase(),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'Confidence: ${(confidence * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Text(
                  isRecording
                      ? "Status: Live monitoring"
                      : "Status: Monitoring stopped",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white24),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      margin: const EdgeInsets.all(24),
      height: 70,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1C),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Sound alerts',
            onPressed: () => _setDashboardMode(_DashboardMode.soundAlerts),
            icon: Icon(
              Icons.radar,
              color: _dashboardMode == _DashboardMode.soundAlerts
                  ? const Color(0xFF00E5FF)
                  : Colors.white24,
            ),
          ),
          IconButton(
            tooltip: 'Alert history',
            onPressed: () => _setDashboardMode(_DashboardMode.history),
            icon: Icon(
              Icons.history,
              color: _dashboardMode == _DashboardMode.history
                  ? const Color(0xFF00E5FF)
                  : Colors.white24,
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => _setDashboardMode(_DashboardMode.settings),
            icon: Icon(
              Icons.settings_outlined,
              color: _dashboardMode == _DashboardMode.settings
                  ? const Color(0xFF00E5FF)
                  : Colors.white24,
            ),
          ),
        ],
      ),
    );
  }
}

enum _DashboardMode { soundAlerts, history, settings }

enum _AlertUrgency {
  high('High'),
  medium('Medium'),
  low('Low');

  const _AlertUrgency(this.displayName);
  final String displayName;
}

class _SoundAlert {
  const _SoundAlert({
    required this.displayName,
    required this.confidence,
    required this.urgency,
    required this.color,
    required this.fallbackIcon,
    this.iconPath,
  });

  final String displayName;
  final double confidence;
  final _AlertUrgency urgency;
  final Color color;
  final IconData fallbackIcon;
  final String? iconPath;

  static _SoundAlert? fromPrediction(String label, double confidence) {
    switch (label.toLowerCase()) {
      case 'siren':
        return _SoundAlert(
          displayName: 'Emergency Siren',
          confidence: confidence,
          urgency: _AlertUrgency.high,
          color: const Color(0xFFD32F2F),
          fallbackIcon: Icons.warning_amber_rounded,
          iconPath: 'assets/icons/Icons/alarm.png',
        );
      case 'glass_breaking':
        return _SoundAlert(
          displayName: 'Glass Breaking',
          confidence: confidence,
          urgency: _AlertUrgency.high,
          color: const Color(0xFFD32F2F),
          fallbackIcon: Icons.broken_image_rounded,
          iconPath: 'assets/icons/Icons/broken-glass.png',
        );
      case 'car_horn':
        return _SoundAlert(
          displayName: 'Car Horn',
          confidence: confidence,
          urgency: _AlertUrgency.high,
          color: const Color(0xFFD32F2F),
          fallbackIcon: Icons.directions_car_rounded,
        );
      case 'baby_crying':
      case 'crying_baby':
        return _SoundAlert(
          displayName: 'Baby Crying',
          confidence: confidence,
          urgency: _AlertUrgency.medium,
          color: const Color(0xFFF57C00),
          fallbackIcon: Icons.baby_changing_station,
          iconPath: 'assets/icons/Icons/baby.png',
        );
      case 'door_knocking':
      case 'door_wood_knock':
        return _SoundAlert(
          displayName: 'Door Knocking',
          confidence: confidence,
          urgency: _AlertUrgency.low,
          color: const Color(0xFF00838F),
          fallbackIcon: Icons.door_front_door_rounded,
          iconPath: 'assets/icons/Icons/door.png',
        );
      default:
        return null;
    }
  }
}
