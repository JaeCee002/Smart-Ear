import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String BASE_URL = 'http://10.79.144.90:8000';

  /// Get prediction from backend with audio file
  /// Audio should be WAV file bytes (mono, 16kHz, 5 seconds)
  static Future<Map<String, dynamic>> getPredictionWithAudio(
    List<int> audioBytes,
  ) async {
    try {
      // Create multipart request
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$BASE_URL/predict'),
      );

      // Add audio file to request
      request.files.add(
        http.MultipartFile.fromBytes('file', audioBytes, filename: 'audio.wav'),
      );

      // Send request with 30-second timeout
      var streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Request timeout after 60s');
        },
      );

      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        print("❌ Server error: ${response.statusCode}");
        print("Response: ${response.body}");
        return {"label": "error", "confidence": 0.0};
      }
    } catch (e, st) {
      print("❌ Network error when calling $BASE_URL/predict: $e");
      print(st);
      return {"label": "error", "confidence": 0.0};
    }
  }

  /// Legacy: Get prediction without audio (for backward compatibility)
  @deprecated
  static Future<Map<String, dynamic>> getPrediction() async {
    final response = await http.get(Uri.parse('$BASE_URL/predict-legacy'));

    return jsonDecode(response.body);
  }
}
