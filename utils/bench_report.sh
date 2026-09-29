#!/usr/bin/env bash
# bench_report.sh - spusti ./chess-static bench 3x, vypise median NPS + profilovy
# rozpad a ulozi report do tests/reports/bench_latest.txt.
# Pouzitie: bash utils/bench_report.sh [ENGINE] [RUNS]
set -u

ENGINE="${1:-./chess-static}"
RUNS="${2:-3}"
REPORT="tests/reports/bench_latest.txt"
mkdir -p tests/reports

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for i in $(seq 1 "$RUNS"); do
    printf "2\nbench\nquit\n" | "$ENGINE" > "$TMP/run_$i.txt" 2>&1
done

# Vyber median run podla NPS
for i in $(seq 1 "$RUNS"); do
    nps=$(grep -oP 'bench: nodes=\d+ time_ms=\d+ nps=\K\d+' "$TMP/run_$i.txt" | head -1)
    echo "$nps $i"
done | sort -n > "$TMP/nps.txt"

med_idx=$(sed -n "$(( (RUNS + 2) / 2 ))p" "$TMP/nps.txt" | awk '{print $2}')
med_nps=$(sed -n "$(( (RUNS + 2) / 2 ))p" "$TMP/nps.txt" | awk '{print $1}')
min_nps=$(head -1 "$TMP/nps.txt" | awk '{print $1}')
max_nps=$(tail -1 "$TMP/nps.txt" | awk '{print $1}')

{
    echo "bench-report: engine=$ENGINE runs=$RUNS date=$(date -Iseconds)"
    grep -h '^bench:' "$TMP"/run_*.txt | sed 's/^/  run: /'
    echo "median_nps=$med_nps min_nps=$min_nps max_nps=$max_nps"
    echo "spread_pct=$(( max_nps > 0 ? (max_nps - min_nps) * 100 / max_nps : 0 ))"
    grep -h '^prof ' "$TMP/run_$med_idx.txt" | sed 's/^/  /'
} | tee "$REPORT"
