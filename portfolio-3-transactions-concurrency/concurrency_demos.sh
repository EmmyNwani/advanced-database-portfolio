#!/usr/bin/env bash
# MIT 8103 Portfolio 3: concurrency demonstrations with two real database sessions
#
# Usage:  ./concurrency_demos.sh
#
# Each demo starts Session A, then Session B one second later, so their steps interleave.
# Every step prints a timestamp, so the output shows who ran, waited or failed, and when.
# Results are written to outputs/03-*.txt ... outputs/08-*.txt.
#
# Demos 03-06 change balances directly (that is the point: they show unsafe and safe
# patterns), so the script restores the original balances afterwards. Demos 07-08 use
# transfer_funds(), which keeps the ledger consistent.

set -euo pipefail

CONTAINER="${PG_CONTAINER:-pg-bank}"
DB="${PG_DB:-paybridge}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/outputs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# One psql session; errors are interleaved with normal output in the order they happen
session() {
    docker exec -i "$CONTAINER" sh -c "stdbuf -oL -eL psql -U postgres -d $DB -X -q -At -v ON_ERROR_STOP=0 2>&1"
}
query() {
    docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -X -q "$@"
}

TS="\\set ts 'to_char(clock_timestamp(), ''HH24:MI:SS.MS'')'"

# run_pair <output-name> <title> <session A sql> <session B sql>
run_pair() {
    echo "== $2"
    { echo "$TS"; echo "$3"; } | session > "$WORK/a.txt" &
    sleep 1
    { echo "$TS"; echo "$4"; } | session > "$WORK/b.txt" &
    wait
    {
        echo "=== $2"
        echo
        echo "--- Session A"
        cat "$WORK/a.txt"
        echo
        echo "--- Session B (started 1 second after A)"
        cat "$WORK/b.txt"
        echo
    } > "$OUT/$1.txt"
}

balance_of() {
    query -At -c "SELECT balance FROM accounts WHERE account_id = $1;"
}

restore_balance() {
    query -c "UPDATE accounts SET balance = $2 WHERE account_id = $1;"
}

# Accounts 1, 3, 6 and 9 whose stored balance differs from their ledger total
RECONCILE_SQL="SELECT a.account_id, a.balance, l.ledger_total
          FROM accounts a
          JOIN (SELECT account_id,
                       SUM(CASE WHEN txn_type IN ('DEPOSIT', 'TRANSFER_IN', 'REVERSAL_IN') THEN amount ELSE -amount END) AS ledger_total
                FROM transactions WHERE account_id IN (1, 3, 6, 9) GROUP BY account_id) l USING (account_id)
          WHERE a.balance <> l.ledger_total"

# The demos restore the balances they find at the start, so they must start from a
# reconciled state; otherwise an earlier interrupted run's error would be carried forward.
if [[ -n "$(query -At -c "$RECONCILE_SQL;")" ]]; then
    echo "Stopped: accounts 1, 3, 6 or 9 do not reconcile with the ledger. Fix them before running the demos." >&2
    query -c "$RECONCILE_SQL;" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 03 + 04: lost update on account 9 (two deposits, read-modify-write)
# ---------------------------------------------------------------------------
B9=$(balance_of 9)

LOST_A=$(cat <<'SQL'
BEGIN;
SELECT :ts || '  A  requests balance of account 9 __LOCK__';
SELECT balance AS bal FROM accounts WHERE account_id = 9 __LOCK__ \gset
SELECT :ts || '  A  reads balance of account 9: ' || :'bal';
SELECT pg_sleep(2) \gset
UPDATE accounts SET balance = :bal + 1000 WHERE account_id = 9;
SELECT :ts || '  A  writes ' || :'bal' || ' + 1,000 (deposit of 1,000)';
COMMIT;
SELECT :ts || '  A  commits';
SQL
)
LOST_B=$(cat <<'SQL'
BEGIN;
SELECT :ts || '  B  requests balance of account 9 __LOCK__';
SELECT balance AS bal FROM accounts WHERE account_id = 9 __LOCK__ \gset
SELECT :ts || '  B  reads balance of account 9: ' || :'bal';
SELECT pg_sleep(2) \gset
UPDATE accounts SET balance = :bal + 500 WHERE account_id = 9;
SELECT :ts || '  B  writes ' || :'bal' || ' + 500 (deposit of 500)';
COMMIT;
SELECT :ts || '  B  commits';
SQL
)

