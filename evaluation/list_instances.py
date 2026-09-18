#!/usr/bin/env python3
"""
Quick picker over the 15 already-generated SWE-bench Verified instances, for
choosing one to re-evaluate live (e.g. in front of a professor) without
regenerating anything in Colab - the patch already exists in
lane-3-colab-gpu/predictions.jsonl.

Usage:
    python3 evaluation/list_instances.py            # all 15, resolved first
    python3 evaluation/list_instances.py resolved    # filter by outcome
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "lane-3-colab-gpu" / "swebench_selected_instances_colab.json"
SUMMARIES = ROOT / "live-demo-data" / "run_summaries.json"

OUTCOME_ORDER = {"resolved": 0, "unresolved": 1, "timeout": 2, "hallucination": 3}
OUTCOME_ICON = {"resolved": "✅", "unresolved": "❌", "timeout": "⏱️", "hallucination": "\U0001f300"}


def main():
    filter_outcome = sys.argv[1].lower() if len(sys.argv) > 1 else None

    manifest = json.loads(MANIFEST.read_text())["instances"]
    summaries_by_id = {}
    if SUMMARIES.exists():
        for s in json.loads(SUMMARIES.read_text()):
            summaries_by_id[s["instance_id"]] = s.get("summary", "")

    rows = sorted(manifest, key=lambda r: OUTCOME_ORDER.get(r["outcome"], 9))
    if filter_outcome:
        rows = [r for r in rows if r["outcome"] == filter_outcome]

    for r in rows:
        icon = OUTCOME_ICON.get(r["outcome"], "?")
        summary = summaries_by_id.get(r["instance_id"], "")
        print(f"{icon} {r['instance_id']:35s} round={r['round']}  outcome={r['outcome']:13s}")
        if summary:
            print(f"   {summary[:160]}{'...' if len(summary) > 160 else ''}")
        print()

    if filter_outcome is None:
        resolved_count = sum(1 for r in manifest if r["outcome"] == "resolved")
        print(f"({resolved_count}/{len(manifest)} resolved — best picks for a guaranteed-good live eval demo)")


if __name__ == "__main__":
    main()
