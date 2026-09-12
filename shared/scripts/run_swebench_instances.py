#!/usr/bin/env python3
"""
Drive Claude Code (headless `-p` mode) against SWE-bench Verified instances,
using whatever local/open-weight model is currently reachable through the
litellm proxy pointed to by ANTHROPIC_BASE_URL (see scripts/use-local-llm.sh).

Environment-agnostic on purpose: this same script runs unmodified on Colab
(native litellm+Ollama), the GCP VM (docker-compose litellm + native Ollama),
or local WSL - it only needs ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN already
exported and the `claude` CLI on PATH.

This script only PRODUCES predictions (predictions.jsonl: instance_id,
model_name_or_path, model_patch). It does NOT evaluate them - SWE-bench's
evaluation harness spins up a Docker container per instance to run
FAIL_TO_PASS/PASS_TO_PASS, and Docker-in-Docker does not work inside Colab's
sandbox. Run the evaluation step separately on a Docker-capable machine:

  pip install swebench
  python -m swebench.harness.run_evaluation \\
    --dataset_name SWE-bench/SWE-bench_Verified \\
    --predictions_path predictions.jsonl \\
    --max_workers 1 \\
    --run_id <run-id>

Dataset must be SWE-bench/SWE-bench_Verified, not princeton-nlp/SWE-bench_Verified:
the latter lacks the `image` field the evaluation harness requires (KeyError:
'image' in make_test_spec otherwise). Both work fine for generation (only
problem_statement/repo/base_commit/instance_id are used here) but using the
same dataset name throughout avoids the trap entirely.

Resumable: re-running with the same --output skips instance_ids already
present in that file, so a Colab disconnect mid-run doesn't lose progress.

For each instance this also captures Claude Code's own session transcript
(it logs one to disk even in headless -p mode, under
~/.claude/projects/<sanitized-cwd>/*.jsonl) into logs/<instance_id>/ as:
  - transcript.jsonl   raw copy of Claude Code's own session log
  - reasoning.md        human-readable rendering (thinking/tool_use/tool_result/text)
  - stats.json          tool-call counts, timing, patch shape - for the report
This is the raw material for the report's per-instance analysis (what the
model reasoned, why it likely succeeded/failed, what could improve) - that
judgment call is made by reading these afterward, not computed here.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def sh(cmd, cwd=None, timeout=None, check=True):
    return subprocess.run(
        cmd, cwd=cwd, timeout=timeout, check=check, capture_output=True, text=True
    )


def ensure_repo(repo, repos_dir):
    """Clone the upstream repo once; reused across instances that share it."""
    repo_dir = repos_dir / repo.replace("/", "__")
    if not repo_dir.exists():
        url = f"https://github.com/{repo}.git"
        sh(["git", "clone", url, str(repo_dir)])
    return repo_dir


def checkout_worktree(repo_dir, base_commit, work_dir):
    """Give each instance its own clean checkout via git worktree (cheap, no
    re-clone) rather than repeatedly mutating one shared checkout."""
    if work_dir.exists():
        sh(["git", "worktree", "remove", "--force", str(work_dir)], cwd=repo_dir, check=False)
    # Shallow-fetch just this commit in case the initial clone didn't reach it
    # (some SWE-bench base_commits are older than a default clone's history).
    sh(["git", "fetch", "--depth", "1", "origin", base_commit], cwd=repo_dir, check=False)
    sh(["git", "worktree", "add", "--detach", str(work_dir), base_commit], cwd=repo_dir)


def build_prompt(instance):
    # Tightened after an observed failure mode (sympy__sympy-22914, Colab
    # qwen3:8b run): the model wrote a brand-new file containing the issue's
    # own suggested code snippet, without ever calling Read/Grep/Glob to find
    # where that code actually already lived. The original wording ("explore
    # the codebase as needed") was too vague for a small local model to act
    # on. This version makes search-before-edit an explicit numbered step and
    # nudges Edit (which requires having Read the target first) over Write
    # (which doesn't). Applies identically to all instances/repos - nothing
    # here is repo-specific.
    return (
        "You are fixing a real bug in this repository, checked out at the "
        "exact commit where the bug is present.\n\n"
        "Follow this process:\n"
        "1. Read the issue below and identify the specific class/function/file it refers to.\n"
        "2. Use Grep or Glob to locate where that code actually lives in this repository "
        "BEFORE editing anything. Do not assume it doesn't exist.\n"
        "3. Read the existing file(s) you found in full.\n"
        "4. Make the smallest possible edit to those existing file(s) using Edit, not Write. "
        "Only use Write to create a brand-new file if your search in step 2 confirms no "
        "existing file should contain this change.\n"
        "5. Do NOT modify test files.\n"
        "6. When the fix is complete, stop - do not ask questions, this is a non-interactive session.\n\n"
        f"--- ISSUE ---\n{instance['problem_statement']}\n--- END ISSUE ---"
    )


def run_claude(work_dir, prompt, timeout, allowed_tools):
    """`-p` is Claude Code's headless/print mode: no TTY, no interactive
    approval prompts - tools inside --allowedTools run automatically, tools
    outside it are simply unavailable. Verify this against your installed
    Claude Code version (`claude --help`) before a full 10-instance run -
    flag syntax has changed across versions and is worth a 1-instance smoke
    test first (see DECISIONS.md's own practice of not assuming CLI behavior)."""
    try:
        proc = subprocess.run(
            ["claude", "-p", prompt, "--allowedTools", allowed_tools],
            cwd=work_dir,
            env=os.environ.copy(),
            timeout=timeout,
            capture_output=True,
            text=True,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as e:
        # Best-effort: whatever edits were made before the timeout still get
        # diffed and submitted as the patch - an incomplete fix is still a
        # valid (if likely unresolved) prediction, not a reason to drop the
        # instance entirely.
        return -1, (e.stdout or ""), (e.stderr or "")


def get_diff(work_dir):
    # Intent-to-add: `git diff` alone ignores untracked files entirely, so a
    # fix that creates a new file (rather than editing an existing one) would
    # silently produce an empty patch without this.
    sh(["git", "add", "-A", "-N", "."], cwd=work_dir, check=False)
    proc = sh(["git", "diff"], cwd=work_dir, check=False)
    return proc.stdout


def find_transcript(work_dir, since_ts):
    """Claude Code logs every session to ~/.claude/projects/<dir>/*.jsonl,
    where <dir> is the absolute cwd with both '/' and '_' replaced by '-'
    (verified empirically: .../worktrees/sympy__sympy-22914 produced project
    dir '-content-swebench-work-worktrees-sympy--sympy-22914'). Falls back to
    the most-recently-modified project dir touched during this call if that
    exact name doesn't match, so a Claude Code version change doesn't silently
    lose logging."""
    projects_root = Path.home() / ".claude" / "projects"
    if not projects_root.is_dir():
        return None
    candidate_name = str(work_dir).replace("/", "-").replace("_", "-")
    session_dir = projects_root / candidate_name
    if not session_dir.is_dir():
        candidates = [
            d for d in projects_root.iterdir()
            if d.is_dir() and d.stat().st_mtime >= since_ts
        ]
        session_dir = max(candidates, key=lambda d: d.stat().st_mtime) if candidates else None
    if session_dir is None:
        return None
    jsonl_files = sorted(session_dir.glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
    return jsonl_files[-1] if jsonl_files else None


def parse_transcript(path):
    """Flatten Claude Code's session JSONL into a simple list of
    {role, type, ...} entries - one per thinking block, tool_use, tool_result,
    or text block. Non-message record types (queue-operation, attachment,
    etc.) are skipped; they're session bookkeeping, not reasoning content."""
    entries = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("type") not in ("user", "assistant"):
            continue
        msg = rec.get("message", {})
        role = msg.get("role")
        content = msg.get("content")
        if isinstance(content, str):
            entries.append({"role": role, "type": "text", "text": content})
        elif isinstance(content, list):
            for block in content:
                bt = block.get("type")
                if bt == "text":
                    entries.append({"role": role, "type": "text", "text": block.get("text", "")})
                elif bt == "thinking":
                    entries.append({"role": role, "type": "thinking", "text": block.get("thinking", "")})
                elif bt == "tool_use":
                    entries.append({"role": role, "type": "tool_use", "name": block.get("name"), "input": block.get("input")})
                elif bt == "tool_result":
                    c = block.get("content")
                    entries.append({"role": role, "type": "tool_result", "text": c if isinstance(c, str) else json.dumps(c)})
    return entries


def render_reasoning_markdown(instance_id, entries):
    lines = [f"# Reasoning trace: {instance_id}\n"]
    for e in entries:
        if e["type"] == "thinking":
            lines.append(f"**[thinking]**\n\n{e['text']}\n")
        elif e["type"] == "tool_use":
            lines.append(f"**[tool_use: {e['name']}]**\n\n```\n{json.dumps(e['input'])[:2000]}\n```\n")
        elif e["type"] == "tool_result":
            lines.append(f"**[tool_result]**\n\n```\n{e['text'][:1000]}\n```\n")
        elif e["type"] == "text":
            lines.append(f"**[{e['role']} text]**\n\n{e['text']}\n")
    return "\n".join(lines)


def compute_stats(entries, patch, elapsed, rc):
    tool_counts = {}
    for e in entries:
        if e["type"] == "tool_use":
            tool_counts[e["name"]] = tool_counts.get(e["name"], 0) + 1
    thinking_chars = sum(len(e["text"]) for e in entries if e["type"] == "thinking")
    new_files = patch.count("\nnew file mode")
    files_touched = patch.count("\ndiff --git")
    return {
        "elapsed_seconds": round(elapsed, 1),
        "timed_out": rc == -1,
        "tool_call_counts": tool_counts,
        "total_tool_calls": sum(tool_counts.values()),
        "searched_before_editing": any(
            n in tool_counts for n in ("Grep", "Glob")
        ) and (tool_counts.get("Grep", 0) + tool_counts.get("Glob", 0)) > 0,
        "thinking_chars": thinking_chars,
        "patch_chars": len(patch),
        "files_touched": files_touched,
        "new_files_created": new_files,
    }


def save_reasoning_log(instance_id, work_dir, logs_dir, since_ts, patch, elapsed, rc):
    inst_log_dir = logs_dir / instance_id.replace("/", "__")
    inst_log_dir.mkdir(parents=True, exist_ok=True)
    transcript_path = find_transcript(work_dir, since_ts)
    entries = []
    if transcript_path is not None:
        (inst_log_dir / "transcript.jsonl").write_text(transcript_path.read_text())
        entries = parse_transcript(transcript_path)
        (inst_log_dir / "reasoning.md").write_text(render_reasoning_markdown(instance_id, entries))
    else:
        (inst_log_dir / "reasoning.md").write_text(
            f"# Reasoning trace: {instance_id}\n\n(No Claude Code session transcript found - "
            "logging convention may have changed; see find_transcript().)\n"
        )
    stats = compute_stats(entries, patch, elapsed, rc)
    (inst_log_dir / "stats.json").write_text(json.dumps(stats, indent=2))
    return stats


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dataset", default="SWE-bench/SWE-bench_Verified")
    ap.add_argument("--split", default="test")
    ap.add_argument("--num-instances", type=int, default=10)
    ap.add_argument("--instance-ids", nargs="*", default=None,
                     help="Explicit instance_id list; overrides --num-instances")
    ap.add_argument("--output", default="predictions.jsonl")
    ap.add_argument("--logs-dir", default="./logs",
                     help="Per-instance reasoning trace + stats go here")
    ap.add_argument("--model-name-or-path", default="local-qwen3",
                     help="Label written into predictions.jsonl - keep distinct "
                          "per run (e.g. 'colab-qwen3-8b' vs 'gcp-qwen3-4b') so "
                          "results from both lanes stay attributable.")
    ap.add_argument("--timeout", type=int, default=900,
                     help="Per-instance wall-clock budget in seconds")
    ap.add_argument("--allowed-tools", default="Read,Write,Edit,Bash,Grep,Glob")
    ap.add_argument("--work-root", default="./swebench_work")
    args = ap.parse_args()

    from datasets import load_dataset
    ds = load_dataset(args.dataset, split=args.split)

    if args.instance_ids:
        wanted = set(args.instance_ids)
        instances = [r for r in ds if r["instance_id"] in wanted]
    else:
        instances = list(ds)[: args.num_instances]

    work_root = Path(args.work_root).resolve()
    repos_dir = work_root / "repos"
    worktrees_dir = work_root / "worktrees"
    repos_dir.mkdir(parents=True, exist_ok=True)
    worktrees_dir.mkdir(parents=True, exist_ok=True)
    logs_dir = Path(args.logs_dir).resolve()
    logs_dir.mkdir(parents=True, exist_ok=True)

    out_path = Path(args.output)
    done_ids = set()
    if out_path.exists():
        for line in out_path.read_text().splitlines():
            if line.strip():
                done_ids.add(json.loads(line)["instance_id"])

    with out_path.open("a") as out_f:
        for i, inst in enumerate(instances):
            iid = inst["instance_id"]
            if iid in done_ids:
                print(f"[{i + 1}/{len(instances)}] skip {iid} (already in {out_path})")
                continue
            print(f"[{i + 1}/{len(instances)}] {iid} ...", flush=True)
            t0 = time.time()
            patch = ""
            stats = {}
            try:
                repo_dir = ensure_repo(inst["repo"], repos_dir)
                work_dir = worktrees_dir / iid.replace("/", "__")
                checkout_worktree(repo_dir, inst["base_commit"], work_dir)
                prompt = build_prompt(inst)
                rc, stdout, stderr = run_claude(work_dir, prompt, args.timeout, args.allowed_tools)
                patch = get_diff(work_dir)
                if rc == -1:
                    print(f"  (timed out after {args.timeout}s - submitting partial diff)")
                elapsed = time.time() - t0
                stats = save_reasoning_log(iid, work_dir, logs_dir, t0, patch, elapsed, rc)
                print(f"  tool calls: {stats['tool_call_counts']} | "
                      f"searched before editing: {stats['searched_before_editing']} | "
                      f"new files created: {stats['new_files_created']}")
            except Exception as e:
                print(f"  ERROR: {e}", file=sys.stderr)
            elapsed = time.time() - t0
            print(f"  done in {elapsed:.0f}s, patch length {len(patch)} chars", flush=True)
            out_f.write(json.dumps({
                "instance_id": iid,
                "model_name_or_path": args.model_name_or_path,
                "model_patch": patch,
            }) + "\n")
            out_f.flush()

    print(f"\nWrote predictions to {out_path}")
    print(f"Per-instance reasoning traces + stats written under {logs_dir}/<instance_id>/")
    print("Next: run swebench's evaluation harness on a Docker-capable machine, e.g.")
    print("  python -m swebench.harness.run_evaluation \\")
    print(f"    --dataset_name {args.dataset} --predictions_path {out_path} \\")
    print("    --max_workers 1 --run_id <run-id>")


if __name__ == "__main__":
    main()
