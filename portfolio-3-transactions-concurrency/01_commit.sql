-- MIT 8103 Portfolio 3, demo 1: COMMIT
-- A successful transfer of 25,000 from account 1 to account 3.
-- Shows balances before and after, the transfer row, both ledger rows and the audit entries.

\set ON_ERROR_STOP on
\pset footer off

\echo '=== Balances before'
SELECT account_id, type_code, status, balance FROM accounts WHERE account_id IN (1, 3) ORDER BY account_id;

\echo '=== Transfer 25,000 from account 1 to account 3'
BEGIN;
SELECT transfer_funds(1, 3, 25000.00) AS new_transfer_id \gset
COMMIT;

\echo '=== Balances after COMMIT'
SELECT account_id, type_code, status, balance FROM accounts WHERE account_id IN (1, 3) ORDER BY account_id;

\echo '=== The transfer row'
SELECT transfer_id, from_account, to_account, amount, status FROM transfers WHERE transfer_id = :new_transfer_id;

\echo '=== Its two ledger rows'
SELECT txn_id, account_id, txn_type, amount, balance_after FROM transactions
WHERE transfer_id = :new_transfer_id ORDER BY txn_id;

\echo '=== Audit entries written by the trigger'
SELECT record_id AS account_id, old_data->>'balance' AS old_balance, new_data->>'balance' AS new_balance
FROM audit_log WHERE table_name = 'accounts' AND record_id IN (1, 3)
ORDER BY audit_id DESC LIMIT 2;

\echo '=== Reconciliation: stored balance equals the sum of the ledger (expect 0 rows)'
SELECT a.account_id, a.balance, l.ledger_total
FROM accounts a
JOIN (SELECT account_id,
             SUM(CASE WHEN txn_type IN ('DEPOSIT', 'TRANSFER_IN', 'REVERSAL_IN') THEN amount ELSE -amount END) AS ledger_total
      FROM transactions WHERE account_id IN (1, 3) GROUP BY account_id) l USING (account_id)
WHERE a.balance <> l.ledger_total;
