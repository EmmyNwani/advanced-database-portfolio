#!/bin/bash
# Runs once, when the primary's data directory is first created.
# Creates the role the replica connects as, and allows it to stream WAL.
set -e
psql -v ON_ERROR_STOP=1 -U postgres -c "CREATE ROLE replicator WITH REPLICATION LOGIN;"
echo "host replication replicator all trust" >> "$PGDATA/pg_hba.conf"
