"""Audit Smart Ear manifests for balance, missing audio, and source leakage."""

from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--fail-on-leakage", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    with args.manifest.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise SystemExit("Manifest contains no recordings")

    missing = [row["path"] for row in rows if not Path(row["path"]).is_file()]
    counts = Counter((row["split"], row["label"]) for row in rows)
    durations: Counter[tuple[str, str]] = Counter()
    sources: defaultdict[tuple[str, str], set[str]] = defaultdict(set)
    source_splits: defaultdict[tuple[str, str], set[str]] = defaultdict(set)
    for row in rows:
        key = (row["split"], row["label"])
        durations[key] += float(row["duration_seconds"])
        sources[key].add(row["source_id"])
        source_splits[(row["source"], row["source_id"])].add(row["split"])

    print(f"Recordings: {len(rows)}")
    print(f"Missing files: {len(missing)}")
    print("\nSplit/class summary:")
    print(f"{'split':<12} {'label':<20} {'clips':>7} {'sources':>8} {'minutes':>9}")
    for split, label in sorted(counts):
        key = (split, label)
        print(
            f"{split:<12} {label:<20} {counts[key]:>7} "
            f"{len(sources[key]):>8} {durations[key] / 60:>9.1f}"
        )

    leaked = {key: value for key, value in source_splits.items() if len(value) > 1}
    print(f"\nSource IDs crossing splits: {len(leaked)}")
    for (source, source_id), splits in list(sorted(leaked.items()))[:20]:
        print(f"  {source}:{source_id} -> {', '.join(sorted(splits))}")
    if missing:
        print("\nFirst missing files:")
        for path in missing[:20]:
            print(f"  {path}")
    if missing or (args.fail_on_leakage and leaked):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
