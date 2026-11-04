-- MIT 8103 Portfolio 2: benchmark queries for PayBridge Microfinance Bank
-- Run after seed.sql. Fixed IDs and dates keep before/after runs comparable
-- (the seed data ends on 2026-11-01).

-- Q1: Account statement
-- All ledger entries for account 23243 in October 2026, oldest first.
SELECT created_at, txn_type, amount, balance_after
FROM transactions
WHERE account_id = 23243
  AND created_at >= '2026-10-01'
  AND created_at <  '2026-11-01'
ORDER BY created_at;

-- Q2: Customer balances
-- Every account held by one customer, with the product description.
SELECT a.account_no, a.type_code, t.description, a.balance, a.status
FROM customers c
JOIN accounts a      ON a.customer_id = c.customer_id
JOIN account_types t ON t.type_code   = a.type_code
WHERE c.email = 'amaka.adeyemi16@example.com'
ORDER BY a.account_no;

-- Q3: Recent transfers
-- Transfers initiated between 25 and 31 October 2026, newest first,
-- with the sender's and receiver's account numbers.
SELECT tr.transfer_id,
       s.account_no AS from_account_no,
       r.account_no AS to_account_no,
       tr.amount, tr.status, tr.initiated_at
FROM transfers tr
JOIN accounts s ON s.account_id = tr.from_account
JOIN accounts r ON r.account_id = tr.to_account
WHERE tr.initiated_at >= '2026-10-25'
  AND tr.initiated_at <  '2026-11-01'
ORDER BY tr.initiated_at DESC;

-- Q4: Top senders
-- The 10 customers who sent the most money in completed transfers in October 2026.
SELECT c.customer_id, c.full_name,
       count(*)       AS transfers_sent,
       sum(tr.amount) AS total_sent
FROM transfers tr
JOIN accounts a  ON a.account_id  = tr.from_account
JOIN customers c ON c.customer_id = a.customer_id
WHERE tr.status = 'COMPLETED'
  AND tr.initiated_at >= '2026-10-01'
  AND tr.initiated_at <  '2026-11-01'
GROUP BY c.customer_id, c.full_name
ORDER BY total_sent DESC
LIMIT 10;

-- Q5: Failed transfers per customer
-- Customers with 3 or more failed outgoing transfers.
-- Written with a correlated subquery: the count is evaluated once per customer.
SELECT c.customer_id, c.full_name, f.failed_transfers
FROM customers c
CROSS JOIN LATERAL (
    SELECT count(*) AS failed_transfers
    FROM transfers tr
    JOIN accounts a ON a.account_id = tr.from_account
    WHERE a.customer_id = c.customer_id
      AND tr.status = 'FAILED'
) f
WHERE f.failed_transfers >= 3
ORDER BY f.failed_transfers DESC, c.customer_id;

-- Q6: Balance ranking
-- The five highest balances within each account type.
SELECT type_code, account_no, balance, balance_rank
FROM (
    SELECT type_code, account_no, balance,
           RANK() OVER (PARTITION BY type_code ORDER BY balance DESC) AS balance_rank
    FROM accounts
) ranked
WHERE balance_rank <= 5
ORDER BY type_code, balance_rank;
