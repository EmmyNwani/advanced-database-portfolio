#!/usr/bin/env bash
# MIT 8103 Portfolio 4: reload MongoDB and run every demo, writing outputs/NN-*.txt
#
# Usage:  ./run_demos.sh
#
# The demos change data (demo 3 updates profiles, demo 5 creates indexes), so the script
# reloads everything first with load.sh. Every run therefore starts from the same state.

set -euo pipefail

MONGO="${MONGO_CONTAINER:-mongo-bank}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/outputs"
mkdir -p "$OUT"

"$DIR/load.sh" | tee "$OUT/00-load.txt"

for demo in 01_documents 02_validation 03_queries 04_aggregations 05_indexes 06_sessions; do
    name="${demo/_/-}"
    echo "== $demo"
    docker exec "$MONGO" mongosh --quiet --file "/p4/$demo.js" > "$OUT/$name.txt" 2>&1
done
echo "Outputs written to outputs/"
