# Smart Ear audio training

This workspace builds a candidate YAMNet-based classifier without replacing the
model currently shipped by the Flutter app.

## Initial labels

- `siren`
- `car_horn`
- `glass_breaking`
- `baby_crying`
- `door_knocking`

All configured non-critical classes become negative/background examples. The
model uses independent sigmoid outputs, so a background recording has an
all-zero target vector rather than being a sixth critical event.

## Local dataset audit

Python 3.10 or newer is sufficient for manifest generation; TensorFlow is not
required.

```powershell
cd backend\audio_training
python scripts\build_manifest.py `
  --esc50 C:\path\to\ESC-50-master `
  --urbansound8k C:\path\to\UrbanSound8K

python scripts\audit_manifest.py manifests\all.csv --fail-on-leakage
```

Either dataset argument may be omitted while the other dataset is unavailable.
The generated CSV files contain absolute paths for the machine on which they
were created. Rebuild the manifests inside Colab after mounting the datasets
from Google Drive.

## Expected layouts

```text
ESC-50-master/
  audio/*.wav
  meta/esc50.csv

UrbanSound8K/
  audio/fold1/*.wav
  ...
  audio/fold10/*.wav
  metadata/UrbanSound8K.csv
```

The importer also accepts the common flattened archive layout, where
`UrbanSound8K.csv` and `fold1/` through `fold10/` are directly under the dataset
root.

Do not rename, merge, or randomly reshuffle the original files and folds.
If an original source identifier occurs in more than one published fold, the
manifest builder moves all of its clips into the most protected applicable
split (`test`, then `validation`). This intentionally prioritizes leakage-free
evaluation over preserving those exceptional fold assignments.

## Colab

Open `notebooks/smart_ear_yamnet_training.ipynb` in Google Colab. Its first cell
mounts Drive, downloads the official ESC-50 and UrbanSound8K archives directly
into temporary Colab storage, and extracts the uploaded training package. This
avoids uploading multi-gigabyte datasets through Drive. The notebook then:

1. mounts Google Drive;
2. builds and audits manifests in the Colab environment;
3. downloads pretrained YAMNet from TensorFlow Hub;
4. extracts and caches 1024-value embeddings;
5. trains a multi-label sigmoid classification head;
6. reports per-class precision, recall, F1 and a confusion-style heatmap;
7. derives provisional per-class thresholds from validation data; and
8. exports a TFLite classification head plus model metadata.

The exported head consumes YAMNet embeddings, not raw waveform or the old
`64 x 128` Mel tensor. It is deliberately kept out of Flutter until a complete
YAMNet + head mobile pipeline is implemented and its results beat the current
model on the held-out test set.

## Generated files

Datasets, cached embeddings, generated manifests and training outputs are
ignored by Git because they can be large or contain machine-specific paths.
Keep experiment summaries and released model metadata separately when a
candidate is promoted.

## Low-memory local training

For a 4 GB Windows PC, the local trainer processes one recording at a time and
stores 1024-value YAMNet embeddings in memory-mapped cache files. It can resume
after interruption without repeating completed audio:

```powershell
python scripts\train_yamnet_local.py --max-files 10 --extract-only
powershell -ExecutionPolicy Bypass -File scripts\run_yamnet_local.ps1
```

The first command is a short environment check. The second resumes until all
embeddings exist and then trains the small classification head. It restarts the
TensorFlow worker every 100 recordings to release fragmented memory on low-RAM
machines. Cache and model outputs are ignored by Git. Close memory-heavy
applications during extraction.
