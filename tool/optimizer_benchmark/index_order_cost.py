#!/usr/bin/env python3
"""Alternate fresh-process AOT samples for optimizer item 6.

The probe is compiled twice: once against the accepted item 3 tree and once
against the candidate. This script only runs those binaries. It does not accept
the item.
"""

import json
import subprocess
import sys
from pathlib import Path

MODES = ["index", "rowid", "sort", "update", "wide"]


def run(binary: Path, mode: str, rows: int) -> tuple[int, int]:
    completed = subprocess.run(
        [str(binary), mode, str(rows)],
        check=True,
        text=True,
        capture_output=True,
    )
    elapsed, checksum = completed.stdout.strip().split()
    return int(elapsed), int(checksum)


def median(values: list[int]) -> float:
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return float(ordered[mid])
    return (ordered[mid - 1] + ordered[mid]) / 2


def main() -> None:
    baseline = Path(sys.argv[1])
    candidate = Path(sys.argv[2])
    rows = int(sys.argv[3])
    pairs = int(sys.argv[4])
    output = Path(sys.argv[5])
    samples = []
    for mode in MODES:
        for pair in range(pairs):
            order = (
                [("baseline", baseline), ("candidate", candidate)]
                if pair % 2 == 0
                else [("candidate", candidate), ("baseline", baseline)]
            )
            for label, binary in order:
                elapsed, checksum = run(binary, mode, rows)
                samples.append(
                    {
                        "mode": mode,
                        "pair": pair,
                        "label": label,
                        "microseconds": elapsed,
                        "checksum": checksum,
                    }
                )
    summary = {}
    for mode in MODES:
        base = [s["microseconds"] for s in samples if s["mode"] == mode and s["label"] == "baseline"]
        cand = [s["microseconds"] for s in samples if s["mode"] == mode and s["label"] == "candidate"]
        checks = {s["checksum"] for s in samples if s["mode"] == mode}
        summary[mode] = {
            "baseline_median_us": median(base),
            "candidate_median_us": median(cand),
            "median_ratio_candidate_over_baseline": median(cand) / median(base),
            "checksums": sorted(checks),
            "samples": len(base),
        }
    output.write_text(json.dumps({"rows": rows, "pairs": pairs, "summary": summary, "samples": samples}, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
