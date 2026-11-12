#!/usr/bin/env bash
#
# run_subdominator_batch.sh
#
# Runs `subdominator` against every split input file (xaa, xab, xac, ...)
# in the current directory, one at a time (or with a small concurrency cap),
# instead of opening a separate terminal/tmux session per file.
#
# Each file's output goes to its own results_<name>/ directory, and all
# tool output (which has no built-in -silent flag) is redirected to a log
# file instead of your terminal, with colors disabled.
#
# RESUMABLE: every successfully completed file gets a marker in
# .subdominator_state/<file>.done. Re-running the script later (after a
# Ctrl-C, SSH drop, crash, etc.) automatically skips anything already
# marked done and continues with whatever's left. Use -f to ignore the
# markers and redo everything from scratch.
#
# Usage:
#   ./run_subdominator_batch.sh                 # sequential (1 at a time)
#   ./run_subdominator_batch.sh -p 3             # 3 files in parallel
#   ./run_subdominator_batch.sh -i "xa*"          # custom glob for input files
#   ./run_subdominator_batch.sh -p 3 -r 2 -t 15   # pass through retries/timeout
#   ./run_subdominator_batch.sh -f                # force re-run everything, ignore markers
#
set -uo pipefail
 
# ---------------------------
# Defaults (override via flags)
# ---------------------------
PARALLEL=1               # how many subdominator instances to run at once
INPUT_GLOB="x??"         # matches xaa, xab, ... xak (split -l / split -b naming)
TIMEOUT=10                # --timeout per request
RETRIES=1                 # --retries
CONCURRENCY=50             # subdominator's own -c (resource concurrency)
LOG_DIR="logs"
STATE_DIR=".subdominator_state"   # holds <file>.done markers for resuming
BIN="subdominator"
FORCE=0
 
usage() {
    cat <<EOF
Usage: $0 [-p parallel_jobs] [-i input_glob] [-t timeout] [-r retries] [-c resource_concurrency] [-f]
 
  -p   Number of split files to process in parallel (default: $PARALLEL)
  -i   Glob for input split files in the current dir (default: "$INPUT_GLOB")
  -t   Per-request timeout passed to subdominator (default: $TIMEOUT)
  -r   Retry count passed to subdominator (default: $RETRIES)
  -c   subdominator's internal resource concurrency (default: $CONCURRENCY)
  -f   Force re-run: ignore .done markers and redo every file
 
Resuming:
  Re-running this script with no new flags automatically skips any file
  that already finished successfully on a previous run (tracked in
  $STATE_DIR/). Only unfinished/failed files are (re)run.
 
Example:
  $0 -p 3
EOF
    exit 1
}
 
while getopts "p:i:t:r:c:fh" opt; do
    case "$opt" in
        p) PARALLEL="$OPTARG" ;;
        i) INPUT_GLOB="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        r) RETRIES="$OPTARG" ;;
        c) CONCURRENCY="$OPTARG" ;;
        f) FORCE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done
 
if ! command -v "$BIN" >/dev/null 2>&1; then
    echo "[!] '$BIN' not found on PATH. Install/activate it first." >&2
    exit 1
fi
 
mkdir -p "$LOG_DIR" "$STATE_DIR"
 
# Collect input files matching the glob, excluding anything that isn't a
# regular file (e.g. the results_* dirs or the .7z/.txt/.md already there).
shopt -s nullglob
ALL_FILES=()
for f in $INPUT_GLOB; do
    [ -f "$f" ] && ALL_FILES+=("$f")
done
shopt -u nullglob
 
if [ "${#ALL_FILES[@]}" -eq 0 ]; then
    echo "[!] No input files matched glob '$INPUT_GLOB' in $(pwd)." >&2
    exit 1
fi
 
# Split into already-done (skip) vs remaining (to run), unless -f forces all.
FILES=()
SKIPPED=()
for f in "${ALL_FILES[@]}"; do
    if [ "$FORCE" -eq 0 ] && [ -f "${STATE_DIR}/${f}.done" ]; then
        SKIPPED+=("$f")
    else
        FILES+=("$f")
    fi
done
 
echo "[*] Found ${#ALL_FILES[@]} input file(s) total: ${ALL_FILES[*]}"
if [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo "[*] Already completed, skipping (use -f to force re-run): ${SKIPPED[*]}"
fi
 
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "[*] Nothing left to do — all files already completed. Use -f to force a full re-run."
    exit 0
fi
 
echo "[*] Remaining to run this pass: ${FILES[*]}"
echo "[*] Running with parallel=$PARALLEL, timeout=$TIMEOUT, retries=$RETRIES, concurrency=$CONCURRENCY"
echo "[*] Logs: $LOG_DIR/<file>.log   Results: results_<file>/   State: $STATE_DIR/<file>.done"
echo
 
run_one() {
    local file="$1"
    local out_dir="results_${file}"
    local log_file="${LOG_DIR}/${file}.log"
    local marker="${STATE_DIR}/${file}.done"
 
    mkdir -p "$out_dir"
    echo "[+] Starting: $file -> $out_dir  (log: $log_file)"
 
    "$BIN" \
        -dL "$file" \
        -oD "$out_dir" \
        --all \
        -t "$TIMEOUT" \
        -rt "$RETRIES" \
        -c "$CONCURRENCY" \
        -ss \
        -nc \
        > "$log_file" 2>&1
 
    local status=$?
    if [ $status -eq 0 ]; then
        # Only write the marker on a clean exit, so a crash/Ctrl-C/kill
        # never falsely marks a partial run as complete — the next
        # invocation of this script will simply retry this file.
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "$marker"
        echo "[=] Done: $file (exit 0) — marked complete"
    else
        rm -f "$marker"
        echo "[!] FAILED: $file (exit $status) — check $log_file, will retry on next run"
    fi
    return $status
}
export -f run_one
export BIN LOG_DIR STATE_DIR TIMEOUT RETRIES CONCURRENCY
 
# ---------------------------
# Run sequentially or with a bounded number of parallel jobs
# ---------------------------
if [ "$PARALLEL" -le 1 ]; then
    FAIL_COUNT=0
    for file in "${FILES[@]}"; do
        run_one "$file" || FAIL_COUNT=$((FAIL_COUNT + 1))
    done
else
    # Simple job pool: cap concurrently running subdominator instances at $PARALLEL
    running=0
    pids=()
    FAIL_COUNT=0
    for file in "${FILES[@]}"; do
        run_one "$file" &
        pids+=($!)
        running=$((running + 1))
        if [ "$running" -ge "$PARALLEL" ]; then
            wait -n || FAIL_COUNT=$((FAIL_COUNT + 1))
            running=$((running - 1))
        fi
    done
    # Drain remaining background jobs
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
fi
 
echo
echo "===== Batch complete ====="
echo "Results under:  results_<file>/"
echo "Logs under:      $LOG_DIR/"
if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
    echo "[!] ${FAIL_COUNT} file(s) reported a non-zero exit — check their logs."
    exit 1
fi
