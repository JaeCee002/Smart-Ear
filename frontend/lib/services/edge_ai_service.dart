import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

class EdgeAiService {
  static const int sampleRate = 16000;
  static const int melBands = 64;
  static const int targetFrames = 128;
  static const int fftSize = 2048;
  static const int hopLength = 512;
  static const double confidenceThreshold = 0.70;
  static const List<String> labels = [
    'siren',
    'crying_baby',
    'door_wood_knock',
    'glass_breaking',
  ];

  Interpreter? _interpreter;

  Future<void> initialize() async {
    if (_interpreter != null) return;
    _interpreter = await Interpreter.fromAsset(
      'assets/models/sound_model.tflite',
      options: InterpreterOptions()..threads = 2,
    );

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final outputShape = _interpreter!.getOutputTensor(0).shape;
    if (!_sameShape(inputShape, [1, melBands, targetFrames, 1]) ||
        !_sameShape(outputShape, [1, labels.length])) {
      dispose();
      throw StateError(
        'Unexpected model tensors: input=$inputShape, output=$outputShape',
      );
    }
  }

  Future<Map<String, dynamic>> predict(List<int> wavBytes) async {
    await initialize();
    final samples = WavDecoder.decodeMono16k(wavBytes);
    final peak = samples.fold<double>(
      0,
      (current, sample) => math.max(current, sample.abs()),
    );
    if (peak < 0.01) return {'label': 'silence', 'confidence': 0.0};

    final spectrogram = MelSpectrogram.extract(samples);
    final input = [
      List.generate(
        melBands,
        (mel) => List.generate(
          targetFrames,
          (frame) => [spectrogram[mel][frame]],
          growable: false,
        ),
        growable: false,
      ),
    ];
    final output = [List<double>.filled(labels.length, 0)];
    _interpreter!.run(input, output);

    var bestIndex = 0;
    for (var i = 1; i < labels.length; i++) {
      if (output[0][i] > output[0][bestIndex]) bestIndex = i;
    }
    final confidence = output[0][bestIndex];
    return {
      'label': confidence >= confidenceThreshold
          ? labels[bestIndex]
          : 'unknown',
      'confidence': confidence,
    };
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }

  static bool _sameShape(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }
}

class WavDecoder {
  static Float32List decodeMono16k(List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    if (data.length < 44 ||
        _ascii(data, 0, 4) != 'RIFF' ||
        _ascii(data, 8, 4) != 'WAVE') {
      throw const FormatException('Recording is not a valid WAV file.');
    }

    final view = ByteData.sublistView(data);
    var offset = 12;
    int? channels;
    int? rate;
    int? bits;
    int? format;
    int? audioOffset;
    int? audioLength;
    while (offset + 8 <= data.length) {
      final id = _ascii(data, offset, 4);
      final length = view.getUint32(offset + 4, Endian.little);
      final content = offset + 8;
      if (content + length > data.length) break;
      if (id == 'fmt ' && length >= 16) {
        format = view.getUint16(content, Endian.little);
        channels = view.getUint16(content + 2, Endian.little);
        rate = view.getUint32(content + 4, Endian.little);
        bits = view.getUint16(content + 14, Endian.little);
      } else if (id == 'data') {
        audioOffset = content;
        audioLength = length;
      }
      offset = content + length + (length.isOdd ? 1 : 0);
    }

    if (format != 1 ||
        bits != 16 ||
        channels == null ||
        channels < 1 ||
        audioOffset == null ||
        audioLength == null) {
      throw const FormatException(
        'Only 16-bit PCM WAV recordings are supported.',
      );
    }
    if (rate != EdgeAiService.sampleRate) {
      throw FormatException(
        'Expected ${EdgeAiService.sampleRate} Hz audio, received $rate Hz.',
      );
    }

    final frameCount = audioLength ~/ (channels * 2);
    final samples = Float32List(frameCount);
    for (var frame = 0; frame < frameCount; frame++) {
      var mixed = 0.0;
      for (var channel = 0; channel < channels; channel++) {
        final index = audioOffset + ((frame * channels + channel) * 2);
        mixed += view.getInt16(index, Endian.little) / 32768.0;
      }
      samples[frame] = mixed / channels;
    }
    return samples;
  }

  static String _ascii(Uint8List data, int offset, int length) =>
      String.fromCharCodes(data.sublist(offset, offset + length));
}

