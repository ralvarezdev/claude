---
name: benchmark-monitor
description: Follow a running benchmark or long job without inflating the session context. Reads a bounded status file instead of logs, picks a safe poll cadence, and reports in five lines. Use when asked to watch progress, poll a job, or check whether a run finished.
---

# Benchmark monitor

State lives in a file, not in the chat. The runner — not the agent — writes
`/tmp/<run>/status.json` with `total`, `done`, `failed`, `current_trial`,
`elapsed_s` and `last_error`. The agent reads that file and never the full log.

## Procedure

1. Find the status file. If it does not exist, create it with the runner before
   starting: never poll a log.
2. Read only what is needed:

   ```bash
   jq -c '{done: ([.trials[] | select(.status != "pending")] | length),
           total: (.trials | length),
           fails: [.trials[] | select(.status == "fail") | .id]}' /tmp/<run>/status.json
   ```

3. Report in ≤5 lines: total, done, failed, ETA and the first suggested action.
   No table of the N trials.
4. Cadence: **<5 min or >60 min, never in between**. Between the 5-minute TTL and
   twice that, every poll pays for the whole context. Prefer `/loop 5m` (it fires
   at 4m45s on purpose) over a `sleep` in `Bash`, which occupies a whole turn.
5. Forbidden: `cat`, `tail` or `less` on `*.output`, JSONL transcripts or any log
   over 200 lines. If a detail is needed, a bounded `grep` with `| head -20`.

## When done

One paragraph with the aggregate result and the artifact path. Never dump the full
trial table: that belongs in the file, and the file is not read.
