import sounddevice as sd
import numpy as np
import tensorflow as tf
import librosa
import os

# =========================
# CONFIGURATION
# =========================
MODEL_PATH = "model/sound_model_custom.h5"
SAMPLE_RATE = 16000  # Must match the training sample rate
DURATION = 5         # Seconds to record (ESC-50 standard)
LABELS = ["siren", "crying_baby", "door_wood_knock", "glass_breaking"]
TARGET_SHAPE = (64, 128)
CONFIDENCE_THRESHOLD = 0.80

def preprocess_live_audio(audio_data):
    """
    Converts raw audio array to Mel Spectrogram.
    Matches the preprocessing logic in main.py for consistency.
    """
    # Generate Mel Spectrogram
    mel = librosa.feature.melspectrogram(
        y=audio_data,
        sr=SAMPLE_RATE,
        n_mels=TARGET_SHAPE[0]
    )

    # Convert to decibels
    # IMPORTANT: Use ref=np.max to normalize volume relative to the loudest peak.
    # This makes the script consistent with test.py and main.py.
    mel_db = librosa.power_to_db(mel, ref=np.max)

    # Ensure shape = (64, 128)
    if mel_db.shape[1] < TARGET_SHAPE[1]:
        pad_width = TARGET_SHAPE[1] - mel_db.shape[1]
        mel_db = np.pad(mel_db, ((0, 0), (0, pad_width)), mode='constant')
    else:
        mel_db = mel_db[:, :TARGET_SHAPE[1]]

    # Add channel dimension
    return mel_db.reshape(*TARGET_SHAPE, 1)

def main():
    if not os.path.exists(MODEL_PATH):
        print(f"❌ Error: Model not found at {MODEL_PATH}. Please run train.py first.")
        return

    print("🔄 Loading Smart-Ear Model...")
    model = tf.keras.models.load_model(MODEL_PATH)
    print("✅ Model loaded successfully.")

    print(f"\n🎧 System is ready. Using sample rate: {SAMPLE_RATE}Hz")
    
    try:
        while True:
            print(f"\n🎤 Listening for {DURATION} seconds...")
            # Capture mono audio
            recording = sd.rec(int(DURATION * SAMPLE_RATE), samplerate=SAMPLE_RATE, channels=1)
            sd.wait()  # Wait until recording is finished
            
            # Flatten from (N, 1) to (N,) for librosa compatibility
            audio_flat = np.squeeze(recording)
            
            # Simple silence detection: check if volume is too low
            if np.max(np.abs(audio_flat)) < 0.01:
                print("🔇 Too quiet... skipping analysis.")
                continue

            print("✅ Sound detected. Analyzing...")

            # Preprocess
            features = preprocess_live_audio(audio_flat)
            input_data = np.expand_dims(features, axis=0)

            # Predict
            predictions = model.predict(input_data, verbose=0)
            idx = np.argmax(predictions)
            label = LABELS[idx]
            confidence = predictions[0][idx]

            print("\n=== AI Analysis ===")

            if confidence >= CONFIDENCE_THRESHOLD:
                print(f"Detected Sound: {label.upper()}")
                print(f"Confidence:     {confidence:.2%}")
            else:
                print("No reliable sound detected.")
                print(f"Highest confidence: {confidence:.2%}")
                continue

            print("===================")

            input("\nPress Enter to record again, or Ctrl+C to exit...")

    except KeyboardInterrupt:
        print("\n👋 Stopping Smart-Ear Sound Classifier.")

if __name__ == "__main__":
    main()
