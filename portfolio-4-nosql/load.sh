#!/usr/bin/env bash
# MIT 8103 Portfolio 4: start MongoDB and load it from the PostgreSQL database
#
# Usage:  ./load.sh
#
# 1. Starts a MongoDB 7 container (mongo-bank) if it is not already running. It listens on
#    localhost only, and this folder is mounted read-only at /p4 so mongosh can run the scripts.
# 2. Recreates the paybridge database with its collections and validators (setup.js).
# 3. Streams both exports from PostgreSQL straight into mongoimport: no data files are written.
#
# Requires the pg-bank container with the Portfolio 1 schema and Portfolio 2 seed loaded.

set -euo pipefail

PG="${PG_CONTAINER:-pg-bank}"
PG_DB="${PG_DB:-paybridge}"
MONGO="${MONGO_CONTAINER:-mongo-bank}"
MONGO_PORT="${MONGO_PORT:-27017}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if ! docker ps --format '{{.Names}}' | grep -qx "$MONGO"; then
    if docker ps -a --format '{{.Names}}' | grep -qx "$MONGO"; then
        docker start "$MONGO" > /dev/null
    else
        docker run --name "$MONGO" -d -p "127.0.0.1:$MONGO_PORT:27017" -v "$DIR:/p4:ro" mongo:7 > /dev/null
    fi
    echo "Waiting for MongoDB..."
    until docker exec "$MONGO" mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1; do sleep 1; done
fi
docker exec "$MONGO" mongosh --quiet --eval 'print("MongoDB " + db.version())'

docker exec "$MONGO" mongosh --quiet --file /p4/setup.js

export_to() {   # export_to <sql file> <collection>
    docker exec -i "$PG" psql -U postgres -d "$PG_DB" -X -q -At < "$DIR/$1" \
      | docker exec -i "$MONGO" mongoimport --quiet --db paybridge --collection "$2" --mode insert
}
export_to export_events.sql   activity_events
export_to export_profiles.sql customer_profiles

docker exec "$MONGO" mongosh --quiet paybridge --eval '
  print("activity_events:   " + db.activity_events.countDocuments());
  print("customer_profiles: " + db.customer_profiles.countDocuments());'
