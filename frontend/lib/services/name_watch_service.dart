import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class NameProfile {
  const NameProfile({
    required this.name,
    required this.sampleCount,
    required this.centroid,
    required this.embeddings,
    required this.updatedAt,
  });

  final String name;
  final int sampleCount;
  final List<double> centroid;
  final List<List<double>> embeddings;
  final DateTime updatedAt;

  NameProfile copyWith({
    String? name,
    int? sampleCount,
    List<double>? centroid,
    List<List<double>>? embeddings,
    DateTime? updatedAt,
  }) {
    return NameProfile(
      name: name ?? this.name,
      sampleCount: sampleCount ?? this.sampleCount,
      centroid: centroid ?? this.centroid,
      embeddings: embeddings ?? this.embeddings,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'sampleCount': sampleCount,
    'centroid': centroid,
    'embeddings': embeddings,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory NameProfile.fromJson(Map<String, dynamic> json) {
    final centroid = (json['centroid'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    final rawEmbeddings = json['embeddings'] as List<dynamic>?;
    final embeddings = rawEmbeddings == null || rawEmbeddings.isEmpty
        ? <List<double>>[centroid]
        : rawEmbeddings
              .map(
                (vector) => (vector as List<dynamic>)
                    .map((value) => (value as num).toDouble())
                    .toList(growable: false),
              )
              .toList(growable: false);
    return NameProfile(
      name: json['name'] as String,
      sampleCount: (json['sampleCount'] as num).toInt(),
      centroid: centroid,
      embeddings: embeddings,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

class NameMatchResult {
  const NameMatchResult({
    required this.name,
    required this.score,
    required this.confidence,
  });

  final String name;
  final double score;
  final double confidence;
}

class NameWatchService {
  static const int sampleRate = 16000;
  static const int fftSize = 1024;
  static const int hopLength = 256;
  static const int melBands = 24;
  static const int targetFrames = 24;
  static const double detectionThreshold = 0.92;
  static const double singleSampleThreshold = 0.96;
  static const double minimumWindowRms = 0.02;
  static const int maxEmbeddingsPerName = 8;

  static final NameWatchService _instance = NameWatchService._internal();

  factory NameWatchService() => _instance;

  NameWatchService._internal();

  final Map<String, NameProfile> _profiles = {};
  bool _loaded = false;
  List<List<double>>? _melFilters;

  Future<void> load() async {
    if (_loaded) return;
    final file = await _storageFile();
    if (await file.exists()) {
      final raw = await file.readAsString();
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _profiles.clear();
        for (final entry in decoded) {
          final profile = NameProfile.fromJson(entry as Map<String, dynamic>);
          _profiles[profile.name] = profile;
        }
      }
    }
    _loaded = true;
  }

  Future<List<NameProfile>> listProfiles() async {
    await load();
    final profiles = _profiles.values.toList(growable: false);
    profiles.sort((left, right) => left.name.compareTo(right.name));
    return profiles;
  }

  Future<NameProfile> enrollSample(String rawName, List<int> wavBytes) async {
    await load();
    final name = _normalizeName(rawName);
    if (name.isEmpty) {
      throw ArgumentError('Name cannot be empty.');
    }

    final embedding = _extractEmbeddingFromWav(wavBytes);
    final existing = _profiles[name];
    final updated = existing == null
        ? NameProfile(
            name: name,
            sampleCount: 1,
            centroid: embedding,
            embeddings: <List<double>>[embedding],
            updatedAt: DateTime.now(),
          )
        : NameProfile(
            name: name,
            sampleCount: existing.sampleCount + 1,
            centroid: _averageAndNormalize(existing.centroid, embedding, existing.sampleCount),
            embeddings: <List<double>>[
              ...existing.embeddings,
              embedding,
            ].skip(math.max(0, existing.embeddings.length + 1 - maxEmbeddingsPerName)).toList(growable: false),
            updatedAt: DateTime.now(),
          );
    _profiles[name] = updated;
    await _save();
    return updated;
  }

  Future<void> deleteProfile(String rawName) async {
    await load();
    _profiles.remove(_normalizeName(rawName));
    await _save();
  }

  Future<NameMatchResult?> detectFromPcm(List<int> pcmBytes) async {
    await load();
    if (_profiles.isEmpty || pcmBytes.isEmpty) return null;

    final samples = _decodePcmToMonoSamples(pcmBytes);
    if (!_looksLikeSpeechWindow(samples)) return null;

    final liveEmbedding = _extractEmbedding(_trimToActiveAudio(samples));
    String? bestName;
    double bestScore = double.negativeInfinity;
    double secondBest = double.negativeInfinity;
    int bestSampleCount = 0;

    for (final profile in _profiles.values) {
      final score = _scoreAgainstProfile(liveEmbedding, profile);
      if (score > bestScore) {
        secondBest = bestScore;
        bestScore = score;
        bestName = profile.name;
        bestSampleCount = profile.sampleCount;
      } else if (score > secondBest) {
        secondBest = score;
      }
    }

    if (bestName == null) return null;
    final requiredThreshold =
        bestSampleCount <= 1 ? singleSampleThreshold : detectionThreshold;
    if (bestScore < requiredThreshold) return null;
    if (secondBest.isFinite && (bestScore - secondBest) < 0.06) return null;

    final confidence = ((bestScore - requiredThreshold) /
            (1 - requiredThreshold))
        .clamp(0.0, 1.0)
        .toDouble();
    return NameMatchResult(
      name: bestName,
      score: bestScore,
      confidence: confidence,
    );
  }

  Future<void> clearAll() async {
    await load();
    _profiles.clear();
    await _save();
  }

  Future<File> _storageFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/name_watch_profiles.json');
  }

  Future<void> _save() async {
    final file = await _storageFile();
    final payload = _profiles.values
        .map((profile) => profile.toJson())
        .toList(growable: false);
    await file.writeAsString(jsonEncode(payload));
  }

  String _normalizeName(String name) => name.trim().toLowerCase();

  List<double> _averageAndNormalize(
    List<double> existing,
    List<double> next,
    int existingSamples,
  ) {
    final combined = List<double>.filled(existing.length, 0, growable: false);
    for (var i = 0; i < existing.length; i++) {
      combined[i] = ((existing[i] * existingSamples) + next[i]) /
          (existingSamples + 1);
    }
    return _normalizeVector(combined);
  }

  double _cosineSimilarity(List<double> left, List<double> right) {
    var dot = 0.0;
    for (var i = 0; i < left.length; i++) {
      dot += left[i] * right[i];
    }
    return dot;
  }

  double _scoreAgainstProfile(List<double> liveEmbedding, NameProfile profile) {
    final similarities = profile.embeddings
        .map((vector) => _cosineSimilarity(liveEmbedding, vector))
        .toList(growable: false);
    similarities.sort((left, right) => right.compareTo(left));
    if (similarities.isEmpty) return double.negativeInfinity;
    if (similarities.length == 1) return similarities.first;
    final top = similarities[0];
    final next = similarities[1];
    return (top * 0.65) + (next * 0.35);
  }

  List<double> _extractEmbeddingFromWav(List<int> wavBytes) {
    final samples = _trimToActiveAudio(_decodeWavToMonoSamples(wavBytes));
    return _extractEmbedding(samples);
  }

  List<double> _extractEmbedding(Float32List samples) {
    if (samples.length < fftSize ~/ 2) {
      throw const FormatException('Audio sample is too short to analyse.');
    }

    final padded = Float64List(samples.length + fftSize);
    final halfPadding = fftSize ~/ 2;
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
        1 + ((padded.length - fftSize) ~/ hopLength);
    final filters = _melFilterBank();
    final melPower = List.generate(melBands, (_) => Float64List(frameCount));
    final real = Float64List(fftSize);
    final imaginary = Float64List(fftSize);

    for (var frame = 0; frame < frameCount; frame++) {
      final start = frame * hopLength;
      for (var i = 0; i < fftSize; i++) {
        final window = 0.5 - 0.5 * math.cos(2 * math.pi * i / fftSize);
        real[i] = padded[start + i] * window;
        imaginary[i] = 0;
      }
      _fft(real, imaginary);
      for (var mel = 0; mel < melBands; mel++) {
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

    final floor = maximum * 1e-8;
    final featureVector = List<double>.filled(melBands * targetFrames, 0);
    for (var mel = 0; mel < melBands; mel++) {
      for (var frame = 0; frame < targetFrames; frame++) {
        final start = (frame * frameCount / targetFrames).floor();
        var end = (((frame + 1) * frameCount) / targetFrames).ceil();
        if (end <= start) end = math.min(start + 1, frameCount);
        var sum = 0.0;
        var count = 0;
        for (var index = start; index < end && index < frameCount; index++) {
          sum += melPower[mel][index];
          count++;
        }
        final averaged = count == 0 ? floor : math.max(floor, sum / count);
        featureVector[mel * targetFrames + frame] =
            10 * math.log(averaged / maximum) / math.ln10;
      }
    }

    return _normalizeVector(featureVector);
  }

  bool _looksLikeSpeechWindow(Float32List samples) {
    var sumSquares = 0.0;
    var zeroCrossings = 0;
    var previous = samples[0];
    for (var i = 0; i < samples.length; i++) {
      final value = samples[i];
      sumSquares += value * value;
      if ((value >= 0 && previous < 0) || (value < 0 && previous >= 0)) {
        zeroCrossings++;
      }
      previous = value;
    }

    final rms = math.sqrt(sumSquares / samples.length);
    if (rms < minimumWindowRms) return false;

    final zcr = zeroCrossings / samples.length;
    if (zcr < 0.01 || zcr > 0.35) return false;
    return true;
  }

  /// Removes leading and trailing room noise so matching is not sensitive to
  /// where the spoken name occurs inside the recording window.
  Float32List _trimToActiveAudio(Float32List samples) {
    if (samples.length < fftSize) return samples;

    const frameLength = 320;
    final frameCount = (samples.length / frameLength).ceil();
    final levels = List<double>.filled(frameCount, 0, growable: false);
    var peak = 0.0;
    for (var frame = 0; frame < frameCount; frame++) {
      final start = frame * frameLength;
      final end = math.min(start + frameLength, samples.length);
      var energy = 0.0;
      for (var index = start; index < end; index++) {
        energy += samples[index] * samples[index];
      }
      final rms = math.sqrt(energy / (end - start));
      levels[frame] = rms;
      peak = math.max(peak, rms);
    }

    final threshold = math.max(0.012, peak * 0.18);
    var first = levels.indexWhere((level) => level >= threshold);
    if (first < 0) return samples;
    var last = levels.lastIndexWhere((level) => level >= threshold);
    first = math.max(0, first - 5);
    last = math.min(frameCount - 1, last + 5);
    final start = first * frameLength;
    final end = math.min(samples.length, (last + 1) * frameLength);
    if (end - start < fftSize ~/ 2) return samples;
    return Float32List.fromList(samples.sublist(start, end));
  }

  List<double> _normalizeVector(List<double> values) {
    var norm = 0.0;
    for (final value in values) {
      norm += value * value;
    }
    if (norm == 0) return values;

    final scale = 1 / math.sqrt(norm);
    return values.map((value) => value * scale).toList(growable: false);
  }

  Float32List _decodeWavToMonoSamples(List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    if (data.length < 44 || _ascii(data, 0, 4) != 'RIFF' || _ascii(data, 8, 4) != 'WAVE') {
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

    if (format != 1 || bits != 16 || channels == null || channels < 1 ||
        audioOffset == null || audioLength == null) {
      throw const FormatException('Only 16-bit PCM WAV recordings are supported.');
    }
    if (rate != sampleRate) {
      throw FormatException('Expected $sampleRate Hz audio, received $rate Hz.');
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

  Float32List _decodePcmToMonoSamples(List<int> bytes) {
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final frameCount = bytes.length ~/ 2;
    final samples = Float32List(frameCount);
    for (var frame = 0; frame < frameCount; frame++) {
      samples[frame] = data.getInt16(frame * 2, Endian.little) / 32768.0;
    }
    return samples;
  }

  List<List<double>> _melFilterBank() {
    final cached = _melFilters;
    if (cached != null) return cached;

    const bins = fftSize ~/ 2 + 1;
    final fftFrequencies = List.generate(
      bins,
      (index) => index * sampleRate / fftSize,
    );
    final minMel = _hzToMel(0);
    final maxMel = _hzToMel(sampleRate / 2);
    final melPoints = List.generate(
      melBands + 2,
      (index) => minMel + (maxMel - minMel) * index / (melBands + 1),
    );
    final hzPoints = melPoints.map(_melToHz).toList(growable: false);

    final filters = List.generate(melBands, (mel) {
      final filter = List<double>.filled(bins, 0, growable: false);
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

    _melFilters = filters;
    return filters;
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

  static String _ascii(Uint8List data, int offset, int length) =>
      String.fromCharCodes(data.sublist(offset, offset + length));
}
