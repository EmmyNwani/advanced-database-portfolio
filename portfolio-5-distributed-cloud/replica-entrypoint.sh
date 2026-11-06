#!/bin/bash
# Entrypoint for the replica. On first start it clones the primary with pg_basebackup:
#   -R              writes standby.signal and primary_conninfo, so the server starts as a standby
#   -X stream       streams the WAL generated during the copy, so the clone is consistent
#   -C -S replica1  creates the physical replication slot replica1 on the primary, so the primary
#                   keeps any WAL the replica has not received yet
# application_name=replica1 is the name the primary uses for this standby
# (pg_stat_replication, synchronous_standby_names).
set -e
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
    until gosu postgres pg_basebackup -h pg-primary -U replicator -D "$PGDATA" \
            -R -X stream -C -S replica1 \
            -d "host=pg-primary user=replicator application_name=replica1"; do
        echo "waiting for primary..."
        sleep 1
    done
fi

exec gosu postgres postgres -c hot_standby=on -c cluster_name=pg-replica
