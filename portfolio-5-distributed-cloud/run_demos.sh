#!/usr/bin/env bash
# MIT 8103 Portfolio 5: replication, consistency, failover and sharding demos
#
# Usage:  ./run_demos.sh
#
# Builds the cluster from scratch (docker compose down -v, then up), loads the Portfolio 1-3
# schema, seed data and functions into the PostgreSQL primary, and runs every demo, writing
# outputs/NN-*.txt. The run ends with the replica promoted and the old primary stopped.
# Remove everything afterwards with:  docker compose -f portfolio-5-distributed-cloud/docker-compose.yml down -v

# Several demos expect errors (writes to a standby, lost majority), so the script does not stop on them.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/outputs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

DC=(docker compose -f "$DIR/docker-compose.yml")
pp()   { "${DC[@]}" exec -T pg-primary psql -U postgres -d paybridge -X -q "$@" 2>&1; }   # primary
rp()   { "${DC[@]}" exec -T pg-replica psql -U postgres -d paybridge -X -q "$@" 2>&1; }   # replica
mgo()  { "${DC[@]}" exec -T "$1" mongosh --quiet --eval "$2" 2>&1; }
ts()   { date +%H:%M:%S; }
say()  { echo; echo "$(ts)  $*"; }
title() { echo "=== $*"; }

RECONCILE="SELECT count(*) AS mismatched_accounts FROM accounts a
  JOIN (SELECT account_id, SUM(CASE WHEN txn_type IN ('DEPOSIT','TRANSFER_IN','REVERSAL_IN') THEN amount ELSE -amount END) t
        FROM transactions GROUP BY account_id) l USING (account_id) WHERE a.balance <> l.t;"

wait_replica_caught_up() {
    for _ in $(seq 1 60); do
        lag=$(pp -At -c "SELECT pg_current_wal_lsn() - replay_lsn FROM pg_stat_replication WHERE application_name = 'replica1';")
        [[ "$lag" == "0" ]] && return 0
        sleep 1
    done
    echo "replica did not catch up" >&2; return 1
}

# ---------------------------------------------------------------------------
echo "== 00 setup"
{
    title "Build the cluster from scratch"
    "${DC[@]}" down -v --remove-orphans > /dev/null 2>&1
    "${DC[@]}" up -d --wait > /dev/null 2>&1
    "${DC[@]}" ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
    say "Load Portfolio 1 schema, Portfolio 2 seed and Portfolio 3 functions into the PRIMARY only"
    pp -f /p1/schema.sql > /dev/null
    pp -f /p2/seed.sql | tail -8
    pp -f /p3/transfer_funds.sql -f /p3/audit_trigger.sql | grep -v NOTICE
    wait_replica_caught_up
    say "Row counts read from the REPLICA, which received everything through replication"
    rp -c "SELECT (SELECT count(*) FROM customers) AS customers, (SELECT count(*) FROM accounts) AS accounts,
                  (SELECT count(*) FROM transfers) AS transfers, (SELECT count(*) FROM transactions) AS ledger_rows,
                  (SELECT sum(balance) FROM accounts) AS total_balance;"
    say "The same from the PRIMARY"
    pp -c "SELECT (SELECT count(*) FROM customers) AS customers, (SELECT count(*) FROM accounts) AS accounts,
                  (SELECT count(*) FROM transfers) AS transfers, (SELECT count(*) FROM transactions) AS ledger_rows,
                  (SELECT sum(balance) FROM accounts) AS total_balance;"
} > "$OUT/00-setup.txt"

# ---------------------------------------------------------------------------
echo "== 01 replication status"
{
    title "Replication status on the primary"
    pp -x -c "SELECT pid, usename, application_name, client_addr, state, sync_state,
                     sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag
              FROM pg_stat_replication;"
    title "Replication slot on the primary (keeps WAL until the replica has it)"
    pp -c "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;"
    title "The replica's view"
    rp -c "SELECT pg_is_in_recovery() AS is_standby, pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed;"
    rp -c "SELECT status, sender_host, slot_name FROM pg_stat_wal_receiver;"
    title "The primary's view of itself"
    pp -c "SELECT pg_is_in_recovery() AS is_standby, pg_current_wal_lsn() AS current_lsn;"
} > "$OUT/01-replication-status.txt"

