import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class AudioService {
  static final AudioService _instance = AudioService._internal();
  final AudioRecorder _audioRecorder = AudioRecorder();

  factory AudioService() {
    return _instance;
  }

  AudioService._internal();

  // Match backend settings
  static const int sampleRate = 16000;
  static const int durationSeconds = 5;
  static const int channels = 1;

  bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Request microphone permission
  Future<bool> requestMicrophonePermission() async {
    if (!isSupportedPlatform) {
      print("❌ Microphone recording is not supported on this platform.");
      return false;
    }

    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// Check if recording is supported
  Future<bool> isRecordingSupported() async {
    try {
      if (!isSupportedPlatform) {
        return false;
      }

      return await _audioRecorder.hasPermission();
    } catch (e) {
      print("❌ Permission check failed: $e");
      return false;
    }
  }

  /// Start recording
  Future<String?> startRecording() async {
    try {
      if (!isSupportedPlatform) {
        print("❌ Recording is not supported on this platform.");
        return null;
      }

      final hasPermission = await _audioRecorder.hasPermission();

      if (!hasPermission) {
        throw Exception("Microphone permission denied");
      }

      final directory = await getTemporaryDirectory();

      final filePath =
          '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: sampleRate,
          numChannels: channels,
        ),
        path: filePath,
      );

      print("🎤 Recording started");
      return filePath;
    } catch (e) {
      print("❌ Error starting recording: $e");
      return null;
    }
  }

  /// Stop recording and return WAV bytes
  Future<List<int>?> stopRecording() async {
    try {
      final path = await _audioRecorder.stop();

      if (path == null) {
        print("❌ No recording found");
        return null;
      }

      final file = File(path);

      if (!await file.exists()) {
        print("❌ Recording file does not exist");
        return null;
      }

      final bytes = await file.readAsBytes();

      // Remove temp file after reading
      await file.delete();

      print("✅ Recording stopped");
      print("📁 Audio size: ${bytes.length} bytes");

      return bytes;
    } catch (e) {
      print("❌ Error stopping recording: $e");
      return null;
    }
  }

  /// Get current microphone amplitude
  Future<double?> getAmplitude() async {
    try {
      final amplitude = await _audioRecorder.getAmplitude();
      return amplitude.current;
    } catch (e) {
      print("❌ Error getting amplitude: $e");
      return null;
    }
  }

  /// Check if recorder is currently recording
  Future<bool> isRecording() async {
    try {
      return await _audioRecorder.isRecording();
    } catch (e) {
      print("❌ Error checking recording state: $e");
      return false;
    }
  }

  /// Dispose recorder resources
  Future<void> dispose() async {
    await _audioRecorder.dispose();
  }
}
