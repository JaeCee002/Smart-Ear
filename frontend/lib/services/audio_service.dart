import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:typed_data';
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

  /// Camera permission is optional and is only used for torch alerts.
  Future<bool> requestCameraPermission() async {
    if (!Platform.isAndroid) return false;
    final status = await Permission.camera.request();
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

  Future<Stream<Uint8List>> startPcmStream({int channels = 1}) async {
    if (!isSupportedPlatform) {
      throw UnsupportedError("Recording is not supported on this platform.");
    }
    if (!await _audioRecorder.hasPermission()) {
      throw Exception("Microphone permission denied");
    }
    return _audioRecorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
      ),
    );
  }

  Future<void> stopPcmStream() async {
    await _audioRecorder.stop();
  }

  static Uint8List pcm16ToWav(List<int> pcmBytes) {
    final wav = Uint8List(44 + pcmBytes.length);
    final data = ByteData.sublistView(wav);

    void writeAscii(int offset, String value) {
      wav.setRange(offset, offset + value.length, value.codeUnits);
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, wav.length - 8, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * channels * 2, Endian.little);
    data.setUint16(32, channels * 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, pcmBytes.length, Endian.little);
    wav.setRange(44, wav.length, pcmBytes);
    return wav;
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
