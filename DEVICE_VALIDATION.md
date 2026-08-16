# Smart Ear physical-device validation

These tasks require a tester with an Android phone and representative sounds.

## Recognition quality

- Test sirens, car horns, breaking glass, baby cries, and door knocks at several
  distances and volumes.
- Repeat tests with speech, television, traffic, fans, and music in the
  background.
- Record false alerts, missed alerts, confidence, and time-to-alert.
- Tune the metadata thresholds and in-app minimum confidence from the results.

## Reliability and performance

- Run foreground monitoring continuously for 30 minutes, 2 hours, and 8 hours.
- Measure battery drain, device temperature, memory, and inference latency.
- Test screen lock/unlock, incoming calls, audio playback, permission revocation,
  and returning after Android suspends the app.
- Verify vibration and camera flash on devices with and without flash hardware.

## Deferred platform work

- Decide whether Android background monitoring is required after battery tests.
- If required, implement it as an Android foreground service with a persistent
  disclosure notification.
- Validate iOS microphone behavior and implement native iOS alert effects before
  claiming iOS feature parity.
