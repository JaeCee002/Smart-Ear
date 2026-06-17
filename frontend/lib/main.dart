import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'services/api_services.dart';
import 'services/audio_service.dart';

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
  late AnimationController _pulseController;
  late AnimationController _recordingController;

  final AudioService _audioService = AudioService();
  String detectedSound = "Listening...";
  double confidence = 0.0;
  bool isRecording = false;
  bool isProcessing = false;
  int recordingCountdown = 5;
  String errorMessage = "";

  @override
  void initState() {
    super.initState();
    _arrowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

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
    }
  }

  @override
  void dispose() {
    _arrowController.dispose();
    _pulseController.dispose();
    _recordingController.dispose();
    _audioService.dispose();
    super.dispose();
  }

  /// Record audio for 5 seconds and get prediction
  Future<void> recordAndPredict() async {
    if (isRecording || isProcessing) return;

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

      // Send audio to backend
      print("📤 Sending audio to backend for prediction...");
      final result = await ApiService.getPredictionWithAudio(audioBytes);

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
    } catch (e) {
      print("❌ Error: $e");
      setState(() {
        isRecording = false;
        isProcessing = false;
        errorMessage = e.toString();
        detectedSound = "Error";
        confidence = 0.0;
      });
    }
  }

  /// Animate arrow direction based on detected sound
  void _animateArrowForSound(String sound) {
    // Map sounds to directions (0.0 = North, 0.25 = East, 0.5 = South, 0.75 = West)
    double direction = 0.0;

    switch (sound.toLowerCase()) {
      case "dog":
        direction = 0.0; // North
        break;
      case "rain":
        direction = 0.25; // East
        break;
      case "crying_baby":
        direction = 0.5; // South
        break;
      case "door_wood_knock":
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
            const SizedBox(height: 40),
            _buildMetricsSection(),
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
            top: 8,
            child: Text(
              'N',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
            ),
          ),
          const Positioned(
            bottom: 8,
            child: Text(
              'S',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
            ),
          ),
          const Positioned(
            left: 8,
            child: Text(
              'W',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
            ),
          ),
          const Positioned(
            right: 8,
            child: Text(
              'E',
              style: TextStyle(color: Color(0xFFBAC9CD), fontSize: 10),
            ),
          ),

          // Animated Pulse
          _RadarPulseRing(animation: _pulseController),

          // The Glass Radar Face
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF00E5FF).withOpacity(0.05),
                  Colors.transparent,
                ],
              ),
              border: Border.all(color: Colors.white10),
            ),
          ),

          // CENTER ICON
          ScaleTransition(
            scale: isRecording
                ? Tween(begin: 1.0, end: 1.2).animate(_recordingController)
                : AlwaysStoppedAnimation(1.0),
            child: Container(
              padding: const EdgeInsets.all(20),
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
              child: Icon(
                isRecording ? Icons.mic : Icons.sensors,
                color: isRecording
                    ? const Color(0xFFFF5252)
                    : const Color(0xFF00E5FF),
                size: 40,
              ),
            ),
          ),

          // THE DIRECTIONAL ARROW
          RotationTransition(
            turns: _arrowController,
            child: SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: Column(
                      children: [
                        const Icon(
                          Icons.navigation,
                          color: Color(0xFF00E5FF),
                          size: 30,
                        ),
                        Container(
                          width: 2,
                          height: 40,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                const Color(0xFF00E5FF),
                                const Color(0xFF00E5FF).withOpacity(0),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

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
          if (detectedSound == "dog")
            Center(child: Icon(Icons.pets, color: Color(0xFFFF5252), size: 30))
          else if (detectedSound == "rain")
            Center(child: Icon(Icons.grain, color: Color(0xFF00E5FF), size: 30))
          else if (detectedSound == "crying_baby")
            Center(
              child: Icon(
                Icons.baby_changing_station,
                color: Color(0xFFFF5252),
                size: 30,
              ),
            )
          else if (detectedSound == "door_wood_knock")
            Center(
              child: Icon(
                Icons.door_back_door,
                color: Color(0xFF00E5FF),
                size: 30,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMetricsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "LIVE SPECTRUM",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 16),
          _buildFrequencyBar(),
          const SizedBox(height: 24),
          _buildCriticalAlert(),
          const SizedBox(height: 24),
          if (errorMessage.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
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
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (isRecording || isProcessing)
                  ? null
                  : recordAndPredict,
              style: ElevatedButton.styleFrom(
                backgroundColor: (isRecording || isProcessing)
                    ? Colors.grey
                    : const Color(0xFF00E5FF),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
              child: Text(
                isRecording
                    ? "Recording... $recordingCountdown"
                    : isProcessing
                    ? "Processing..."
                    : "Start Recording",
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildFrequencyBar() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1C),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(20, (index) {
          return Container(
            width: 6,
            height: 10.0 + math.Random().nextInt(40),
            decoration: BoxDecoration(
              color: index > 14
                  ? const Color(0xFFFF5252)
                  : const Color(0xFF00E5FF),
              borderRadius: BorderRadius.circular(10),
            ),
          );
        }),
      ),
    );
  }

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

class _RadarPulseRing extends StatelessWidget {
  final Animation<double> animation;
  const _RadarPulseRing({required this.animation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Opacity(
          opacity: (1.0 - animation.value),
          child: Container(
            width: 280 * animation.value,
            height: 280 * animation.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF00E5FF).withOpacity(0.3),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}
