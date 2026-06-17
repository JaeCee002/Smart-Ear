from fastapi import FastAPI, File, UploadFile
from fastapi.responses import JSONResponse
import tensorflow as tf
import numpy as np
import librosa
import os
import io
import time
import soundfile as sf

app = FastAPI()


# CONFIGURATION
MODEL_PATH = "model/sound_model.h5"
SAMPLE_RATE = 16000
DURATION = 5
TARGET_SHAPE = (64, 128)

LABELS = [
    "dog",
    "rain",
    "crying_baby",
    "door_wood_knock"
]

CONFIDENCE_THRESHOLD = 0.70

# LOAD MODEL ONCE
print("Loading Smart-Ear model...")

model = tf.keras.models.load_model(MODEL_PATH)

print("Model loaded successfully.")


# AUDIO PREPROCESSING
def preprocess_live_audio(audio_data):

    mel = librosa.feature.melspectrogram(
        y=audio_data,
        sr=SAMPLE_RATE,
        n_mels=TARGET_SHAPE[0]
    )

    mel_db = librosa.power_to_db(
        mel,
        ref=np.max
    )

    if mel_db.shape[1] < TARGET_SHAPE[1]:

        pad_width = TARGET_SHAPE[1] - mel_db.shape[1]

        mel_db = np.pad(
            mel_db,
            ((0, 0), (0, pad_width)),
            mode='constant'
        )

    else:

        mel_db = mel_db[:, :TARGET_SHAPE[1]]

    return mel_db.reshape(*TARGET_SHAPE, 1)


# PREDICTION ENDPOINT
@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    """
    Receive raw audio WAV bytes from frontend.
    Preprocess and predict sound label.
    """
    try:
        start_time = time.time()
        print(f"🔔 /predict called - filename={file.filename}, content_type={file.content_type}")

        # Read audio file
        audio_bytes = await file.read()

        print(f"📥 Received upload: {len(audio_bytes)} bytes")
        
        # Load audio from bytes
        audio_data, sr = sf.read(io.BytesIO(audio_bytes))
        
        # Handle stereo - convert to mono if needed
        if len(audio_data.shape) > 1:
            audio_data = np.mean(audio_data, axis=1)
        
        # Resample if necessary
        if sr != SAMPLE_RATE:
            audio_data = librosa.resample(audio_data, orig_sr=sr, target_sr=SAMPLE_RATE)
        
        # Silence detection
        if np.max(np.abs(audio_data)) < 0.01:
            return {
                "label": "silence",
                "confidence": 0.0
            }

        # Preprocess
        features = preprocess_live_audio(audio_data)
        input_data = np.expand_dims(features, axis=0)

        # Predict
        predictions = model.predict(input_data, verbose=0)
        idx = np.argmax(predictions)
        label = LABELS[idx]
        confidence = float(predictions[0][idx])

        elapsed = time.time() - start_time
        print(f"✅ Prediction complete in {elapsed:.2f}s — label={label}, confidence={confidence:.3f}")

        # Confidence threshold
        if confidence < CONFIDENCE_THRESHOLD:
            return {
                "label": "unknown",
                "confidence": confidence
            }

        return {
            "label": label,
            "confidence": confidence
        }
        
    except Exception as e:
        print(f"❌ Error in prediction: {str(e)}")
        return JSONResponse(
            status_code=400,
            content={
                "label": "error",
                "confidence": 0.0,
                "error": str(e)
            }
        )


@app.get("/predict-legacy")
def predict_legacy():
    """
    Legacy endpoint - records directly on backend.
    Deprecated in favor of /predict which accepts audio from frontend.
    """
    import sounddevice as sd
    
    print("Recording...")

    recording = sd.rec(
        int(DURATION * SAMPLE_RATE),
        samplerate=SAMPLE_RATE,
        channels=1
    )

    sd.wait()

    audio_flat = np.squeeze(recording)

    # Silence detection
    if np.max(np.abs(audio_flat)) < 0.01:

        return {
            "label": "silence",
            "confidence": 0.0
        }

    features = preprocess_live_audio(audio_flat)

    input_data = np.expand_dims(
        features,
        axis=0
    )

    predictions = model.predict(
        input_data,
        verbose=0
    )
    print(predictions[0])

    idx = np.argmax(predictions)

    label = LABELS[idx]

    confidence = float(predictions[0][idx])

    # Confidence threshold
    if confidence < CONFIDENCE_THRESHOLD:

        return {
            "label": "unknown",
            "confidence": confidence
        }

    return {
        "label": label,
        "confidence": confidence
    }
