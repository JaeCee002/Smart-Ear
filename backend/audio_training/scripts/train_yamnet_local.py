"""Low-memory, resumable YAMNet training for the Smart Ear local dataset."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import time
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
os.environ.setdefault("TF_FORCE_GPU_ALLOW_GROWTH", "true")
os.environ.setdefault("TF_ENABLE_ONEDNN_OPTS", "0")

import librosa
import numpy as np
import tensorflow as tf
import tensorflow_hub as hub
from sklearn.metrics import classification_report, precision_recall_curve


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "manifests" / "all.csv"
DEFAULT_CONFIG = ROOT / "config" / "labels.json"
EMBEDDING_SIZE = 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--cache-dir", type=Path, default=ROOT / "cache" / "yamnet_local")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "outputs" / "yamnet_local")
    parser.add_argument("--max-files", type=int, help="Extract at most this many new files")
    parser.add_argument("--extract-only", action="store_true")
    parser.add_argument("--threads", type=int, default=2)
    return parser.parse_args()


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ValueError(f"Manifest is empty: {path}")
    return rows


def manifest_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_cache(
    cache_dir: Path,
    count: int,
    label_count: int,
    fingerprint: str,
) -> tuple[np.memmap, np.memmap, np.memmap]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    metadata_path = cache_dir / "cache_metadata.json"
    expected = {
        "manifest_sha256": fingerprint,
        "recordings": count,
        "embedding_size": EMBEDDING_SIZE,
        "label_count": label_count,
    }
    mode = "r+"
    if metadata_path.is_file():
        actual = json.loads(metadata_path.read_text(encoding="utf-8"))
        if actual != expected:
            raise RuntimeError(
                "The manifest or labels changed. Use a new --cache-dir instead of "
                "mixing incompatible embeddings."
            )
    else:
        mode = "w+"
        metadata_path.write_text(json.dumps(expected, indent=2), encoding="utf-8")

    embeddings = np.memmap(
        cache_dir / "embeddings.float32",
        dtype=np.float32,
        mode=mode,
        shape=(count, EMBEDDING_SIZE),
    )
    targets = np.memmap(
        cache_dir / "targets.float32",
        dtype=np.float32,
        mode=mode,
        shape=(count, label_count),
    )
    completed = np.memmap(
        cache_dir / "completed.uint8",
        dtype=np.uint8,
        mode=mode,
        shape=(count,),
    )
    if mode == "w+":
        embeddings[:] = 0
        targets[:] = 0
        completed[:] = 0
        embeddings.flush(); targets.flush(); completed.flush()
    return embeddings, targets, completed


def extract_embeddings(
    rows: list[dict[str, str]],
    labels: list[str],
    embeddings: np.memmap,
    targets: np.memmap,
    completed: np.memmap,
    max_files: int | None,
) -> int:
    pending = np.flatnonzero(completed == 0)
    if max_files is not None:
        pending = pending[:max_files]
    if not len(pending):
        print("Embedding cache is already complete.")
        return 0

    print("Loading pretrained YAMNet (downloaded once, then cached locally)...")
    yamnet = hub.load("https://tfhub.dev/google/yamnet/1")
    label_index = {label: index for index, label in enumerate(labels)}
    started = time.perf_counter()
    for position, row_index in enumerate(pending, 1):
        row = rows[int(row_index)]
        waveform, _ = librosa.load(row["path"], sr=16000, mono=True, dtype=np.float32)
        try:
            _, frames, _ = yamnet(tf.convert_to_tensor(waveform, dtype=tf.float32))
        except (tf.errors.ResourceExhaustedError, tf.errors.AbortedError):
            embeddings.flush(); targets.flush(); completed.flush()
            print(
                "TensorFlow exhausted available RAM; restarting with the cache intact.",
                flush=True,
            )
            raise SystemExit(11)
        embeddings[row_index] = tf.reduce_mean(frames, axis=0).numpy()
        targets[row_index] = 0
        if row["label"] != "background":
            targets[row_index, label_index[row["label"]]] = 1
        completed[row_index] = 1
        if position % 10 == 0 or position == len(pending):
            embeddings.flush(); targets.flush(); completed.flush()
            elapsed = time.perf_counter() - started
            rate = position / elapsed
            total_done = int(completed.sum())
            remaining = len(rows) - total_done
            eta_hours = remaining / rate / 3600 if rate else float("inf")
            print(
                f"Embedded {position}/{len(pending)} this run; "
                f"{total_done}/{len(rows)} total; ETA {eta_hours:.1f} h"
            )
    return len(pending)


def sample_weights(y: np.ndarray, train_mask: np.ndarray) -> np.ndarray:
    groups = np.where(y.sum(axis=1) == 0, y.shape[1], y.argmax(axis=1))
    train_groups = groups[train_mask]
    counts = np.bincount(train_groups, minlength=y.shape[1] + 1)
    weights_by_group = np.zeros_like(counts, dtype=np.float32)
    present = counts > 0
    weights_by_group[present] = train_groups.size / (present.sum() * counts[present])
    weights = weights_by_group[train_groups]
    return weights / weights.mean()


def best_thresholds(
    y_true: np.ndarray,
    scores: np.ndarray,
    labels: list[str],
) -> dict[str, float]:
    result: dict[str, float] = {}
    for index, label in enumerate(labels):
        if len(np.unique(y_true[:, index])) < 2:
            result[label] = 0.5
            continue
        precision, recall, values = precision_recall_curve(y_true[:, index], scores[:, index])
        f1 = 2 * precision * recall / np.maximum(precision + recall, 1e-8)
        best = int(np.nanargmax(f1[:-1]))
        result[label] = float(values[best])
    return result


def train_head(
    rows: list[dict[str, str]],
    labels: list[str],
    embeddings: np.memmap,
    targets: np.memmap,
    output_dir: Path,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    splits = np.asarray([row["split"] for row in rows])
    train_mask = splits == "train"
    validation_mask = splits == "validation"
    test_mask = splits == "test"
    x = np.asarray(embeddings)
    y = np.asarray(targets)

    tf.keras.utils.set_random_seed(42)
    model = tf.keras.Sequential(
        [
            tf.keras.layers.Input((EMBEDDING_SIZE,), name="yamnet_embedding"),
            tf.keras.layers.Dense(128, activation="relu"),
            tf.keras.layers.Dropout(0.35),
            tf.keras.layers.Dense(len(labels), activation="sigmoid", name="probabilities"),
        ]
    )
    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss="binary_crossentropy",
        metrics=[tf.keras.metrics.AUC(curve="PR", multi_label=True, name="pr_auc")],
    )
    model.fit(
        x[train_mask],
        y[train_mask],
        sample_weight=sample_weights(y, train_mask),
        validation_data=(x[validation_mask], y[validation_mask]),
        epochs=60,
        batch_size=32,
        callbacks=[
            tf.keras.callbacks.EarlyStopping(
                monitor="val_pr_auc",
                mode="max",
                patience=8,
                restore_best_weights=True,
            )
        ],
        verbose=2,
    )

    validation_scores = model.predict(x[validation_mask], batch_size=64, verbose=0)
    thresholds = best_thresholds(y[validation_mask], validation_scores, labels)
    test_scores = model.predict(x[test_mask], batch_size=64, verbose=0)
    test_predictions = np.column_stack(
        [test_scores[:, i] >= thresholds[label] for i, label in enumerate(labels)]
    ).astype(np.int8)
    report = classification_report(
        y[test_mask],
        test_predictions,
        target_names=labels,
        zero_division=0,
        output_dict=True,
    )

    model.save(output_dir / "smart_ear_yamnet_head.keras")
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    (output_dir / "smart_ear_yamnet_head.tflite").write_bytes(converter.convert())
    metadata = {
        "version": "2.0.0-local-candidate",
        "model_type": "yamnet_embedding_head",
        "embedding_size": EMBEDDING_SIZE,
        "sample_rate": 16000,
        "labels": labels,
        "thresholds": thresholds,
        "training_sources": sorted({row["source"] for row in rows}),
    }
    (output_dir / "model_metadata.json").write_text(
        json.dumps(metadata, indent=2), encoding="utf-8"
    )
    (output_dir / "evaluation_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, indent=2))
    print(f"Candidate artifacts written to {output_dir}")


def main() -> None:
    args = parse_args()
    tf.config.threading.set_intra_op_parallelism_threads(args.threads)
    tf.config.threading.set_inter_op_parallelism_threads(1)
    config = json.loads(args.config.read_text(encoding="utf-8"))
    labels = config["labels"]
    rows = load_rows(args.manifest)
    embeddings, targets, completed = prepare_cache(
        args.cache_dir,
        len(rows),
        len(labels),
        manifest_hash(args.manifest),
    )
    extracted = extract_embeddings(
        rows, labels, embeddings, targets, completed, args.max_files
    )
    remaining = int((completed == 0).sum())
    print(f"New embeddings: {extracted}; remaining: {remaining}")
    if remaining:
        print("Run the same command again to resume.")
        raise SystemExit(10 if args.max_files is not None else 0)
    if not args.extract_only:
        train_head(rows, labels, embeddings, targets, args.output_dir)


if __name__ == "__main__":
    main()