# ---------------------------------------------------------------------------
echo "== 02 write propagation"
{
    title "A transfer committed on the primary appears on the replica"
    say "Before: account 9 on primary and replica"
    pp -At -c "SELECT 'primary: ' || balance FROM accounts WHERE account_id = 9;"
    rp -At -c "SELECT 'replica: ' || balance FROM accounts WHERE account_id = 9;"
    say "Primary: transfer_funds(6, 9, 1000.00)"
    pp -At -c "SELECT 'transfer ' || transfer_funds(6, 9, 1000.00);"
    pp -At -c "SELECT 'primary WAL position after the commit: ' || pg_current_wal_lsn();"
    say "Replica, read straight away"
    rp -At -c "SELECT 'replica: ' || balance || '  (replayed up to LSN ' || pg_last_wal_replay_lsn() || ')' FROM accounts WHERE account_id = 9;"
    sleep 1
    say "Replication lag reported by the primary"
    pp -c "SELECT application_name, replay_lsn, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
} > "$OUT/02-write-propagation.txt"

# ---------------------------------------------------------------------------
echo "== 03 read-only replica"
{
    title "The replica serves reads but refuses writes"
    say "Replica: a reporting query (top 3 balances by account type) runs normally"
    rp -c "SELECT type_code, account_id, balance FROM (
             SELECT type_code, account_id, balance, rank() OVER (PARTITION BY type_code ORDER BY balance DESC) r
             FROM accounts) x WHERE r <= 3 ORDER BY type_code, r;"
    say "Replica: transfer_funds(6, 9, 100.00)"
    rp -c "SELECT transfer_funds(6, 9, 100.00);"
    say "Replica: a direct UPDATE"
    rp -c "UPDATE accounts SET balance = balance + 1 WHERE account_id = 9;"
    say "Replica: CREATE TABLE"
    rp -c "CREATE TABLE scratch (id int);"
} > "$OUT/03-read-only-replica.txt"

# ---------------------------------------------------------------------------
echo "== 04 stale read"
{
    title "Asynchronous replication: a read from the replica can be stale"
    say "Replica: pause WAL replay (simulates a replica that has fallen behind)"
    rp -At -c "SELECT pg_wal_replay_pause();" > /dev/null
    rp -At -c "SELECT 'replay paused: ' || pg_is_wal_replay_paused();"
    say "Primary: transfer_funds(6, 9, 2500.00), committed and acknowledged to the client"
    pp -At -c "SELECT 'transfer ' || transfer_funds(6, 9, 2500.00);"
    say "Account 9 read from each server"
    pp -At -c "SELECT 'primary: ' || balance FROM accounts WHERE account_id = 9;"
    rp -At -c "SELECT 'replica: ' || balance || '   <- stale' FROM accounts WHERE account_id = 9;"
    say "How far behind the replica is"
    rp -c "SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed,
                  pg_last_wal_receive_lsn() - pg_last_wal_replay_lsn() AS bytes_not_applied,
                  now() - pg_last_xact_replay_timestamp() AS behind_by;"
    say "Replica: resume replay"
    rp -At -c "SELECT pg_wal_replay_resume();" > /dev/null
    wait_replica_caught_up
    rp -At -c "SELECT 'replica: ' || balance || '   <- caught up' FROM accounts WHERE account_id = 9;"
} > "$OUT/04-stale-read.txt"

