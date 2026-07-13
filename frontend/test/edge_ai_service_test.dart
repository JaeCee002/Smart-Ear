import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartear_flutter/services/edge_ai_service.dart';

void main() {
  test('decodes mono 16-bit PCM WAV samples', () {
    final wav = _pcmWav(Int16List.fromList([-32768, 0, 16384, 32767]));
    final samples = WavDecoder.decodeMono16k(wav);

    expect(samples, hasLength(4));
    expect(samples[0], closeTo(-1, 0.0001));
    expect(samples[1], 0);
    expect(samples[2], closeTo(0.5, 0.0001));
    expect(samples[3], closeTo(1, 0.0001));
  });

  test('rejects audio recorded at the wrong sample rate', () {
    final wav = _pcmWav(Int16List(32), sampleRate: 44100);
    expect(
      () => WavDecoder.decodeMono16k(wav),
      throwsA(isA<FormatException>()),
    );
  });

  test('creates the model-required finite Mel tensor', () {
    final samples = Float32List(EdgeAiService.sampleRate * 5);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = i.isEven ? 0.25 : -0.25;
    }

    final mel = MelSpectrogram.extract(samples);

    expect(mel, hasLength(EdgeAiService.melBands));
    for (final band in mel) {
      expect(band, hasLength(EdgeAiService.targetFrames));
      expect(band.every((value) => value.isFinite), isTrue);
      expect(band.every((value) => value <= 0 && value >= -80.001), isTrue);
    }
  });
}

Uint8List _pcmWav(Int16List samples, {int sampleRate = 16000}) {
  final output = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(output);
  void ascii(int offset, String value) {
    output.setRange(offset, offset + value.length, value.codeUnits);
  }

  ascii(0, 'RIFF');
  data.setUint32(4, output.length - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return output;
}
