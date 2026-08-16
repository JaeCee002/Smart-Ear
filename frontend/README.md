# Smart Ear mobile app

Smart Ear is an offline Flutter application that detects important environmental
sounds and presents strong visual and haptic alerts. The current classifier
recognizes emergency sirens, car horns, breaking glass, crying babies, and door
knocks.

## Current capabilities

- continuous foreground microphone monitoring;
- fully on-device YAMNet and TensorFlow Lite inference;
- configurable sound classes and minimum confidence;
- Android vibration and high-priority camera-flash alerts;
- persistent alert history; and
- local preferences with no account or network dependency.

Name Watch is intentionally paused. Its experimental source files remain in the
repository, but it is not exposed in application navigation.

## Run locally

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

Microphone capture is intended for Android, iOS, and macOS. Native vibration and
flash effects are currently implemented only for Android.

## Model assets

The default engine loads:

- `assets/models/yamnet.tflite`
- `assets/models/smart_ear_yamnet_head.tflite`
- `assets/models/yamnet_model_metadata.json`

The legacy classifier remains available for development builds with
`--dart-define=SMART_EAR_AI_ENGINE=legacy`.

## Work requiring physical-device validation

Before release, test the five sound classes on representative phones and tune
thresholds using real environmental recordings. Long-running microphone use,
battery consumption, interruptions, camera flash behavior, and background
monitoring also require device testing. Background monitoring is deliberately
not enabled until those measurements are available.

Release signing and a permanent Android application ID must be configured before
publishing an APK or app bundle.
