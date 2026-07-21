"""Build source-safe Smart Ear manifests from ESC-50 and UrbanSound8K."""

from __future__ import annotations

import argparse
import csv
import json
import struct
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "labels.json"
FIELDS = [
    "path",
    "label",
    "source",
    "source_id",
    "fold",
    "split",
    "duration_seconds",
    "sample_rate",
    "channels",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esc50", type=Path, help="Path to ESC-50-master")
    parser.add_argument("--urbansound8k", type=Path, help="Path to UrbanSound8K")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "manifests")
    return parser.parse_args()


def audio_info(path: Path) -> tuple[float, int, int]:
    """Read RIFF metadata, including valid WAVE_FORMAT_EXTENSIBLE files."""
    with path.open("rb") as handle:
        header = handle.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise ValueError(f"Not a RIFF/WAVE file: {path}")
        channels = sample_rate = byte_rate = data_size = None
        while chunk_header := handle.read(8):
            if len(chunk_header) != 8:
                break
            chunk_id, chunk_size = struct.unpack("<4sI", chunk_header)
            if chunk_id == b"fmt ":
                payload = handle.read(chunk_size)
                if len(payload) < 16:
                    raise ValueError(f"Invalid WAV fmt chunk: {path}")
                _, channels, sample_rate, byte_rate = struct.unpack("<HHII", payload[:12])
            elif chunk_id == b"data":
                data_size = chunk_size
                handle.seek(chunk_size, 1)
            else:
                handle.seek(chunk_size, 1)
            if chunk_size % 2:
                handle.seek(1, 1)
            if channels and sample_rate and byte_rate and data_size is not None:
                return data_size / byte_rate, sample_rate, channels
    raise ValueError(f"Incomplete WAV metadata: {path}")


def split_for(config: dict[str, Any], source: str, fold: int) -> str:
    for split, folds in config["splits"][source].items():
        if fold in folds:
            return split
    raise ValueError(f"Fold {fold} has no configured {source} split")


def mapped_label(config: dict[str, Any], source: str, source_label: str) -> str | None:
    mapping = config["source_mappings"][source]
    if source_label in mapping:
        return mapping[source_label]
    if source_label in config["background_classes"][source]:
        return "background"
    return None


def esc50_rows(root: Path, config: dict[str, Any]) -> Iterable[dict[str, Any]]:
    metadata = root / "meta" / "esc50.csv"
    if not metadata.is_file():
        raise FileNotFoundError(f"ESC-50 metadata not found: {metadata}")
    with metadata.open(encoding="utf-8", newline="") as handle:
        for item in csv.DictReader(handle):
            label = mapped_label(config, "esc50", item["category"])
            if label is None:
                continue
            path = root / "audio" / item["filename"]
            if not path.is_file():
                raise FileNotFoundError(f"ESC-50 audio not found: {path}")
            duration, rate, channels = audio_info(path)
            fold = int(item["fold"])
            yield {
                "path": path.resolve().as_posix(),
                "label": label,
                "source": "esc50",
                "source_id": item.get("src_file") or item["filename"],
                "fold": fold,
                "split": split_for(config, "esc50", fold),
                "duration_seconds": f"{duration:.6f}",
                "sample_rate": rate,
                "channels": channels,
            }


def find_urbansound_metadata(root: Path) -> Path:
    candidates = [
        root / "metadata" / "UrbanSound8K.csv",
        root / "UrbanSound8K.csv",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"UrbanSound8K.csv not found below {root}")


def urbansound_rows(root: Path, config: dict[str, Any]) -> Iterable[dict[str, Any]]:
    metadata = find_urbansound_metadata(root)
    with metadata.open(encoding="utf-8-sig", newline="") as handle:
        for item in csv.DictReader(handle):
            source_label = (item.get("class") or "").strip()
            label = mapped_label(config, "urbansound8k", source_label)
            if label is None:
                continue
            fold = int(item["fold"])
            filename = item["slice_file_name"]
            official_path = root / "audio" / f"fold{fold}" / filename
            flattened_path = root / f"fold{fold}" / filename
            path = official_path if official_path.is_file() else flattened_path
            if not path.is_file():
                raise FileNotFoundError(f"UrbanSound8K audio not found: {path}")
            duration, rate, channels = audio_info(path)
            yield {
                "path": path.resolve().as_posix(),
                "label": label,
                "source": "urbansound8k",
                "source_id": item.get("fsID") or filename.split("-")[0],
                "fold": fold,
                "split": split_for(config, "urbansound8k", fold),
                "duration_seconds": f"{duration:.6f}",
                "sample_rate": rate,
                "channels": channels,
            }


def write_manifests(rows: list[dict[str, Any]], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, selected in {
        "all": rows,
        "train": [row for row in rows if row["split"] == "train"],
        "validation": [row for row in rows if row["split"] == "validation"],
        "test": [row for row in rows if row["split"] == "test"],
    }.items():
        destination = output_dir / f"{name}.csv"
        with destination.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(selected)
        print(f"Wrote {len(selected):>5} rows to {destination}")


def enforce_source_safe_splits(rows: list[dict[str, Any]]) -> None:
    """Keep every original source in one split, protecting test data first."""
    priority = {"train": 0, "validation": 1, "test": 2}
    chosen: dict[tuple[str, str], str] = {}
    for row in rows:
        key = (row["source"], row["source_id"])
        current = chosen.get(key)
        if current is None or priority[row["split"]] > priority[current]:
            chosen[key] = row["split"]
    moved = 0
    affected: set[tuple[str, str]] = set()
    for row in rows:
        key = (row["source"], row["source_id"])
        safe_split = chosen[key]
        if row["split"] != safe_split:
            row["split"] = safe_split
            moved += 1
            affected.add(key)
    if moved:
        print(
            f"Moved {moved} clips from {len(affected)} shared source IDs "
            "to prevent split leakage"
        )


def main() -> None:
    args = parse_args()
    if args.esc50 is None and args.urbansound8k is None:
        raise SystemExit("Provide --esc50 and/or --urbansound8k")
    config = json.loads(args.config.read_text(encoding="utf-8"))
    rows: list[dict[str, Any]] = []
    if args.esc50:
        rows.extend(esc50_rows(args.esc50.resolve(), config))
    if args.urbansound8k:
        rows.extend(urbansound_rows(args.urbansound8k.resolve(), config))
    enforce_source_safe_splits(rows)
    rows.sort(key=lambda row: (row["split"], row["source"], row["label"], row["path"]))
    write_manifests(rows, args.output_dir)


if __name__ == "__main__":
    main()
