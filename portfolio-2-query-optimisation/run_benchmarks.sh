#!/usr/bin/env bash
# MIT 8103 Portfolio 2: capture execution plans and timings for queries.sql
#
# Usage:  ./run_benchmarks.sh before     (no secondary indexes yet)
#         ./run_benchmarks.sh after      (after running indexes.sql)
#
# For each query in queries.sql (split on the "-- Qn:" headers) this:
#   - runs EXPLAIN (ANALYZE, BUFFERS) three times and keeps the median time
#   - saves the full plan of the median run to plans/<phase>/qN.txt
#   - saves the query result to outputs/qN-result.txt (before phase only)
# and writes plans/<phase>/summary.txt and plans/<phase>/environment.txt.

set -euo pipefail

PHASE="${1:-}"
if [[ "$PHASE" != "before" && "$PHASE" != "after" ]]; then
    echo "Usage: $0 before|after" >&2
    exit 1
fi

CONTAINER="${PG_CONTAINER:-pg-bank}"
DB="${PG_DB:-paybridge}"
RUNS=3

DIR="$(cd "$(dirname "$0")" && pwd)"
PLANS="$DIR/plans/$PHASE"
OUTPUTS="$DIR/outputs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PLANS" "$OUTPUTS"

psql_run() {
    docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -X -q "$@"
}

# Split queries.sql into q1.sql ... q6.sql, dropping comment lines
awk -v out="$WORK" '
    /^-- Q[0-9]+:/ { n = $2; gsub(/[^0-9]/, "", n); file = out "/q" n ".sql"; next }
    /^--/          { next }
    file != ""     { print > file }
' "$DIR/queries.sql"

echo "== $PHASE: VACUUM ANALYZE"
psql_run -c "VACUUM ANALYZE;"

{
    echo "Phase: $PHASE"
    echo "Captured: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Host: $(uname -sm)"
    psql_run -At -c "SELECT version();"
    psql_run -At -c "SELECT name || ' = ' || setting || coalesce(' ' || unit, '') FROM pg_settings
                     WHERE name IN ('shared_buffers', 'work_mem', 'effective_cache_size',
                                    'random_page_cost', 'max_parallel_workers_per_gather')
                     ORDER BY name;"
    echo
    echo "Secondary indexes present:"
    psql_run -At -c "SELECT indexname FROM pg_indexes WHERE schemaname = 'public'
                     AND indexname LIKE 'idx_%' ORDER BY 1;" | sed 's/^/  /'
} > "$PLANS/environment.txt"

printf "%-4s %12s %12s %12s %12s\n" "query" "run1_ms" "run2_ms" "run3_ms" "median_ms" > "$PLANS/summary.txt"

for q in $(ls "$WORK" | sort); do
    name="${q%.sql}"
    echo "== $PHASE: $name"
    times=()
    for run in $(seq 1 "$RUNS"); do
        { printf 'EXPLAIN (ANALYZE, BUFFERS)\n'; cat "$WORK/$q"; } | psql_run > "$WORK/$name-run$run.txt"
        t=$(awk '/Execution Time:/ { print $3 }' "$WORK/$name-run$run.txt")
        times+=("$t")
        echo "   run $run: $t ms"
    done

    median=$(printf '%s\n' "${times[@]}" | sort -n | sed -n '2p')
    for run in $(seq 1 "$RUNS"); do
        if [[ "${times[$((run - 1))]}" == "$median" ]]; then
            cp "$WORK/$name-run$run.txt" "$PLANS/$name.txt"
            break
        fi
    done
    printf "%-4s %12s %12s %12s %12s\n" "$name" "${times[@]}" "$median" >> "$PLANS/summary.txt"

    if [[ "$PHASE" == "before" ]]; then
        psql_run < "$WORK/$q" > "$OUTPUTS/$name-result.txt"
    fi
done

echo
cat "$PLANS/summary.txt"
echo
echo "Plans saved to plans/$PHASE/"
