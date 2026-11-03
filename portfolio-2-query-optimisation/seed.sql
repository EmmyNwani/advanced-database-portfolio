-- MIT 8103 Portfolio 2: seed data for PayBridge Microfinance Bank
-- Target: PostgreSQL 16, loaded after portfolio-1-database-design/schema.sql.
-- Deterministic: setseed() fixes random(), so every run produces the same data.
-- Volumes: 20,000 customers, 30,000 accounts, 50,000 transfers, ~190,000 ledger rows.
-- Data window: 2024-11-01 to 2026-11-01.

\set ON_ERROR_STOP on
SET max_parallel_workers_per_gather = 0;   -- keep random() order deterministic
SELECT setseed(0.42);

TRUNCATE audit_log, transactions, transfers, accounts, customers RESTART IDENTITY CASCADE;

-- 1. Customers: 85% VERIFIED, 10% PENDING, 5% REJECTED
INSERT INTO customers (full_name, email, phone, kyc_status, created_at)
SELECT f.name || ' ' || l.name,
       lower(f.name || '.' || l.name || g.i) || '@example.com',
       '080' || lpad(g.i::text, 8, '0'),
       CASE WHEN r < 0.85 THEN 'VERIFIED' WHEN r < 0.95 THEN 'PENDING' ELSE 'REJECTED' END,
       timestamptz '2024-11-01' + random() * interval '600 days'
FROM (SELECT i, random() AS r,
             1 + floor(random() * 12)::int AS fi,
             1 + floor(random() * 12)::int AS li
      FROM generate_series(1, 20000) AS i) g
JOIN (SELECT row_number() OVER () AS n, name FROM unnest(ARRAY[
        'Chinedu','Amaka','Tunde','Ngozi','Ibrahim','Funmi',
        'Emeka','Aisha','Segun','Chiamaka','Musa','Yetunde']) AS name) f ON f.n = g.fi
JOIN (SELECT row_number() OVER () AS n, name FROM unnest(ARRAY[
        'Okafor','Adeyemi','Bello','Eze','Okonkwo','Abubakar',
        'Nwosu','Balogun','Ojo','Danjuma','Ibe','Lawal']) AS name) l ON l.n = g.li
ORDER BY g.i;

-- 2. Accounts: every customer has one, 7,000 have a second, 3,000 of those a third (30,000 total)
--    70% SAVINGS; 95% ACTIVE, 3% FROZEN, 2% CLOSED. Balances are set in step 6.
WITH ranked AS (
    SELECT customer_id, created_at, row_number() OVER (ORDER BY random()) AS rk
    FROM customers
), owners AS (
    SELECT customer_id, created_at FROM ranked
    UNION ALL SELECT customer_id, created_at FROM ranked WHERE rk <= 7000
    UNION ALL SELECT customer_id, created_at FROM ranked WHERE rk <= 3000
)
INSERT INTO accounts (customer_id, account_no, type_code, status, opened_at)
SELECT customer_id,
       '30' || lpad(row_number() OVER (ORDER BY customer_id)::text, 8, '0'),
       CASE WHEN random() < 0.70 THEN 'SAVINGS' ELSE 'CURRENT' END,
       CASE WHEN r < 0.95 THEN 'ACTIVE' WHEN r < 0.98 THEN 'FROZEN' ELSE 'CLOSED' END,
       created_at + random() * interval '30 days'
FROM (SELECT o.*, random() AS r FROM owners o ORDER BY customer_id) x;

-- 3. Transfers: random pairs of different accounts, after both were opened
--    90% COMPLETED, 7% FAILED, 3% REVERSED
INSERT INTO transfers (from_account, to_account, amount, status, initiated_at)
SELECT p.from_acc, p.to_acc,
       round((1000 + random() * 99000)::numeric, 2),
       CASE WHEN p.r < 0.90 THEN 'COMPLETED' WHEN p.r < 0.97 THEN 'FAILED' ELSE 'REVERSED' END,
       greatest(a.opened_at, b.opened_at) + interval '1 minute'
         + random() * (timestamptz '2026-11-01' - greatest(a.opened_at, b.opened_at) - interval '1 day')
FROM (SELECT f AS from_acc,
             ((f - 1 + 1 + floor(random() * 29999)::int) % 30000) + 1 AS to_acc,
             random() AS r
      FROM (SELECT 1 + floor(random() * 30000)::int AS f
            FROM generate_series(1, 50000)) s) p
