-- ============================================================
-- MIT 8103 PORTFOLIO 2
-- PAYBRIDGE: SECONDARY INDEXING SCRIPT
-- Run AFTER collecting baseline execution plans.
-- ============================================================

-- Q1: Account statement
CREATE INDEX idx_transactions_account_created
ON transactions (account_id, created_at);


-- Q2: Customer balances
CREATE INDEX idx_accounts_customer
ON accounts (customer_id);


-- Q3: Recent transfers
CREATE INDEX idx_transfers_initiated
ON transfers (initiated_at);


-- Q4: Top senders
-- INCLUDE (amount) lets the query be answered from the index alone (index-only scan).
CREATE INDEX idx_transfers_completed_date_sender
ON transfers (initiated_at, from_account) INCLUDE (amount)
WHERE status = 'COMPLETED';


-- Q5: Failed transfers per customer
CREATE INDEX idx_transfers_failed_sender
ON transfers (from_account)
WHERE status = 'FAILED';


-- Q6: Balance ranking
CREATE INDEX idx_accounts_type_balance
ON accounts (type_code, balance DESC);


-- Refresh planner statistics and the visibility map (needed for index-only scans).
VACUUM ANALYZE;


-- Storage cost of each new index.
SELECT indexrelname AS index_name,
       relname      AS table_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE indexrelname LIKE 'idx_%'
ORDER BY pg_relation_size(indexrelid) DESC;