class MelSpectrogram {
  static List<Float32List> extract(Float32List samples) {
    if (samples.length <= EdgeAiService.fftSize ~/ 2) {
      throw const FormatException('Recording is too short to analyse.');
    }
    final padded = Float64List(samples.length + EdgeAiService.fftSize);
    final halfPadding = EdgeAiService.fftSize ~/ 2;
    for (var i = 0; i < padded.length; i++) {
      final source = i - halfPadding;
      if (source < 0) {
        padded[i] = samples[-source];
      } else if (source >= samples.length) {
        padded[i] = samples[2 * samples.length - source - 2];
      } else {
        padded[i] = samples[source];
      }
    }

    final frameCount =
        1 +
        ((padded.length - EdgeAiService.fftSize) ~/ EdgeAiService.hopLength);
    final filters = _melFilters();
    final melPower = List.generate(
      EdgeAiService.melBands,
      (_) => Float64List(frameCount),
    );
    final real = Float64List(EdgeAiService.fftSize);
    final imaginary = Float64List(EdgeAiService.fftSize);

    for (var frame = 0; frame < frameCount; frame++) {
      final start = frame * EdgeAiService.hopLength;
      for (var i = 0; i < EdgeAiService.fftSize; i++) {
        final window =
            0.5 - 0.5 * math.cos(2 * math.pi * i / EdgeAiService.fftSize);
        real[i] = padded[start + i] * window;
        imaginary[i] = 0;
      }
      _fft(real, imaginary);
      for (var mel = 0; mel < EdgeAiService.melBands; mel++) {
        var sum = 0.0;
        for (var bin = 0; bin < filters[mel].length; bin++) {
          final power = real[bin] * real[bin] + imaginary[bin] * imaginary[bin];
          sum += filters[mel][bin] * power;
        }
        melPower[mel][frame] = sum;
      }
    }

    var maximum = 1e-10;
    for (final band in melPower) {
      for (final value in band) {
        maximum = math.max(maximum, value);
      }
    }
    final floor = maximum * 1e-8; // librosa power_to_db top_db=80
    return List.generate(EdgeAiService.melBands, (mel) {
      final output = Float32List(EdgeAiService.targetFrames);
      for (
        var frame = 0;
        frame < math.min(frameCount, EdgeAiService.targetFrames);
        frame++
      ) {
        output[frame] =
            10 *
            math.log(math.max(floor, melPower[mel][frame]) / maximum) /
            math.ln10;
      }
      return output;
    }, growable: false);
  }

  static List<Float64List> _melFilters() {
    const bins = EdgeAiService.fftSize ~/ 2 + 1;
    final fftFrequencies = List.generate(
      bins,
      (i) => i * EdgeAiService.sampleRate / EdgeAiService.fftSize,
    );
    final minMel = _hzToMel(0);
    final maxMel = _hzToMel(EdgeAiService.sampleRate / 2);
    final melPoints = List.generate(
      EdgeAiService.melBands + 2,
      (i) => minMel + (maxMel - minMel) * i / (EdgeAiService.melBands + 1),
    );
    final hzPoints = melPoints.map(_melToHz).toList(growable: false);

    return List.generate(EdgeAiService.melBands, (mel) {
      final filter = Float64List(bins);
      final lowerWidth = hzPoints[mel + 1] - hzPoints[mel];
      final upperWidth = hzPoints[mel + 2] - hzPoints[mel + 1];
      final normalization = 2 / (hzPoints[mel + 2] - hzPoints[mel]);
      for (var bin = 0; bin < bins; bin++) {
        final lower = (fftFrequencies[bin] - hzPoints[mel]) / lowerWidth;
        final upper = (hzPoints[mel + 2] - fftFrequencies[bin]) / upperWidth;
        filter[bin] = normalization * math.max(0, math.min(lower, upper));
      }
      return filter;
    }, growable: false);
  }

  static double _hzToMel(double hz) {
    const fSp = 200.0 / 3;
    var mel = hz / fSp;
    if (hz >= 1000) {
      final logStep = math.log(6.4) / 27;
      mel = 15 + math.log(hz / 1000) / logStep;
    }
    return mel;
  }

  static double _melToHz(double mel) {
    const fSp = 200.0 / 3;
    var hz = mel * fSp;
    if (mel >= 15) {
      final logStep = math.log(6.4) / 27;
      hz = 1000 * math.exp(logStep * (mel - 15));
    }
    return hz;
  }

  static void _fft(Float64List real, Float64List imaginary) {
    final n = real.length;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        final realValue = real[i];
        real[i] = real[j];
        real[j] = realValue;
        final imaginaryValue = imaginary[i];
        imaginary[i] = imaginary[j];
        imaginary[j] = imaginaryValue;
      }
    }

    for (var length = 2; length <= n; length <<= 1) {
      final angle = -2 * math.pi / length;
      final rootReal = math.cos(angle);
      final rootImaginary = math.sin(angle);
      for (var start = 0; start < n; start += length) {
        var currentReal = 1.0;
        var currentImaginary = 0.0;
        for (var offset = 0; offset < length ~/ 2; offset++) {
          final even = start + offset;
          final odd = even + length ~/ 2;
          final oddReal =
              real[odd] * currentReal - imaginary[odd] * currentImaginary;
          final oddImaginary =
              real[odd] * currentImaginary + imaginary[odd] * currentReal;
          real[odd] = real[even] - oddReal;
          imaginary[odd] = imaginary[even] - oddImaginary;
          real[even] += oddReal;
          imaginary[even] += oddImaginary;
          final nextReal =
              currentReal * rootReal - currentImaginary * rootImaginary;
          currentImaginary =
              currentReal * rootImaginary + currentImaginary * rootReal;
          currentReal = nextReal;
        }
      }
    }
  }
}
