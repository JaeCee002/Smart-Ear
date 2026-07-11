import os
import numpy as np
import pandas as pd
import librosa
from tensorflow.keras import layers, models
 
# ====== CONFIG ======
DATA_PATH = "ESC-50-master" # Path to ESC-50 dataset
TARGET_CLASSES = ["siren", "crying_baby", "door_wood_knock", "glass_breaking"]

SAMPLE_RATE = 16000
FIXED_SHAPE = (64, 128)

# ====== LOAD METADATA ======
meta_path = os.path.join(DATA_PATH, "meta", "esc50.csv")
meta = pd.read_csv(meta_path)

# Filter classes
meta = meta[meta['category'].isin(TARGET_CLASSES)]

print(f"Total samples: {len(meta)}")

# ====== LABEL MAP ======
label_map = {label: i for i, label in enumerate(TARGET_CLASSES)}

# ====== FEATURE EXTRACTION ======
def extract_features(file_path):
    audio, sr = librosa.load(file_path, sr=SAMPLE_RATE)

    mel = librosa.feature.melspectrogram(
        y=audio,
        sr=sr,
        n_mels=64
    )

    # Use ref=np.max to normalize training samples
    mel_db = librosa.power_to_db(mel, ref=np.max)

    # Proper padding/cropping instead of np.resize
    if mel_db.shape[1] < FIXED_SHAPE[1]:
        pad_width = FIXED_SHAPE[1] - mel_db.shape[1]
        mel_db = np.pad(mel_db, ((0, 0), (0, pad_width)), mode='constant')
    else:
        mel_db = mel_db[:, :FIXED_SHAPE[1]]

    return mel_db

# ====== BUILD DATASET ======
X = []
y = []

for _, row in meta.iterrows():
    file_path = os.path.join(DATA_PATH, "audio", row["filename"])

    try:
        features = extract_features(file_path)

        X.append(features)
        y.append(label_map[row["category"]])

    except Exception as e:
        print(f"Error loading {file_path}: {e}")

X = np.array(X)
y = np.array(y)

# Add channel dimension
X = X[..., np.newaxis]

print("Dataset shape:", X.shape)

# ====== MODEL ======
model = models.Sequential([
    layers.Conv2D(16, (3,3), activation='relu', input_shape=(64,128,1)),
    layers.MaxPooling2D((2,2)),

    layers.Conv2D(32, (3,3), activation='relu'),
    layers.MaxPooling2D((2,2)),

    layers.Flatten(),
    layers.Dense(64, activation='relu'),
    layers.Dense(len(TARGET_CLASSES), activation='softmax')
])

model.compile(
    optimizer='adam',
    loss='sparse_categorical_crossentropy',
    metrics=['accuracy']
)

model.summary()

# ====== TRAIN ======
model.fit(X, y, epochs=10, batch_size=16, validation_split=0.2)

# ====== SAVE ======
os.makedirs("model", exist_ok=True)
model.save("model/sound_model.h5")

print("Model saved to model/sound_model.h5")
