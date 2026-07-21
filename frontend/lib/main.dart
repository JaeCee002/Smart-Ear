import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'services/audio_service.dart';
import 'services/edge_ai_service.dart';
import 'services/yamnet_edge_ai_service.dart';

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
  late AnimationController _arrowController;
  //late AnimationController _pulseController;
  late AnimationController _recordingController;

  final AudioService _audioService = AudioService();
  static const String _aiEngine = String.fromEnvironment(
    'SMART_EAR_AI_ENGINE',
    defaultValue: 'legacy',
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
  static const int _pcmBytesPerSecond = AudioService.sampleRate * 2;
  static const int _windowBytes =
      AudioService.durationSeconds * _pcmBytesPerSecond;
  static const int _predictionHopBytes = 2 * _pcmBytesPerSecond;
  int recordingCountdown = 5;
  String errorMessage = "";

  @override
  void initState() {
    super.initState();
    _arrowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    // _pulseController = AnimationController(
    //   vsync: this,
    //   duration: const Duration(seconds: 3),
    // )..repeat();

    _recordingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);

    _requestPermissionsAndInit();
  }

  Future<void> _requestPermissionsAndInit() async {
    final granted = await _audioService.requestMicrophonePermission();
    if (!granted) {
      setState(() {
        errorMessage = "Microphone permission denied";
      });
      return;
    }
    try {
      await _edgeAiService.initialize();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        errorMessage = "Could not load the on-device sound model: $error";
      });
    }
  }

  @override
  void dispose() {
    _audioSubscription?.cancel();
    _audioService.stopPcmStream();
    _arrowController.dispose();
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

      // Animate arrow based on detected sound
      _animateArrowForSound(detectedSound);
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
      final stream = await _audioService.startPcmStream();
      _rollingPcm.clear();
      _bytesSincePrediction = 0;
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
      setState(() {
        detectedSound = label;
        confidence = score;
        errorMessage = "";
      });
      _animateArrowForSound(label);
      print(
        "Continuous prediction: $label "
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

  /// Animate arrow direction based on detected sound
  void _animateArrowForSound(String sound) {
    // Map sounds to directions (0.0 = North, 0.25 = East, 0.5 = South, 0.75 = West)
    double direction = 0.0;

    switch (sound.toLowerCase()) {
      case "siren":
        direction = 0.0; // North
        break;
      case "crying_baby":
      case "baby_crying":
        direction = 0.25; // East
        break;
      case "door_wood_knock":
      case "door_knocking":
        direction = 0.5; // South
        break;
      case "glass_breaking":
        direction = 0.75; // West
        break;
      default:
        direction = 0.125; // North-East (default)
    }

    _arrowController.animateTo(
      direction,
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
    );
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
        actions: [
          IconButton(
            icon: const Icon(Icons.grid_view_rounded, color: Colors.white54),
            onPressed: () {},
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 20),
            Center(child: _buildRadarDisplay()),
            const SizedBox(height: 20),
            _buildMetricsSection(),
            _recordButton(),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
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

          // DIRECTIONS
          const Positioned(
            top: 6,
            child: Text(
              'N',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
            ),
          ),
          const Positioned(
            bottom: 6,
            child: Text(
              'S',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
            ),
          ),
          const Positioned(
            left: 6,
            child: Text(
              'W',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
            ),
          ),
          const Positioned(
            right: 6,
            child: Text(
              'E',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
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
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFFFF5252).withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFF5252)),
              ),
              child: Text(
                errorMessage,
                style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12),
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
                const Text(
                  "Status: Live Monitoring",
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
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Icon(Icons.radar, color: Color(0xFF00E5FF)),
          Icon(Icons.history, color: Colors.white24),
          Icon(Icons.settings_outlined, color: Colors.white24),
        ],
      ),
    );
  }
}