for variant in unsafe safe; do
    if [[ "$variant" == "unsafe" ]]; then
        name="03-lost-update"; lock=""
        title="Lost update: two deposits read the same balance (plain SELECT)"
    else
        name="04-lost-update-prevented"; lock="FOR UPDATE"
        title="Lost update prevented: SELECT ... FOR UPDATE makes the second deposit wait"
    fi
    run_pair "$name" "$title" "${LOST_A//__LOCK__/$lock}" "${LOST_B//__LOCK__/$lock}"
    final=$(balance_of 9)
    {
        echo "--- Result"
        echo "Starting balance:            $B9"
        echo "Expected (both deposits):    $(echo "$B9 + 1500" | bc)"
        echo "Actual final balance:        $final"
        echo
        echo "--- Audit log: both writes happened"
        query -c "SELECT audit_id, old_data->>'balance' AS old_balance, new_data->>'balance' AS new_balance
                  FROM audit_log WHERE record_id = 9 ORDER BY audit_id DESC LIMIT 2;"
    } >> "$OUT/$name.txt"
    restore_balance 9 "$B9" > /dev/null
done

# ---------------------------------------------------------------------------
# 05 + 06: deadlock between opposite transfers on accounts 1 and 3
# ---------------------------------------------------------------------------
B1=$(balance_of 1)
B3=$(balance_of 3)

run_pair "05-deadlock" "Deadlock: A locks 1 then 3, B locks 3 then 1" "$(cat <<'SQL'
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE account_id = 1;
SELECT :ts || '  A  locks account 1 (debit 100)';
SELECT pg_sleep(2) \gset
SELECT :ts || '  A  requests account 3';
UPDATE accounts SET balance = balance + 100 WHERE account_id = 3;
SELECT :ts || '  A  got account 3 (credit 100)';
COMMIT;
SELECT :ts || '  A  ends transaction (COMMIT if it succeeded, ROLLBACK if it was aborted)';
SQL
)" "$(cat <<'SQL'
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE account_id = 3;
SELECT :ts || '  B  locks account 3 (debit 100)';
SELECT pg_sleep(2) \gset
SELECT :ts || '  B  requests account 1';
UPDATE accounts SET balance = balance + 100 WHERE account_id = 1;
SELECT :ts || '  B  got account 1 (credit 100)';
COMMIT;
SELECT :ts || '  B  ends transaction (COMMIT if it succeeded, ROLLBACK if it was aborted)';
SQL
)"
restore_balance 1 "$B1" > /dev/null
restore_balance 3 "$B3" > /dev/null

ORDERED=$(cat <<'SQL'
BEGIN;
SELECT :ts || '  __S__  requests locks on accounts 1 and 3';
SELECT count(*) AS locked FROM (SELECT 1 FROM accounts WHERE account_id IN (1, 3) ORDER BY account_id FOR UPDATE) s \gset
SELECT :ts || '  __S__  locks accounts 1 and 3, lowest id first';
SELECT pg_sleep(2) \gset
UPDATE accounts SET balance = balance - 100 WHERE account_id = __FROM__;
UPDATE accounts SET balance = balance + 100 WHERE account_id = __TO__;
SELECT :ts || '  __S__  moves 100 from account __FROM__ to account __TO__';
COMMIT;
SELECT :ts || '  __S__  commits';
SQL
)
A_SQL=${ORDERED//__S__/A}; A_SQL=${A_SQL//__FROM__/1}; A_SQL=${A_SQL//__TO__/3}
B_SQL=${ORDERED//__S__/B}; B_SQL=${B_SQL//__FROM__/3}; B_SQL=${B_SQL//__TO__/1}
run_pair "06-deadlock-prevented" "Deadlock prevented: both sessions lock accounts in account_id order" "$A_SQL" "$B_SQL"
restore_balance 1 "$B1" > /dev/null
restore_balance 3 "$B3" > /dev/null

# ---------------------------------------------------------------------------
# 07 + 08: non-repeatable read under READ COMMITTED vs REPEATABLE READ
# ---------------------------------------------------------------------------
READER=$(cat <<'SQL'
BEGIN ISOLATION LEVEL __LEVEL__;
SELECT :ts || '  A  (__LEVEL__) first read of account 9:  ' || balance FROM accounts WHERE account_id = 9;
SELECT pg_sleep(2) \gset
SELECT :ts || '  A  (__LEVEL__) second read of account 9: ' || balance FROM accounts WHERE account_id = 9;
COMMIT;
SELECT :ts || '  A  after COMMIT, account 9:             ' || balance FROM accounts WHERE account_id = 9;
SQL
)
WRITER=$(cat <<'SQL'
SELECT transfer_funds(6, 9, 1000.00) AS tid \gset
SELECT :ts || '  B  transfers 1,000 from account 6 to account 9 and commits (transfer ' || :tid || ')';
SQL
)
run_pair "07-read-committed" "READ COMMITTED: a second read inside one transaction sees B's committed change" \
    "${READER//__LEVEL__/READ COMMITTED}" "$WRITER"
run_pair "08-repeatable-read" "REPEATABLE READ: both reads see the same snapshot" \
    "${READER//__LEVEL__/REPEATABLE READ}" "$WRITER"

# ---------------------------------------------------------------------------
echo
echo "== Reconciliation for the demo accounts (expect 0 rows)"
query -c "$RECONCILE_SQL;"
echo "Outputs written to outputs/"
