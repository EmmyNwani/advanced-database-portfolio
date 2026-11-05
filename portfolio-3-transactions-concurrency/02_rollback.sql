-- MIT 8103 Portfolio 3, demo 2: ROLLBACK
-- Part A: every guardrail rejects a bad transfer, and nothing is written.
-- Part B: an explicit ROLLBACK undoes a transfer that had succeeded inside the transaction.
-- Part C: a later error in the same transaction rolls back an earlier successful transfer.
-- Part D: a SAVEPOINT undoes only the failed part of a transaction.
-- Errors are expected in this script, so it does not stop on them.

\set ON_ERROR_STOP off
\pset footer off

\echo '=== Starting state'
SELECT account_id, type_code, status, balance FROM accounts WHERE account_id IN (1, 3, 6, 9, 28, 38) ORDER BY account_id;
SELECT count(*) AS transfers_before FROM transfers \gset
SELECT count(*) AS ledger_rows_before FROM transactions \gset

\echo ''
\echo '=== Part A: guardrails (each call should fail)'
\echo '--- A1: negative amount'
SELECT transfer_funds(1, 3, -50.00);
\echo '--- A2: same account'
SELECT transfer_funds(1, 1, 100.00);
\echo '--- A3: account does not exist'
SELECT transfer_funds(1, 999999, 100.00);
\echo '--- A4: source account FROZEN (28)'
SELECT transfer_funds(28, 1, 100.00);
\echo '--- A5: destination account CLOSED (38)'
SELECT transfer_funds(1, 38, 100.00);
\echo '--- A6: insufficient funds (account 6 holds about 1.8 million)'
SELECT transfer_funds(6, 9, 2000000.00);
\echo '--- A7: daily limit (SAVINGS limit is 500,000)'
SELECT transfer_funds(3, 1, 600000.00);

\echo ''
\echo '=== After Part A: nothing written (expect the same counts as before)'
SELECT :transfers_before AS transfers_before, count(*) AS transfers_now FROM transfers;
SELECT :ledger_rows_before AS ledger_rows_before, count(*) AS ledger_rows_now FROM transactions;

\echo ''
\echo '=== Part B: explicit ROLLBACK'
BEGIN;
SELECT transfer_funds(6, 9, 1000.00) AS transfer_id;
\echo '--- Inside the transaction, the money has moved:'
SELECT account_id, balance FROM accounts WHERE account_id IN (6, 9) ORDER BY account_id;
ROLLBACK;
\echo '--- After ROLLBACK, the balances are back:'
SELECT account_id, balance FROM accounts WHERE account_id IN (6, 9) ORDER BY account_id;

\echo ''
\echo '=== Part C: a later error undoes an earlier success'
BEGIN;
SELECT transfer_funds(6, 9, 1000.00) AS transfer_id;
\echo '--- Second statement fails (transfer from a FROZEN account):'
SELECT transfer_funds(28, 9, 500.00);
\echo '--- The transaction is now aborted; COMMIT turns into ROLLBACK:'
COMMIT;
SELECT account_id, balance FROM accounts WHERE account_id IN (6, 9) ORDER BY account_id;

\echo ''
\echo '=== Part D: SAVEPOINT keeps the good work and undoes the failed part'
BEGIN;
SELECT transfer_funds(6, 9, 1000.00) AS kept_transfer_id;
SAVEPOINT before_second_transfer;
SELECT transfer_funds(6, 9, 5000000.00);
ROLLBACK TO SAVEPOINT before_second_transfer;
COMMIT;
\echo '--- The 1,000 transfer was committed; the failed one left no trace:'
SELECT account_id, balance FROM accounts WHERE account_id IN (6, 9) ORDER BY account_id;
SELECT :transfers_before AS transfers_before, count(*) AS transfers_now FROM transfers;
