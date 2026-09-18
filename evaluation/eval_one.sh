#!/bin/bash
# Re-evaluate ONE already-generated instance from lane-3-colab-gpu/predictions.jsonl
# without touching Colab — reuses the existing patch, so this is just the
# evaluation half of the pipeline, safe to run repeatedly for a live demo.
#
# Usage: ./evaluation/eval_one.sh <instance_id>
# e.g.:  ./evaluation/eval_one.sh sympy__sympy-23950
#
# No --cache_level flag: this installed swebench version doesn't have one
# (confirmed - passing it errors with "unrecognized arguments"). Image reuse
# happens automatically via Docker's own layer cache — if the instance's
# image already exists locally (check `docker images`), the harness skips
# straight to applying the patch + running tests, no flag needed. Verified:
# a cached instance evaluates in ~20s instead of a multi-minute image pull.
set -e

INSTANCE_ID="$1"
if [ -z "$INSTANCE_ID" ]; then
  echo "Usage: $0 <instance_id>"
  echo "Run 'python3 evaluation/list_instances.py' to see the 15 available instances."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRED_FILE="$REPO_ROOT/lane-3-colab-gpu/predictions.jsonl"
TMP_PRED="/tmp/predictions_${INSTANCE_ID//\//__}.jsonl"

MATCH=$(grep "\"instance_id\": \"$INSTANCE_ID\"" "$PRED_FILE" || true)
if [ -z "$MATCH" ]; then
  echo "No prediction found for $INSTANCE_ID in $PRED_FILE"
  echo "Run 'python3 evaluation/list_instances.py' to see valid instance_ids."
  exit 1
fi

echo "$MATCH" > "$TMP_PRED"
echo "Extracted existing patch for $INSTANCE_ID -> $TMP_PRED"
echo "Running evaluation (image reused automatically if already cached)..."

"$REPO_ROOT/.venv-eval/bin/python" -m swebench.harness.run_evaluation \
  --dataset_name SWE-bench/SWE-bench_Verified \
  --split test \
  --predictions_path "$TMP_PRED" \
  --max_workers 1 \
  --run_id "live-demo-${INSTANCE_ID//\//__}"
