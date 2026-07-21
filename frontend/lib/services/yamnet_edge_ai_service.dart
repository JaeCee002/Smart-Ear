import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'edge_ai_service.dart';

class YamnetEdgeAiService implements SoundInferenceService {
  static const double _maximumOperationalThreshold = 0.80;
  static const int _sampleRate = 16000;
  static const int _inputSeconds = 5;
  static const int _inputSamples = _sampleRate * _inputSeconds;
  static const int _frameSamples = 15360; // 0.96 seconds at 16 kHz.
  static const int _hopSamples = 7680; // 0.48 seconds at 16 kHz.
  static const int _spectrogramFrameCount = 96;
  static const int _spectrogramFrameHop = 48;

  Interpreter? _yamnet;
  Interpreter? _head;
  List<String> _labels = const [];
  Map<String, double> _thresholds = const {};

  @override
  Future<void> initialize() async {
    if (_yamnet != null && _head != null) return;
    final metadata =
        jsonDecode(
              await rootBundle.loadString(
                'assets/models/yamnet_model_metadata.json',
              ),
            )
            as Map<String, dynamic>;
    _labels = (metadata['labels'] as List<dynamic>).cast<String>();
    _thresholds = (metadata['thresholds'] as Map<String, dynamic>).map(
      (label, value) => MapEntry(label, (value as num).toDouble()),
    );
    _yamnet = await Interpreter.fromAsset(
      'assets/models/yamnet.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    _head = await Interpreter.fromAsset(
      'assets/models/smart_ear_yamnet_head.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    _head!.allocateTensors();
    if (!_sameShape(_head!.getInputTensor(0).shape, [1, 1024]) ||
        !_sameShape(_head!.getOutputTensor(0).shape, [1, _labels.length])) {
      dispose();
      throw StateError('Unexpected YAMNet classifier head tensor shapes.');
    }
  }

  @override
  Future<Map<String, dynamic>> predict(List<int> wavBytes) async {
    await initialize();
    final decodedSamples = WavDecoder.decodeMono16k(wavBytes);
    final samples = _normalizeInput(decodedSamples);
    final peak = samples.fold<double>(
      0,
      (current, sample) => math.max(current, sample.abs()),
    );
    if (peak < 0.01) return {'label': 'silence', 'confidence': 0.0};

    _yamnet!.resizeInputTensor(0, [samples.length]);
    _yamnet!.allocateTensors();
    final tensors = _yamnet!.getOutputTensors();
    int? embeddingIndex;
    final outputs = <int, Object>{};
    for (var index = 0; index < tensors.length; index++) {
      final shape = tensors[index].shape;
      if (shape.isNotEmpty && shape.last == 1024) embeddingIndex = index;
      outputs[index] = _zeros(_yamnetOutputShape(shape, samples.length));
    }
    if (embeddingIndex == null) {
      throw StateError('YAMNet embedding output is missing.');
    }
    _yamnet!.runForMultipleInputs([samples], outputs);

    final embeddingOutput = outputs[embeddingIndex];
    if (embeddingOutput is! List<dynamic>) {
      throw StateError('YAMNet returned an invalid embedding output.');
    }
    final frames = embeddingOutput.cast<List<dynamic>>();
    if (frames.isEmpty) throw StateError('YAMNet returned no audio frames.');
    final embedding = List<double>.filled(1024, 0);
    for (final frame in frames) {
      for (var feature = 0; feature < embedding.length; feature++) {
        embedding[feature] += (frame[feature] as num).toDouble();
      }
    }
    for (var feature = 0; feature < embedding.length; feature++) {
      embedding[feature] /= frames.length;
    }

    final output = [List<double>.filled(_labels.length, 0)];
    _head!.run([embedding], output);
    final probabilities = <String, double>{
      for (var i = 0; i < _labels.length; i++) _labels[i]: output[0][i],
    };

    String? selected;
    var selectedConfidence = 0.0;
    var selectedMargin = double.negativeInfinity;
    for (final entry in probabilities.entries) {
      final trainedThreshold = _thresholds[entry.key] ?? 0.5;
      final operationalThreshold = math.min(
        trainedThreshold,
        _maximumOperationalThreshold,
      );
      final margin = entry.value - operationalThreshold;
      if (margin >= 0 && margin > selectedMargin) {
        selected = entry.key;
        selectedConfidence = entry.value;
        selectedMargin = margin;
      }
    }
    if (selected == null) {
      final best = probabilities.entries.reduce(
        (left, right) => left.value >= right.value ? left : right,
      );
      return {
        'label': 'unknown',
        'confidence': best.value,
        'probabilities': probabilities,
      };
    }
    return {
      'label': selected,
      'confidence': selectedConfidence,
      'probabilities': probabilities,
    };
  }

  @override
  void dispose() {
    _yamnet?.close();
    _head?.close();
    _yamnet = null;
    _head = null;
  }

  static Object _zeros(List<int> shape) {
    Object build(int dimension) {
      if (dimension == shape.length - 1) {
        return List<double>.filled(shape[dimension], 0);
      }
      return List.generate(shape[dimension], (_) => build(dimension + 1));
    }

    return build(0);
  }

  static int _yamnetFrameCount(int sampleCount) {
    if (sampleCount <= _frameSamples) return 1;
    return ((sampleCount - _frameSamples + _hopSamples - 1) ~/ _hopSamples) + 1;
  }

  static int frameCountForTest(int sampleCount) =>
      _yamnetFrameCount(sampleCount);

  static List<double> normalizeInputForTest(List<double> samples) =>
      _normalizeInput(samples);

  static List<double> _normalizeInput(List<double> samples) {
    if (samples.length == _inputSamples) return samples;
    final normalized = List<double>.filled(_inputSamples, 0);
    final copyLength = math.min(samples.length, normalized.length);
    normalized.setRange(0, copyLength, samples);
    return normalized;
  }

  static List<int> outputShapeForTest(List<int> shape, int sampleCount) =>
      _yamnetOutputShape(shape, sampleCount);

  static List<int> _yamnetOutputShape(List<int> shape, int sampleCount) {
    if (shape.length != 2) return shape;
    switch (shape.last) {
      case 521:
      case 1024:
        return [_yamnetFrameCount(sampleCount), shape.last];
      case 64:
        final patchCount = _yamnetFrameCount(sampleCount);
        return [
          _spectrogramFrameCount + ((patchCount - 1) * _spectrogramFrameHop),
          shape.last,
        ];
      default:
        return shape;
    }
  }

  static bool _sameShape(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }
}