# ---------------------------------------------------------------------------
echo "== 05 synchronous replication"
{
    title "Synchronous replication: no stale commits, but writes depend on the replica"
    say "Primary: synchronous_standby_names = 'replica1'"
    pp -c "ALTER SYSTEM SET synchronous_standby_names = 'replica1';" -c "SELECT pg_reload_conf();" > /dev/null
    sleep 1
    pp -c "SELECT application_name, sync_state FROM pg_stat_replication;"
    say "Primary: transfer_funds(6, 9, 100.00) with the replica up"
    start=$(date +%s)
    pp -At -c "SELECT 'transfer ' || transfer_funds(6, 9, 100.00);"
    echo "returned after $(( $(date +%s) - start )) s"
    say "Stop the replica (a network partition or crash)"
    "${DC[@]}" stop pg-replica 2>&1 | grep -c Stopped | sed 's/^/containers stopped: /'
    say "Primary: transfer_funds(6, 9, 200.00) in the background"
    ( start=$(date +%s)
      pp -At -c "SELECT 'transfer ' || transfer_funds(6, 9, 200.00);"
      echo "$(ts)  background transfer returned after $(( $(date +%s) - start )) s" ) > "$WORK/bg.txt" &
    sleep 5
    say "Primary, 5 seconds later: the session is still waiting for the replica"
    pp -c "SELECT pid, state, wait_event_type, wait_event, now() - query_start AS waiting_for
           FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
    say "Another session reads the latest transfer id: is the waiting transfer visible?"
    pp -c "SELECT max(transfer_id) AS latest_visible_transfer FROM transfers;"
    say "Start the replica again"
    "${DC[@]}" start pg-replica 2>&1 | grep -c Started | sed 's/^/containers started: /'
    wait
    cat "$WORK/bg.txt"
    say "Back to asynchronous replication"
    pp -c "ALTER SYSTEM RESET synchronous_standby_names;" -c "SELECT pg_reload_conf();" > /dev/null
    sleep 1
    wait_replica_caught_up
    pp -c "SELECT application_name, sync_state FROM pg_stat_replication;"
} > "$OUT/05-synchronous-replication.txt"

# ---------------------------------------------------------------------------
echo "== 06 failover"
{
    title "Failover: the primary fails and the replica is promoted"
    wait_replica_caught_up
    LAST_ID=$(pp -At -c "SELECT max(transfer_id) FROM transfers;")
    say "Last transfer id on the primary before it fails: $LAST_ID"
    say "Stop the primary"
    "${DC[@]}" stop pg-primary 2>&1 | grep -c Stopped | sed 's/^/containers stopped: /'
    say "Replica: still a standby, so writes fail"
    rp -At -c "SELECT 'is_standby: ' || pg_is_in_recovery();"
    rp -c "SELECT transfer_funds(6, 9, 100.00);"
    say "Replica: SELECT pg_promote()"
    rp -At -c "SELECT 'promoted: ' || pg_promote(wait => true);"
    rp -At -c "SELECT 'is_standby: ' || pg_is_in_recovery();"
    say "New primary: transfer_funds(6, 9, 100.00)"
    rp -At -c "SELECT 'transfer ' || transfer_funds(6, 9, 100.00);"
    say "Transfer ids jump: the sequence is WAL-logged in batches of 32, so the replica resumes after the batch"
    rp -c "SELECT transfer_id, from_account, to_account, amount, status FROM transfers WHERE transfer_id > $LAST_ID - 2 ORDER BY transfer_id;"
    say "New primary: every account still reconciles with the ledger (expect 0)"
    rp -c "$RECONCILE"
} > "$OUT/06-failover.txt"

# ---------------------------------------------------------------------------
echo "== 07 split brain"
{
    title "Split brain: the old primary comes back without being fenced"
    say "Start the old primary again"
    "${DC[@]}" start pg-primary 2>&1 | grep -c Started | sed 's/^/containers started: /'
    until pp -At -c "SELECT 1;" > /dev/null 2>&1; do sleep 1; done
    pp -At -c "SELECT 'old primary  is_standby: ' || pg_is_in_recovery();"
    rp -At -c "SELECT 'new primary  is_standby: ' || pg_is_in_recovery();"
    say "A client still pointing at the old primary: transfer_funds(9, 6, 5000.00)"
    pp -At -c "SELECT 'old primary  transfer ' || transfer_funds(9, 6, 5000.00);"
    say "A client using the new primary: transfer_funds(6, 9, 300.00)"
    rp -At -c "SELECT 'new primary  transfer ' || transfer_funds(6, 9, 300.00);"
    say "The two servers now disagree"
    pp -At -c "SELECT 'old primary  account 9: ' || balance FROM accounts WHERE account_id = 9;"
    pp -At -c "SELECT 'old primary  max transfer_id: ' || max(transfer_id) || ', total transfers: ' || count(*) FROM transfers;"
    rp -At -c "SELECT 'new primary  account 9: ' || balance FROM accounts WHERE account_id = 9;"
    rp -At -c "SELECT 'new primary  max transfer_id: ' || max(transfer_id) || ', total transfers: ' || count(*) FROM transfers;"
    say "Fence the old primary (stop it); it would have to be rebuilt from the new primary"
    "${DC[@]}" stop pg-primary 2>&1 | grep -c Stopped | sed 's/^/containers stopped: /'
} > "$OUT/07-split-brain.txt"