JOIN accounts a ON a.account_id = p.from_acc
JOIN accounts b ON b.account_id = p.to_acc
ORDER BY 5;

-- 4. Ledger events (signed amounts) except the opening deposit
CREATE TEMP TABLE ev (
    account_id  BIGINT,
    transfer_id BIGINT,
    txn_type    VARCHAR(12),
    signed_amt  NUMERIC(15,2),
    created_at  TIMESTAMPTZ
);

-- 35,000 extra deposits and 30,000 withdrawals on random accounts
INSERT INTO ev
SELECT a.account_id, NULL, 'DEPOSIT', round((5000 + random() * 195000)::numeric, 2),
       a.opened_at + interval '1 minute' + random() * (timestamptz '2026-11-01' - a.opened_at - interval '1 minute')
FROM (SELECT 1 + floor(random() * 30000)::int AS id FROM generate_series(1, 35000)) s
JOIN accounts a ON a.account_id = s.id;

INSERT INTO ev
SELECT a.account_id, NULL, 'WITHDRAWAL', -round((1000 + random() * 49000)::numeric, 2),
       a.opened_at + interval '1 minute' + random() * (timestamptz '2026-11-01' - a.opened_at - interval '1 minute')
FROM (SELECT 1 + floor(random() * 30000)::int AS id FROM generate_series(1, 30000)) s
JOIN accounts a ON a.account_id = s.id;

-- Completed and reversed transfers: debit sender, credit receiver
INSERT INTO ev
SELECT from_account, transfer_id, 'TRANSFER_OUT', -amount, initiated_at
FROM transfers WHERE status IN ('COMPLETED', 'REVERSED')
UNION ALL
SELECT to_account, transfer_id, 'TRANSFER_IN', amount, initiated_at
FROM transfers WHERE status IN ('COMPLETED', 'REVERSED');

-- Reversals, within a day: money leaves the receiver and returns to the sender
INSERT INTO ev
SELECT account_id, transfer_id, txn_type, signed_amt, rev_at
FROM (SELECT t.*, t.initiated_at + interval '1 minute' + random() * interval '1 day' AS rev_at
      FROM transfers t WHERE status = 'REVERSED') r
CROSS JOIN LATERAL (VALUES (r.to_account,   'REVERSAL_OUT', -r.amount),
                           (r.from_account, 'REVERSAL_IN',   r.amount)) v(account_id, txn_type, signed_amt);
-- FAILED transfers produce no ledger rows.

-- 5. Opening deposit, sized so the running balance never drops below zero:
--    a random base amount plus the account's worst running deficit.
INSERT INTO ev
SELECT a.account_id, NULL, 'DEPOSIT',
       round((200000 + random() * 1800000)::numeric, 2) + greatest(0, -coalesce(m.min_running, 0)),
       a.opened_at
FROM accounts a
LEFT JOIN (SELECT account_id, min(running) AS min_running
           FROM (SELECT account_id,
                        sum(signed_amt) OVER (PARTITION BY account_id
                                              ORDER BY created_at, txn_type, transfer_id
                                              ROWS UNBOUNDED PRECEDING) AS running
                 FROM ev) x
           GROUP BY account_id) m ON m.account_id = a.account_id;

-- 6. Write the ledger in time order with running balances, then set each account's balance
INSERT INTO transactions (account_id, transfer_id, txn_type, amount, balance_after, created_at)
SELECT account_id, transfer_id, txn_type, abs(signed_amt),
       sum(signed_amt) OVER (PARTITION BY account_id
                             ORDER BY created_at, txn_type, transfer_id
                             ROWS UNBOUNDED PRECEDING),
       created_at
FROM ev
ORDER BY created_at, account_id;

UPDATE accounts a
SET balance = l.balance_after
FROM (SELECT DISTINCT ON (account_id) account_id, balance_after
      FROM transactions
      ORDER BY account_id, created_at DESC, txn_id DESC) l
WHERE l.account_id = a.account_id;

DROP TABLE ev;

-- 7. Fresh planner statistics for Portfolio 2's execution plans
ANALYZE;

-- 8. Summary
SELECT 'customers' AS table_name, count(*) AS rows FROM customers
UNION ALL SELECT 'accounts',     count(*) FROM accounts
UNION ALL SELECT 'transfers',    count(*) FROM transfers
UNION ALL SELECT 'transactions', count(*) FROM transactions;