# ---------------------------------------------------------------------------
echo "== 08 MongoDB replica set"
{
    title "MongoDB replica set rs0: mongo1 (priority 2), mongo2, mongo3"
    mgo mongo1 'rs.initiate({ _id: "rs0", members: [
        { _id: 0, host: "mongo1:27017", priority: 2 },
        { _id: 1, host: "mongo2:27017" },
        { _id: 2, host: "mongo3:27017" } ] }).ok' | sed 's/^/rs.initiate ok: /'
    until [[ "$(mgo mongo1 'db.hello().isWritablePrimary' | tail -1)" == "true" ]]; do sleep 1; done
    STATUS='rs.status().members.forEach(m => print(m.name.padEnd(14) + m.stateStr.padEnd(12) + (m.health ? "up" : "DOWN")))'
    mgo mongo1 "$STATUS"

    say "Write with w: 'majority' (acknowledged once 2 of 3 members have it)"
    mgo mongo1 'const r = db.getSiblingDB("paybridge").events.insertOne(
        { type: "LOGIN", customer_id: 800, ts: new Date() }, { writeConcern: { w: "majority", wtimeout: 3000 } });
        print("acknowledged: " + r.acknowledged)'
    sleep 1
    say "Read the same document from a secondary (mongo3)"
    mgo mongo3 'db.getMongo().setReadPref("secondary"); print("documents on mongo3: " + db.getSiblingDB("paybridge").events.countDocuments())'

    say "Stop mongo3: 2 of 3 members remain, still a majority"
    "${DC[@]}" stop mongo3 2>&1 | grep -c Stopped | sed 's/^/containers stopped: /'
    mgo mongo1 'const r = db.getSiblingDB("paybridge").events.insertOne(
        { type: "LOGIN", customer_id: 1600, ts: new Date() }, { writeConcern: { w: "majority", wtimeout: 3000 } });
        print("w: majority acknowledged: " + r.acknowledged)'

    say "Stop mongo2 as well: the primary can no longer reach a majority"
    "${DC[@]}" stop mongo2 2>&1 | grep -c Stopped | sed 's/^/containers stopped: /'
    mgo mongo1 'try { db.getSiblingDB("paybridge").events.insertOne(
        { type: "LOGIN", customer_id: 2400, ts: new Date() }, { writeConcern: { w: "majority", wtimeout: 3000 } });
        print("acknowledged") } catch (e) { print("w: majority FAILED: " + e.codeName + " - " + e.message) }'
    say "Wait for the primary to notice it has lost the majority"
    until [[ "$(mgo mongo1 'db.hello().isWritablePrimary' | tail -1)" == "false" ]]; do sleep 1; done
    mgo mongo1 "$STATUS"
    mgo mongo1 'try { db.getSiblingDB("paybridge").events.insertOne({ type: "LOGIN", customer_id: 3200, ts: new Date() });
        print("acknowledged") } catch (e) { print("any write FAILED: " + e.codeName) }'
    mgo mongo1 'db.getMongo().setReadPref("secondaryPreferred"); print("reads still work: " + db.getSiblingDB("paybridge").events.countDocuments() + " documents")'

    say "Restart mongo2 and mongo3: a primary is elected again"
    "${DC[@]}" start mongo2 mongo3 2>&1 | grep -c Started | sed 's/^/containers started: /'
    until [[ "$(mgo mongo1 'db.hello().primary || ""' | tail -1)" == mongo* ]]; do sleep 1; done
    mgo mongo1 "$STATUS"
} > "$OUT/08-mongodb-replica-set.txt"

# ---------------------------------------------------------------------------
echo "== 09 sharding analysis"
rp -f /p5/sharding_analysis.sql > "$OUT/09-sharding-analysis.txt"

echo "Outputs written to outputs/"
